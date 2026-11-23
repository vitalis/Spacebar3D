import Foundation
import ImportRouter
import ModelCore
import simd
import XCTest

/// Vertex colours of the USD files Blender 5.2 writes: its default binary `.usdc`, the
/// `.usdz` package around one, and `.usda` text. Blender writes no `primvars:displayColor`;
/// each colour attribute goes under its own name as `color4f[]` (`primvars:Col`, a point
/// attribute, interpolation "vertex"; `primvars:Paint`, a corner byte-colour attribute,
/// "faceVarying") with `colorSpace:name = "lin_rec709_scene"`, that is linear.
///
/// Fixtures: written by Blender 5.2.2 LTS (`bpy.ops.wm.usd_export`, `export_materials=False`) from
/// a script that builds the mesh with exact colours (script: /tmp/sb3d-fx/script/make.py, kept
/// in the test report). Every `.usdc` starts `PXR-USDC` then 00 08 00: crate version 0.8.0.
/// The `.usdz` holds one `.usdc` stored without compression. The cube has 24 corners, so
/// its `faceVertexIndices` is a compressed integer array in the crate file.
final class BlenderUSDColourTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-bcol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private enum Container: String, CaseIterable { case usdc, usdz, usda }

    private func part(_ fixture: String, _ container: Container) throws -> ModelScene.MeshPart {
        let data: Data
        switch (fixture, container) {
        case ("tri", .usdc): data = Self.triColUSDC
        case ("tri", .usdz): data = Self.triColUSDZ
        case ("tri", .usda): data = Data(Self.triColUSDA.utf8)
        case ("cube", .usdc): data = Self.cubePaintUSDC
        case ("cube", .usdz): data = Self.cubePaintUSDZ
        case ("cube", .usda): data = Data(Self.cubePaintUSDA.utf8)
        case ("plain", .usdc): data = Self.triPlainUSDC
        case ("plain", .usdz): data = Self.triPlainUSDZ
        default: data = Data(Self.triPlainUSDA.utf8)
        }
        let url = folder.appendingPathComponent("\(fixture).\(container.rawValue)")
        try data.write(to: url)
        return try XCTUnwrap(try ImportRouter.load(url, format: .usd).meshes.first?.parts.first)
    }

    private func srgb(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    private func srgb(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(srgb(c.x), srgb(c.y), srgb(c.z)) }
    private func rgb(_ c: SIMD4<Float>) -> SIMD3<Float> { SIMD3(c.x, c.y, c.z) }

    /// The file's own coordinates (the importer keeps `part.positions` there and turns the
    /// scene on a parent node), so a vertex is found by where the file put it.
    private func key(_ p: SIMD3<Float>) -> SIMD3<Int> { SIMD3(Int((p.x * 100).rounded()), Int((p.y * 100).rounded()), Int((p.z * 100).rounded())) }

    /// Open a Blender triangle whose "Col" attribute holds linear red, green and half grey on
    /// its three points, as `.usdc`, `.usdz` or `.usda`, and each corner shows that colour
    /// (it came out with no colour at all, grey: Model I/O hands over only `displayColor`, and
    /// the crate file is not text we could read ourselves), converted from linear light to
    /// the sRGB the scene keeps (half grey is 0.7354). Source: Blender 5.2.2 export, USD
    /// ColorSpaceAPI `lin_rec709_scene`; the same conversion as the `displayColor` path.
    func testABlenderTrianglesPointColoursAreShownInEveryContainer() throws {
        let grey = srgb(0.5)
        let expected: [SIMD3<Int>: SIMD3<Float>] = [
            key(SIMD3(0, 0, 0)): SIMD3(1, 0, 0), key(SIMD3(1, 0, 0)): SIMD3(0, 1, 0), key(SIMD3(0, 1, 0)): SIMD3(grey, grey, grey),
        ]
        for container in Container.allCases {
            let part = try part("tri", container)
            XCTAssertEqual(part.colors.count, part.positions.count, "\(container): a colour for every vertex")
            for (position, colour) in zip(part.positions, part.colors) {
                let want = try XCTUnwrap(expected[key(position)], "\(container): unexpected vertex \(position)")
                XCTAssertEqual(simd_distance(rgb(colour), want), 0, accuracy: 1e-3, "\(container) at \(position)")
                XCTAssertEqual(colour.w, 1, accuracy: 1e-3, "\(container) alpha at \(position)")
            }
            XCTAssertEqual(Set(part.positions.map(key)), Set(expected.keys), "\(container): all three points")
        }
    }

    /// Open a Blender cube painted one colour per face on its corners ("Paint", a byte colour,
    /// 24 corners on 8 points), as `.usdc`, `.usdz` or `.usda`, and each face shows its own
    /// colour (it was grey; and a crate file with 16 or more indices keeps them compressed,
    /// so a reader that cannot unpack them loses the faces too). Rule asserted: if the
    /// importer keeps the 24 corners apart, each vertex has its own face's colour (every
    /// face colour four times); if it welds them to the 8 points, each point has the mean of
    /// its three corners, taken in linear light and then converted (a blend of light), because
    /// one colour per point is all a welded vertex can hold. Welding is allowed, but not
    /// to one colour for everything.
    func testABlenderCubesCornerColoursAreShownInEveryContainer() throws {
        let palette: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 1, 0), SIMD3(0, 1, 1), SIMD3(repeating: 0.5028865)]
        // The file's own faceVertexIndices (6 quads), face colour by face.
        let faces: [[Int]] = [[0, 1, 3, 2], [2, 3, 7, 6], [6, 7, 5, 4], [4, 5, 1, 0], [2, 6, 4, 0], [7, 3, 1, 5]]
        let points: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(-1, -1, 1), SIMD3(-1, 1, -1), SIMD3(-1, 1, 1), SIMD3(1, -1, -1), SIMD3(1, -1, 1), SIMD3(1, 1, -1), SIMD3(1, 1, 1)]
        var cornersAt: [SIMD3<Int>: [SIMD3<Float>]] = [:]
        for (f, face) in faces.enumerated() { for i in face { cornersAt[key(points[i]), default: []].append(palette[f]) } }
        for container in Container.allCases {
            let part = try part("cube", container)
            XCTAssertEqual(part.colors.count, part.positions.count, "\(container): a colour for every vertex")
            if part.positions.count == 8 {
                for (position, colour) in zip(part.positions, part.colors) {
                    let corners = try XCTUnwrap(cornersAt[key(position)], "\(container): unexpected vertex \(position)")
                    let mean = srgb(corners.reduce(SIMD3<Float>(repeating: 0), +) / Float(corners.count))
                    XCTAssertEqual(simd_distance(rgb(colour), mean), 0, accuracy: 1e-3, "\(container) welded point \(position)")
                }
            } else {
                XCTAssertEqual(part.positions.count, 24, "\(container): welded to 8 points or kept as 24 corners")
                var seen: [SIMD3<Int>: Int] = [:]
                for (position, colour) in zip(part.positions, part.colors) {
                    let allowed = try XCTUnwrap(cornersAt[key(position)], "\(container): unexpected vertex \(position)").map(srgb)
                    XCTAssertTrue(allowed.contains { simd_distance($0, rgb(colour)) < 1e-3 }, "\(container): \(rgb(colour)) at \(position) is no colour of a face there")
                    seen[key(SIMD3<Float>(rgb(colour))) , default: 0] += 1
                }
                XCTAssertEqual(seen.count, 6, "\(container): six face colours")
                XCTAssertTrue(seen.values.allSatisfy { $0 == 4 }, "\(container): each face colour on its four corners, \(seen)")
            }
        }
    }

    /// A text USD that has both `displayColor` (blue) and Blender's own "Col" keeps showing
    /// `displayColor`, as before (a change that reads named colours must not take over a
    /// file that says what to show). Blender 5.2 itself never writes both, so this is the
    /// hand-made `.usda` of the earlier gap work (/tmp/sb3d-release/gap-usd-colours), and no crate twin.
    func testDisplayColourStillWinsOverANamedColourAttribute() throws {
        let usda = Self.triColUSDA.replacingOccurrences(of: "            color4f[] primvars:Col", with: """
                    color3f[] primvars:displayColor = [(0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                        interpolation = "vertex"
                    )
                    color4f[] primvars:Col
        """)
        XCTAssertTrue(usda.contains("displayColor"))
        let url = folder.appendingPathComponent("both.usda")
        try Data(usda.utf8).write(to: url)
        let part = try XCTUnwrap(try ImportRouter.load(url, format: .usd).meshes.first?.parts.first)
        XCTAssertEqual(part.colors.count, 3)
        for colour in part.colors { XCTAssertEqual(simd_distance(rgb(colour), SIMD3(0, 0, 1)), 0, accuracy: 2e-3) }
    }

    /// A Blender triangle with no colour attribute still has no vertex colours, in all three
    /// containers (the new reading must not invent colour, nor read the wrong attribute, or
    /// a plain model would turn up black or grey-tinted).
    func testABlenderTriangleWithoutColourAttributesHasNoVertexColours() throws {
        for container in Container.allCases {
            let part = try part("plain", container)
            XCTAssertEqual(part.positions.count, 3, "\(container)")
            XCTAssertTrue(part.colors.isEmpty, "\(container): colours \(part.colors)")
        }
    }

    /// Opening the Blender files stays quick. The bound is generous on purpose (2 s per file
    /// after one warm-up open, where each takes a few milliseconds today): it exists to
    /// catch a reader that loops or decodes the whole file again for every mesh, not
    /// to rank speed on a busy test machine.
    func testBlenderFilesOpenQuickly() throws {
        _ = try part("tri", .usda)
        for fixture in ["tri", "cube", "plain"] {
            for container in Container.allCases {
                let start = ContinuousClock.now
                _ = try part(fixture, container)
                let took = ContinuousClock.now - start
                XCTAssertLessThan(took, .seconds(2), "\(fixture).\(container) took \(took)")
            }
        }
    }

    // MARK: - Fixtures (Blender 5.2.2, see the class comment)

    private static let triColUSDC = Data(base64Encoded:
        "UFhSLVVTREMACAAAAAAAAKgFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA" +
        "AAAAAAAACAAAACABAAAAAAAAAA4AAAABAAAAAAAAABAAAAABAAAAAAAAAAEAAAAkAAAAAAAAAAEAAAAAAAAAAgAAAAgAAAAAAAAAAQAAAAAAAUCRAAAAAAAf" +
        "AAEAAAAAAAAAFAAAAAEAAAAAAAAAFQAAAAkAAAAAAAAAGAAAABkAAAAaAAAAGwAAABAAAAAcAAAAHQAAAB4AAAAfAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAACAPwAAgD8AAAAAAQAAAAAAAAADAAAAAwAAAAAAAAAAAAAAAQAAAAIAAAADAAAAAAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAA" +
        "AACAP0ZJRUwDAAAAAAAAAAAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAIA/AAAAAJsAAAADAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAACAPwAA" +
        "AAAAAIA/AAAAPwAAAD8AAAA/AACAPy8AAAAAAAAA/gEAAAAAAACvAQAAAAAAAADwlTstKQAAbWV0ZXJzUGVyVW5pdABkb2N1bWVudGF0aW9uAEJsZW5kZXIg" +
        "djUuMi4yIExUUwB1cEF4aXMAWgBwcmltQ2hpbGRyZW4Acm9vdABkZWZhdWx0UHJpbQBzcGVjaWZpZXIAdHlwZU5hbWUAWGZvcm0AYXBpU2NoZW1hcwBDb2xv" +
        "clNwYWNlQVBJAHByb3BlcnRpZXMAY29sb3JTcGFjZTpuOgCkY3VzdG9tRGF0YZIA9QUAZ2VuZXJhdGVkAFRyaQB1c2VyUEAAIjpitwCBOm9iamVjdF9EAPoR" +
        "TWVzaABhY3RpdmUAcG9pbnRzAGZhY2VWZXJ0ZXhDb3URAHFJbmRpY2Vz5QDxFHZhcnM6Q29sAG5vcm1hbHMAZXh0ZW50AHN1YmRpdmlzaW9u0gAfZYcABUJk" +
        "YXRhhQD0AnRva2VuAHZhcmlhYmlsaXR5NAHzEQBsaW5fcmVjNzA5X3NjZW5lAGZsb2F0M1tdAGludFtdfAAiM2YRAFJlcnBvbKMBAcUAYmFyeWluZ9gAASQA" +
        "AUIBEDQuABF24QBEAG5vbkgBgABzdHJpbmcABAAAAAAAAAAEAAAAEgAAABMAAAAUAAAAIwAAAAAAAAArAAAAAAAAAACAAgAAAAQUUFUBAPAOFQEBAfYI/Az4" +
        "/BYB6RfpFwDpFwXkF+kc+wAL3he4AAAAAAAAAACRAACAPwAACUAAAQAxCkAGCAAxC0BYCAAxKQAICAATCyAAMypADBAAEWQIADEgAHEIADEpAH0IADEfALUI" +
        "ADMpAMEIABEWCAAxC0ABCAAxAUDNCAAxKQAgCAAEGAAzLEAjEAATJAgAEQAxADMYgCUQABEgEAAzA4AsCAATJhgAAlkAMxiAKBAAEykIABFwKAAzGIAqEAAT" +
        "KwgAEaAYADMcgCwQAAEPAEMAAUAuEACAAwAAAAAACkA4AAAAAAAAADYAAAAAAAAAAPAkAQAAAAEUAEVVRUFRVAVFQVFBAPsG9QYF//UGB/sG8RDuE+wV6hUC" +
        "6RjmG+Qd4RAP4CHdDwAAAAAAAAAPAAAAAAAAABAAAAAAAAAAAOABAAAAURUAAAAD/gz1AhgAAAAAAAAAAPAGBAAAAFVVFBUBB+gk1ync8//+/f3/EgAAAAAA" +
        "AAAA8AAAAAAAURUAEP8B/wH/Af4PAAAAAAAAAAsAAAAAAAAAAJABAAAAAQAAAAAWAAAAAAAAAADwBAQAAABVRUUQAAYHBQYAAwMDAwANAAAAAAAAAACwAAAA" +
        "AAUBAAAH//sGAAAAAAAAAFRPS0VOUwAAAAAAAAAAAADYAQAAAAAAAMcBAAAAAAAAU1RSSU5HUwAAAAAAAAAAAJ8DAAAAAAAAGAAAAAAAAABGSUVMRFMAAAAA" +
        "AAAAAAAAtwMAAAAAAAD7AAAAAAAAAEZJRUxEU0VUUwAAAAAAAACyBAAAAAAAAEYAAAAAAAAAUEFUSFMAAAAAAAAAAAAAAPgEAAAAAAAAYgAAAAAAAABTUEVD" +
        "UwAAAAAAAAAAAAAAWgUAAAAAAABOAAAAAAAAAA==")!

    private static let triColUSDZ = Data(base64Encoded:
        "UEsDBAoAAAAAAKZJd139Rl5RcAYAAHAGAAAUAA4AYmxlbmRlcl90cmlfY29sLnVzZGOGGQoAAAAAAAAAAAAAAFBYUi1VU0RDAAgAAAAAAACoBQAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAgAAAAgAQAAAAAAAAAOAAAAAQAA" +
        "AAAAAAAQAAAAAQAAAAAAAAABAAAAJAAAAAAAAAABAAAAAAAAAAIAAAAIAAAAAAAAAAEAAAAAAAFAkQAAAAAAHwABAAAAAAAAABQAAAABAAAAAAAAABUAAAAJ" +
        "AAAAAAAAABgAAAAZAAAAGgAAABsAAAAQAAAAHAAAAB0AAAAeAAAAHwAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAgD8AAIA/AAAAAAEAAAAAAAAA" +
        "AwAAAAMAAAAAAAAAAAAAAAEAAAACAAAAAwAAAAAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD9GSUVMAwAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAIA/AAAAAAAAAAAAAAAAAACAPwAAAACbAAAAAwAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAgD8AAAAAAACAPwAAAD8AAAA/AAAAPwAAgD8vAAAA" +
        "AAAAAP4BAAAAAAAArwEAAAAAAAAA8JU7LSkAAG1ldGVyc1BlclVuaXQAZG9jdW1lbnRhdGlvbgBCbGVuZGVyIHY1LjIuMiBMVFMAdXBBeGlzAFoAcHJpbUNo" +
        "aWxkcmVuAHJvb3QAZGVmYXVsdFByaW0Ac3BlY2lmaWVyAHR5cGVOYW1lAFhmb3JtAGFwaVNjaGVtYXMAQ29sb3JTcGFjZUFQSQBwcm9wZXJ0aWVzAGNvbG9y" +
        "U3BhY2U6bjoApGN1c3RvbURhdGGSAPUFAGdlbmVyYXRlZABUcmkAdXNlclBAACI6YrcAgTpvYmplY3RfRAD6EU1lc2gAYWN0aXZlAHBvaW50cwBmYWNlVmVy" +
        "dGV4Q291EQBxSW5kaWNlc+UA8RR2YXJzOkNvbABub3JtYWxzAGV4dGVudABzdWJkaXZpc2lvbtIAH2WHAAVCZGF0YYUA9AJ0b2tlbgB2YXJpYWJpbGl0eTQB" +
        "8xEAbGluX3JlYzcwOV9zY2VuZQBmbG9hdDNbXQBpbnRbXXwAIjNmEQBSZXJwb2yjAQHFAGJhcnlpbmfYAAEkAAFCARA0LgARduEARABub25IAYAAc3RyaW5n" +
        "AAQAAAAAAAAABAAAABIAAAATAAAAFAAAACMAAAAAAAAAKwAAAAAAAAAAgAIAAAAEFFBVAQDwDhUBAQH2CPwM+PwWAekX6RcA6RcF5BfpHPsAC94XuAAAAAAA" +
        "AAAAkQAAgD8AAAlAAAEAMQpABggAMQtAWAgAMSkACAgAEwsgADMqQAwQABFkCAAxIABxCAAxKQB9CAAxHwC1CAAzKQDBCAARFggAMQtAAQgAMQFAzQgAMSkA" +
        "IAgABBgAMyxAIxAAEyQIABEAMQAzGIAlEAARIBAAMwOALAgAEyYYAAJZADMYgCgQABMpCAARcCgAMxiAKhAAEysIABGgGAAzHIAsEAABDwBDAAFALhAAgAMA" +
        "AAAAAApAOAAAAAAAAAA2AAAAAAAAAADwJAEAAAABFABFVUVBUVQFRUFRQQD7BvUGBf/1Bgf7BvEQ7hPsFeoVAukY5hvkHeEQD+Ah3Q8AAAAAAAAADwAAAAAA" +
        "AAAQAAAAAAAAAADgAQAAAFEVAAAAA/4M9QIYAAAAAAAAAADwBgQAAABVVRQVAQfoJNcp3PP//v39/xIAAAAAAAAAAPAAAAAAAFEVABD/Af8B/wH+DwAAAAAA" +
        "AAALAAAAAAAAAACQAQAAAAEAAAAAFgAAAAAAAAAA8AQEAAAAVUVFEAAGBwUGAAMDAwMADQAAAAAAAAAAsAAAAAAFAQAAB//7BgAAAAAAAABUT0tFTlMAAAAA" +
        "AAAAAAAA2AEAAAAAAADHAQAAAAAAAFNUUklOR1MAAAAAAAAAAACfAwAAAAAAABgAAAAAAAAARklFTERTAAAAAAAAAAAAALcDAAAAAAAA+wAAAAAAAABGSUVM" +
        "RFNFVFMAAAAAAAAAsgQAAAAAAABGAAAAAAAAAFBBVEhTAAAAAAAAAAAAAAD4BAAAAAAAAGIAAAAAAAAAU1BFQ1MAAAAAAAAAAAAAAFoFAAAAAAAATgAAAAAA" +
        "AABQSwECAAAKAAAAAACmSXdd/UZeUXAGAABwBgAAFAAOAAAAAAAAAAAAAAAAAAAAYmxlbmRlcl90cmlfY29sLnVzZGOGGQoAAAAAAAAAAAAAAFBLBQYAAAAA" +
        "AQABAFAAAACwBgAAAAA=")!

    private static let triColUSDA = ##"""
#usda 1.0
(
    defaultPrim = "root"
    doc = "Blender v5.2.2 LTS"
    metersPerUnit = 1
    upAxis = "Z"
)

def Xform "root" (
    prepend apiSchemas = ["ColorSpaceAPI"]
    customData = {
        dictionary Blender = {
            bool generated = 1
        }
    }
)
{
    uniform token colorSpace:name = "lin_rec709_scene"

    def Xform "Tri"
    {
        custom string userProperties:blender:object_name = "Tri"

        def Mesh "Tri" (
            active = true
            prepend apiSchemas = ["ColorSpaceAPI"]
        )
        {
            uniform token colorSpace:name = "lin_rec709_scene"
            float3[] extent = [(0, 0, 0), (1, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                interpolation = "faceVarying"
            )
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            color4f[] primvars:Col = [(1, 0, 0, 1), (0, 1, 0, 1), (0.5, 0.5, 0.5, 1)] (
                interpolation = "vertex"
            )
            uniform token subdivisionScheme = "none"
            custom string userProperties:blender:data_name = "Tri"
        }
    }
}

"""##

    private static let cubePaintUSDC = Data(base64Encoded:
        "UFhSLVVTREMACAAAAAAAAFEJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA" +
        "AAAAAAAACAAAACABAAAAAAAAAA4AAAABAAAAAAAAABAAAAABAAAAAAAAAAEAAAAkAAAAAAAAAAEAAAAAAAAAAgAAAAgAAAAAAAAAAQAAAAAAAUCRAAAAAAAf" +
        "AAEAAAAAAAAAFAAAAAEAAAAAAAAAFQAAAAsAAAAAAAAAGAAAABkAAAAaAAAAGwAAABwAAAAdAAAAEAAAAB4AAAAfAAAAIAAAACEAAAAAAAAAAAcAAgAAAAAA" +
        "AAAAAIC/AACAvwAAgL8AAIA/AACAPwAAgD8GAAAAAAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAABgAAAAAAAAAIQAAAAAAAAAA8A8BAAAAUVFRUVVVAAL/" +
        "AAT/AP7/APz/AgT+/Af8/gQAAAB/AAAAGAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAAAAAACAPwAA" +
        "AAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAAAA" +
        "AACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAAAAAAAAgL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAA" +
        "gL8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8IAAAAAAAAAAAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgL8AAIA/" +
        "AACAvwAAgL8AAIA/AACAPwAAgD8AAIC/AACAvwAAgD8AAIC/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPxgAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAA" +
        "gD8AAAAAAAAAAAAAgD8AAIA/AAAAAAAAAAAAAIA/AACAPwAAAAAAAAAAAACAPwAAAAAAAIA/AAAAAAAAgD8AAAAAAACAPwAAAAAAAIA/AAAAAAAAgD8AAAAA" +
        "AACAPwAAAAAAAIA/AAAAAAAAgD8AAAAAAAAAAAAAgD8AAIA/AAAAAAAAAAAAAIA/AACAPwAAAAAAAAAAAACAPwAAgD8AAAAAAAAAAAAAgD8AAIA/AACAPwAA" +
        "gD8AAAAAAACAPwAAgD8AAIA/AAAAAAAAgD8AAIA/AACAPwAAAAAAAIA/AACAPwAAgD8AAAAAAACAPwAAAAAAAIA/AACAPwAAgD8AAAAAAACAPwAAgD8AAIA/" +
        "AAAAAAAAgD8AAIA/AACAPwAAAAAAAIA/AACAPwAAgD8rvQA/K70APyu9AD8AAIA/K70APyu9AD8rvQA/AACAPyu9AD8rvQA/K70APwAAgD8rvQA/K70APyu9" +
        "AD8AAIA/DgAAAAAAAAAAAMA+AAAAAAAAwD4AAIA/AAAAPgAAQD8AACA/AAAAAAAAID8AAIA/AABgPwAAQD8AAMA+AACAPgAAAD4AAAA/AAAgPwAAgD4AAGA/" +
        "AAAAPwAAwD4AAEA/AAAgPwAAQD8AAMA+AAAAPwAAID8AAAA/GAAAAAAAAAAhAAAAAAAAAADwDwAAAABUVFRUVVUDBf4CBf8B/v8B+f0GBf74C/z8BjEAAAAA" +
        "AAAAJwIAAAAAAADAAQAAAAAAAADwlTstKQAAbWV0ZXJzUGVyVW5pdABkb2N1bWVudGF0aW9uAEJsZW5kZXIgdjUuMi4yIExUUwB1cEF4aXMAWgBwcmltQ2hp" +
        "bGRyZW4Acm9vdABkZWZhdWx0UHJpbQBzcGVjaWZpZXIAdHlwZU5hbWUAWGZvcm0AYXBpU2NoZW1hcwBDb2xvclNwYWNlQVBJAHByb3BlcnRpZXMAY29sb3JT" +
        "cGFjZTpuOgCkY3VzdG9tRGF0YZIA9QYAZ2VuZXJhdGVkAEN1YmUAdXNlclBBACI6YrgAgTpvYmplY3RfRQD6EU1lc2gAYWN0aXZlAHBvaW50cwBmYWNlVmVy" +
        "dGV4Q291EQBxSW5kaWNlc+YAeHZhcnM6c3QMACw6aSAA8RFQYWludABub3JtYWxzAGV4dGVudABzdWJkaXZpc2lvbvUAD6kABkJkYXRhpwD0AnRva2VuAHZh" +
        "cmlhYmlsaXR5VwHzEQBsaW5fcmVjNzA5X3NjZW5lAGZsb2F0M1tdAGludFtdfAAiM2YRAFJlcnBvbMYBAecAYmFyeWluZ/oAASQAAWUBEDQuAAEAAUBvcmQy" +
        "DQA0bm9ucQGAAHN0cmluZwAEAAAAAAAAAAQAAAASAAAAEwAAABQAAAAlAAAAAAAAAC8AAAAAAAAAAPAFGQAAAFVVVVUVURQRVQACAQICAgEFAPAF9gj8DPj8" +
        "GAHn5wDnBeLn5wAAC9zPAAAAAAAAAACRAACAPwAACUAAAQAxCkAGCAAxC0BYCAAxKQAICAATCyAAMypADBAAEWQIADEgAHEIADEpAH0IADEfALUIADMpAMEI" +
        "ABEWCAAxC0ABCAAxAUDNCAAxKQAiCAAEGAAzLEAlEAATJggAEQgxADMYgCcQABEoEAAyA4BICAAjoCgYABGAEAAzGIAqEAATKwgAIKgCCQAwGIAsBwBQAAtA" +
        "EAMJADAcgC0HAFAAC0CYBAkAQBSAEAUIADADoC4HAAWQADMBQDAQAIADAAAAAAAKQD8AAAAAAAAAQQAAAAAAAAAA8C8BAAAAARQARVVFQVFUBUVVVVVUEAD7" +
        "BvUGBf/1Bgf7BvEQ7hPsFeoVAukY5hvkHf0E4h/7BuAVDN8QEd4j2xEAAAAAAAAAEQAAAAAAAAASAAAAAAAAAADwAAEAAABRFQAAAAAD/g7zAhoAAAAAAAAA" +
        "APAI/////1VVUUUAAQfoJNcp3PEG/Ab7AvwTAAAAAAAAAADwAQAAAABRFQAAAf8B/wH/Af4RAAAAAAAAAAwAAAAAAAAAAKABAAAAAQAAAAAAGAAAAAAAAAAA" +
        "8AYEAAAAVUVFEAEABgcFBgADAwMDAwAOAAAAAAAAAADAAAAAAAUBAAAAB//7BgAAAAAAAABUT0tFTlMAAAAAAAAAAAAAQQUAAAAAAADYAQAAAAAAAFNUUklO" +
        "R1MAAAAAAAAAAAAZBwAAAAAAABgAAAAAAAAARklFTERTAAAAAAAAAAAAADEHAAAAAAAAFgEAAAAAAABGSUVMRFNFVFMAAAAAAAAARwgAAAAAAABRAAAAAAAA" +
        "AFBBVEhTAAAAAAAAAAAAAACYCAAAAAAAAGcAAAAAAAAAU1BFQ1MAAAAAAAAAAAAAAP8IAAAAAAAAUgAAAAAAAAA=")!

    private static let cubePaintUSDZ = Data(base64Encoded:
        "UEsDBAoAAAAAAKZJd10Je+mVGQoAABkKAAAXAAsAYmxlbmRlcl9jdWJlX3BhaW50LnVzZGOGGQcAAAAAAAAAAFBYUi1VU0RDAAgAAAAAAABRCQAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAgAAAAgAQAAAAAAAAAOAAAAAQAA" +
        "AAAAAAAQAAAAAQAAAAAAAAABAAAAJAAAAAAAAAABAAAAAAAAAAIAAAAIAAAAAAAAAAEAAAAAAAFAkQAAAAAAHwABAAAAAAAAABQAAAABAAAAAAAAABUAAAAL" +
        "AAAAAAAAABgAAAAZAAAAGgAAABsAAAAcAAAAHQAAABAAAAAeAAAAHwAAACAAAAAhAAAAAAAAAAAHAAIAAAAAAAAAAACAvwAAgL8AAIC/AACAPwAAgD8AAIA/" +
        "BgAAAAAAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAYAAAAAAAAACEAAAAAAAAAAPAPAQAAAFFRUVFVVQAC/wAE/wD+/wD8/wIE/vwH/P4EAAAAfwAAABgA" +
        "AAAAAAAAAACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAA" +
        "AAAAAAAAgD8AAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAA" +
        "gL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/" +
        "AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/CAAAAAAAAAAAAIC/AACAvwAAgL8AAIC/AACAvwAAgD8AAIC/AACAPwAAgL8AAIC/AACAPwAAgD8AAIA/AACAvwAA" +
        "gL8AAIA/AACAvwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8YAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAIA/AAAAAAAAAAAAAIA/AACAPwAAAAAAAAAA" +
        "AACAPwAAgD8AAAAAAAAAAAAAgD8AAAAAAACAPwAAAAAAAIA/AAAAAAAAgD8AAAAAAACAPwAAAAAAAIA/AAAAAAAAgD8AAAAAAACAPwAAAAAAAIA/AAAAAAAA" +
        "AAAAAIA/AACAPwAAAAAAAAAAAACAPwAAgD8AAAAAAAAAAAAAgD8AAIA/AAAAAAAAAAAAAIA/AACAPwAAgD8AAIA/AAAAAAAAgD8AAIA/AACAPwAAAAAAAIA/" +
        "AACAPwAAgD8AAAAAAACAPwAAgD8AAIA/AAAAAAAAgD8AAAAAAACAPwAAgD8AAIA/AAAAAAAAgD8AAIA/AACAPwAAAAAAAIA/AACAPwAAgD8AAAAAAACAPwAA" +
        "gD8AAIA/K70APyu9AD8rvQA/AACAPyu9AD8rvQA/K70APwAAgD8rvQA/K70APyu9AD8AAIA/K70APyu9AD8rvQA/AACAPw4AAAAAAAAAAADAPgAAAAAAAMA+" +
        "AACAPwAAAD4AAEA/AAAgPwAAAAAAACA/AACAPwAAYD8AAEA/AADAPgAAgD4AAAA+AAAAPwAAID8AAIA+AABgPwAAAD8AAMA+AABAPwAAID8AAEA/AADAPgAA" +
        "AD8AACA/AAAAPxgAAAAAAAAAIQAAAAAAAAAA8A8AAAAAVFRUVFVVAwX+AgX/Af7/Afn9BgX++Av8/AYxAAAAAAAAACcCAAAAAAAAwAEAAAAAAAAA8JU7LSkA" +
        "AG1ldGVyc1BlclVuaXQAZG9jdW1lbnRhdGlvbgBCbGVuZGVyIHY1LjIuMiBMVFMAdXBBeGlzAFoAcHJpbUNoaWxkcmVuAHJvb3QAZGVmYXVsdFByaW0Ac3Bl" +
        "Y2lmaWVyAHR5cGVOYW1lAFhmb3JtAGFwaVNjaGVtYXMAQ29sb3JTcGFjZUFQSQBwcm9wZXJ0aWVzAGNvbG9yU3BhY2U6bjoApGN1c3RvbURhdGGSAPUGAGdl" +
        "bmVyYXRlZABDdWJlAHVzZXJQQQAiOmK4AIE6b2JqZWN0X0UA+hFNZXNoAGFjdGl2ZQBwb2ludHMAZmFjZVZlcnRleENvdREAcUluZGljZXPmAHh2YXJzOnN0" +
        "DAAsOmkgAPERUGFpbnQAbm9ybWFscwBleHRlbnQAc3ViZGl2aXNpb271AA+pAAZCZGF0YacA9AJ0b2tlbgB2YXJpYWJpbGl0eVcB8xEAbGluX3JlYzcwOV9z" +
        "Y2VuZQBmbG9hdDNbXQBpbnRbXXwAIjNmEQBSZXJwb2zGAQHnAGJhcnlpbmf6AAEkAAFlARA0LgABAAFAb3JkMg0ANG5vbnEBgABzdHJpbmcABAAAAAAAAAAE" +
        "AAAAEgAAABMAAAAUAAAAJQAAAAAAAAAvAAAAAAAAAADwBRkAAABVVVVVFVEUEVUAAgECAgIBBQDwBfYI/Az4/BgB5+cA5wXi5+cAAAvczwAAAAAAAAAAkQAA" +
        "gD8AAAlAAAEAMQpABggAMQtAWAgAMSkACAgAEwsgADMqQAwQABFkCAAxIABxCAAxKQB9CAAxHwC1CAAzKQDBCAARFggAMQtAAQgAMQFAzQgAMSkAIggABBgA" +
        "MyxAJRAAEyYIABEIMQAzGIAnEAARKBAAMgOASAgAI6AoGAARgBAAMxiAKhAAEysIACCoAgkAMBiALAcAUAALQBADCQAwHIAtBwBQAAtAmAQJAEAUgBAFCAAw" +
        "A6AuBwAFkAAzAUAwEACAAwAAAAAACkA/AAAAAAAAAEEAAAAAAAAAAPAvAQAAAAEUAEVVRUFRVAVFVVVVVBAA+wb1BgX/9QYH+wbxEO4T7BXqFQLpGOYb5B39" +
        "BOIf+wbgFQzfEBHeI9sRAAAAAAAAABEAAAAAAAAAEgAAAAAAAAAA8AABAAAAURUAAAAAA/4O8wIaAAAAAAAAAADwCP////9VVVFFAAEH6CTXKdzxBvwG+wL8" +
        "EwAAAAAAAAAA8AEAAAAAURUAAAH/Af8B/wH+EQAAAAAAAAAMAAAAAAAAAACgAQAAAAEAAAAAABgAAAAAAAAAAPAGBAAAAFVFRRABAAYHBQYAAwMDAwMADgAA" +
        "AAAAAAAAwAAAAAAFAQAAAAf/+wYAAAAAAAAAVE9LRU5TAAAAAAAAAAAAAEEFAAAAAAAA2AEAAAAAAABTVFJJTkdTAAAAAAAAAAAAGQcAAAAAAAAYAAAAAAAA" +
        "AEZJRUxEUwAAAAAAAAAAAAAxBwAAAAAAABYBAAAAAAAARklFTERTRVRTAAAAAAAAAEcIAAAAAAAAUQAAAAAAAABQQVRIUwAAAAAAAAAAAAAAmAgAAAAAAABn" +
        "AAAAAAAAAFNQRUNTAAAAAAAAAAAAAAD/CAAAAAAAAFIAAAAAAAAAUEsBAgAACgAAAAAApkl3XQl76ZUZCgAAGQoAABcACwAAAAAAAAAAAAAAAAAAAGJsZW5k" +
        "ZXJfY3ViZV9wYWludC51c2RjhhkHAAAAAAAAAABQSwUGAAAAAAEAAQBQAAAAWQoAAAAA")!

    private static let cubePaintUSDA = ##"""
#usda 1.0
(
    defaultPrim = "root"
    doc = "Blender v5.2.2 LTS"
    metersPerUnit = 1
    upAxis = "Z"
)

def Xform "root" (
    prepend apiSchemas = ["ColorSpaceAPI"]
    customData = {
        dictionary Blender = {
            bool generated = 1
        }
    }
)
{
    uniform token colorSpace:name = "lin_rec709_scene"

    def Xform "Cube"
    {
        custom string userProperties:blender:object_name = "Cube"

        def Mesh "Cube" (
            active = true
            prepend apiSchemas = ["ColorSpaceAPI"]
        )
        {
            uniform token colorSpace:name = "lin_rec709_scene"
            float3[] extent = [(-1, -1, -1), (1, 1, 1)]
            int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
            int[] faceVertexIndices = [0, 1, 3, 2, 2, 3, 7, 6, 6, 7, 5, 4, 4, 5, 1, 0, 2, 6, 4, 0, 7, 3, 1, 5]
            normal3f[] normals = [(-1, 0, 0), (-1, 0, 0), (-1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, 1, 0), (0, 1, 0), (0, 1, 0), (1, 0, 0), (1, 0, 0), (1, 0, 0), (1, 0, 0), (0, -1, 0), (0, -1, 0), (0, -1, 0), (0, -1, 0), (0, 0, -1), (0, 0, -1), (0, 0, -1), (0, 0, -1), (0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                interpolation = "faceVarying"
            )
            point3f[] points = [(-1, -1, -1), (-1, -1, 1), (-1, 1, -1), (-1, 1, 1), (1, -1, -1), (1, -1, 1), (1, 1, -1), (1, 1, 1)]
            color4f[] primvars:Paint = [(1, 0, 0, 1), (1, 0, 0, 1), (1, 0, 0, 1), (1, 0, 0, 1), (0, 1, 0, 1), (0, 1, 0, 1), (0, 1, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1), (0, 0, 1, 1), (0, 0, 1, 1), (0, 0, 1, 1), (1, 1, 0, 1), (1, 1, 0, 1), (1, 1, 0, 1), (1, 1, 0, 1), (0, 1, 1, 1), (0, 1, 1, 1), (0, 1, 1, 1), (0, 1, 1, 1), (0.5028865, 0.5028865, 0.5028865, 1), (0.5028865, 0.5028865, 0.5028865, 1), (0.5028865, 0.5028865, 0.5028865, 1), (0.5028865, 0.5028865, 0.5028865, 1)] (
                interpolation = "faceVarying"
            )
            texCoord2f[] primvars:st = [(0.375, 0), (0.375, 1), (0.125, 0.75), (0.625, 0), (0.625, 1), (0.875, 0.75), (0.375, 0.25), (0.125, 0.5), (0.625, 0.25), (0.875, 0.5), (0.375, 0.75), (0.625, 0.75), (0.375, 0.5), (0.625, 0.5)] (
                interpolation = "faceVarying"
            )
            int[] primvars:st:indices = [0, 3, 8, 6, 6, 8, 13, 12, 12, 13, 11, 10, 10, 11, 4, 1, 7, 12, 10, 2, 13, 9, 5, 11]
            uniform token subdivisionScheme = "none"
            custom string userProperties:blender:data_name = "Cube"
        }
    }
}

"""##

    private static let triPlainUSDC = Data(base64Encoded:
        "UFhSLVVTREMACAAAAAAAADIFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA" +
        "AAAAAAAACAAAACABAAAAAAAAAA4AAAABAAAAAAAAABAAAAABAAAAAAAAAAEAAAAkAAAAAAAAAAEAAAAAAAAAAgAAAAgAAAAAAAAAAQAAAAAAAUCRAAAAAAAf" +
        "AAEAAAAAAAAAFAAAAAEAAAAAAAAAFQAAAAcAAAAAAAAAGAAAABkAAAAaAAAAGwAAABwAAAAdAAAAHgAAAAAAAAAAAAcCAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "gD8AAIA/AAAAAAEAAAAAAAAAAwAAAAMAAAAAAAAAAAAAAAEAAAACAAAAAwAAAAAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8IAAAA" +
        "AwAAAAAAAAAAAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAAAAAACAPwAAAAAsAAAAAAAAAOABAAAAAAAAmAEAAAAAAAAA8JU7LSkAAG1ldGVyc1BlclVuaXQA" +
        "ZG9jdW1lbnRhdGlvbgBCbGVuZGVyIHY1LjIuMiBMVFMAdXBBeGlzAFoAcHJpbUNoaWxkcmVuAHJvb3QAZGVmYXVsdFByaW0Ac3BlY2lmaWVyAHR5cGVOYW1l" +
        "AFhmb3JtAGFwaVNjaGVtYXMAQ29sb3JTcGFjZUFQSQBwcm9wZXJ0aWVzAGNvbG9yU3BhY2U6bjoApGN1c3RvbURhdGGSAPUFAGdlbmVyYXRlZABUcmkAdXNl" +
        "clBAACI6YrcAgTpvYmplY3RfRAD6EU1lc2gAYWN0aXZlAHBvaW50cwBmYWNlVmVydGV4Q291EQDxE0luZGljZXMAbm9ybWFscwBleHRlbnQAc3ViZGl2aXNp" +
        "b27FAB9legAFQmRhdGF4APQCdG9rZW4AdmFyaWFiaWxpdHknAfMRAGxpbl9yZWM3MDlfc2NlbmUAZmxvYXQzW10AaW50W118ACIzZhEAUmVycG9slgEBuABi" +
        "YXJ5aW5nywABJAA0bm9uKgGAAHN0cmluZwAEAAAAAAAAAAQAAAASAAAAEwAAABQAAAAgAAAAAAAAACcAAAAAAAAAAIACAAAABBRQVQEA8AoBAQH2CPwM+PwV" +
        "AeoW6hYA6hYF5RYACeEWqwAAAAAAAAAAkQAAgD8AAAlAAAEAMQpABggAMQtAWAgAMSkACAgAEwsgADMqQAwQABFkCAAxIABxCAAxKQB9CAAxHwC1CAAzKQDB" +
        "CAARFggAMQtAAQgAMQFAzQgAMSkAHwgABBgAMyxAIhAAEyMIABH4CAAxGIAkCAAxC0AYQQAzA4AkCAATJRgAETgQADMYgCcQABMoCAATaBgAEykQAAEPAEMA" +
        "AUArEACAAwAAAAAACkAzAAAAAAAAADEAAAAAAAAAAPAfAQAAAAEUAEVVUFAUVUFRVBAA+wb1BgX/9QYH8RDuE+wV6hUC6RjmG+QQDOMe4A0AAAAAAAAADQAA" +
        "AAAAAAAQAAAAAAAAAADgAQAAAFEVAAAAA/4K9wIVAAAAAAAAAADwA/////9VVVAAAQfoJNcp0AMD+xIAAAAAAAAAAPAAAAAAAFEVAAH/Af8B/wH+DQAAAAAA" +
        "AAALAAAAAAAAAACQAQAAAAEAAAAAFAAAAAAAAAAA8AIDAAAAVQVEAQAGBwUFBAQEAA0AAAAAAAAAALAAAAAABQEAAAf/+wYAAAAAAAAAVE9LRU5TAAAAAAAA" +
        "AAAAAJQBAAAAAAAAsAEAAAAAAABTVFJJTkdTAAAAAAAAAAAARAMAAAAAAAAYAAAAAAAAAEZJRUxEUwAAAAAAAAAAAABcAwAAAAAAAOoAAAAAAAAARklFTERT" +
        "RVRTAAAAAAAAAEYEAAAAAAAAQQAAAAAAAABQQVRIUwAAAAAAAAAAAAAAhwQAAAAAAABfAAAAAAAAAFNQRUNTAAAAAAAAAAAAAADmBAAAAAAAAEwAAAAAAAAA")!

    private static let triPlainUSDZ = Data(base64Encoded:
        "UEsDBAoAAAAAAKZJd13b4/9f+gUAAPoFAAAWAAwAYmxlbmRlcl90cmlfcGxhaW4udXNkY4YZCAAAAAAAAAAAAFBYUi1VU0RDAAgAAAAAAAAyBQAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAgAAAAgAQAAAAAAAAAOAAAAAQAA" +
        "AAAAAAAQAAAAAQAAAAAAAAABAAAAJAAAAAAAAAABAAAAAAAAAAIAAAAIAAAAAAAAAAEAAAAAAAFAkQAAAAAAHwABAAAAAAAAABQAAAABAAAAAAAAABUAAAAH" +
        "AAAAAAAAABgAAAAZAAAAGgAAABsAAAAcAAAAHQAAAB4AAAAAAAAAAAAHAgAAAAAAAAAAAAAAAAAAAAAAAAAAAIA/AACAPwAAAAABAAAAAAAAAAMAAAADAAAA" +
        "AAAAAAAAAAABAAAAAgAAAAMAAAAAAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/CAAAAAMAAAAAAAAAAAAAAAAAAAAAAAAAAACAPwAA" +
        "AAAAAAAAAAAAAAAAgD8AAAAALAAAAAAAAADgAQAAAAAAAJgBAAAAAAAAAPCVOy0pAABtZXRlcnNQZXJVbml0AGRvY3VtZW50YXRpb24AQmxlbmRlciB2NS4y" +
        "LjIgTFRTAHVwQXhpcwBaAHByaW1DaGlsZHJlbgByb290AGRlZmF1bHRQcmltAHNwZWNpZmllcgB0eXBlTmFtZQBYZm9ybQBhcGlTY2hlbWFzAENvbG9yU3Bh" +
        "Y2VBUEkAcHJvcGVydGllcwBjb2xvclNwYWNlOm46AKRjdXN0b21EYXRhkgD1BQBnZW5lcmF0ZWQAVHJpAHVzZXJQQAAiOmK3AIE6b2JqZWN0X0QA+hFNZXNo" +
        "AGFjdGl2ZQBwb2ludHMAZmFjZVZlcnRleENvdREA8RNJbmRpY2VzAG5vcm1hbHMAZXh0ZW50AHN1YmRpdmlzaW9uxQAfZXoABUJkYXRheAD0AnRva2VuAHZh" +
        "cmlhYmlsaXR5JwHzEQBsaW5fcmVjNzA5X3NjZW5lAGZsb2F0M1tdAGludFtdfAAiM2YRAFJlcnBvbJYBAbgAYmFyeWluZ8sAASQANG5vbioBgABzdHJpbmcA" +
        "BAAAAAAAAAAEAAAAEgAAABMAAAAUAAAAIAAAAAAAAAAnAAAAAAAAAACAAgAAAAQUUFUBAPAKAQEB9gj8DPj8FQHqFuoWAOoWBeUWAAnhFqsAAAAAAAAAAJEA" +
        "AIA/AAAJQAABADEKQAYIADELQFgIADEpAAgIABMLIAAzKkAMEAARZAgAMSAAcQgAMSkAfQgAMR8AtQgAMykAwQgAERYIADELQAEIADEBQM0IADEpAB8IAAQY" +
        "ADMsQCIQABMjCAAR+AgAMRiAJAgAMQtAGEEAMwOAJAgAEyUYABE4EAAzGIAnEAATKAgAE2gYABMpEAABDwBDAAFAKxAAgAMAAAAAAApAMwAAAAAAAAAxAAAA" +
        "AAAAAADwHwEAAAABFABFVVBQFFVBUVQQAPsG9QYF//UGB/EQ7hPsFeoVAukY5hvkEAzjHuANAAAAAAAAAA0AAAAAAAAAEAAAAAAAAAAA4AEAAABRFQAAAAP+" +
        "CvcCFQAAAAAAAAAA8AP/////VVVQAAEH6CTXKdADA/sSAAAAAAAAAADwAAAAAABRFQAB/wH/Af8B/g0AAAAAAAAACwAAAAAAAAAAkAEAAAABAAAAABQAAAAA" +
        "AAAAAPACAwAAAFUFRAEABgcFBQQEBAANAAAAAAAAAACwAAAAAAUBAAAH//sGAAAAAAAAAFRPS0VOUwAAAAAAAAAAAACUAQAAAAAAALABAAAAAAAAU1RSSU5H" +
        "UwAAAAAAAAAAAEQDAAAAAAAAGAAAAAAAAABGSUVMRFMAAAAAAAAAAAAAXAMAAAAAAADqAAAAAAAAAEZJRUxEU0VUUwAAAAAAAABGBAAAAAAAAEEAAAAAAAAA" +
        "UEFUSFMAAAAAAAAAAAAAAIcEAAAAAAAAXwAAAAAAAABTUEVDUwAAAAAAAAAAAAAA5gQAAAAAAABMAAAAAAAAAFBLAQIAAAoAAAAAAKZJd13b4/9f+gUAAPoF" +
        "AAAWAAwAAAAAAAAAAAAAAAAAAABibGVuZGVyX3RyaV9wbGFpbi51c2RjhhkIAAAAAAAAAAAAUEsFBgAAAAABAAEAUAAAADoGAAAAAA==")!

    private static let triPlainUSDA = ##"""
#usda 1.0
(
    defaultPrim = "root"
    doc = "Blender v5.2.2 LTS"
    metersPerUnit = 1
    upAxis = "Z"
)

def Xform "root" (
    prepend apiSchemas = ["ColorSpaceAPI"]
    customData = {
        dictionary Blender = {
            bool generated = 1
        }
    }
)
{
    uniform token colorSpace:name = "lin_rec709_scene"

    def Xform "Tri"
    {
        custom string userProperties:blender:object_name = "Tri"

        def Mesh "Tri" (
            active = true
        )
        {
            float3[] extent = [(0, 0, 0), (1, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1)] (
                interpolation = "faceVarying"
            )
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            uniform token subdivisionScheme = "none"
            custom string userProperties:blender:data_name = "Tri"
        }
    }
}

"""##
}
