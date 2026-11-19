import Compression
import CoreGraphics
import Foundation
import ImageIO
import ImportRouter
import ImportThreeMF
import ModelCore
import RenderMetal
import simd
import XCTest
import zlib

final class ThreeMFReaderTests: XCTestCase {
    func testLongDecimalCoordinatesUseTheFallbackWithoutOverflow() throws {
        for coordinate in ["999999999999999999999", "0.123456789012345678901234567890", "0.000000000000000000000000000001"] {
            let mesh = "<mesh><vertices><vertex x=\"\(coordinate)\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"0\" z=\"0\"/><vertex x=\"0\" y=\"1\" z=\"0\"/></vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh>"
            let data = package("<resources><object id=\"1\">\(mesh)</object></resources><build><item objectid=\"1\"/></build>")
            let scene = try ThreeMFReader.scene(from: data)
            XCTAssertEqual(scene.meshes.first?.parts.first?.positions.first?.x, Float(coordinate))
            XCTAssertEqual(scene.topology.faces, 1)
        }
    }

    /// A zip archive; files are deflated when `deflate` is set, otherwise stored.
    private func zip(_ files: [(name: String, text: String)], deflate: Bool = false) -> Data {
        zip(files.map { (name: $0.name, data: Data($0.text.utf8)) }, deflate: deflate)
    }

    private func zip(_ files: [(name: String, data: Data)], deflate: Bool = false) -> Data {
        var out = Data(), directory = Data()
        func put16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
        func put32(_ v: Int, _ d: inout Data) { put16(v & 0xffff, &d); put16((v >> 16) & 0xffff, &d) }
        for file in files {
            let name = Array(file.name.utf8), body = [UInt8](file.data)
            let crc = Int(body.withUnsafeBufferPointer { crc32(0, $0.baseAddress, UInt32($0.count)) })
            var packed = body
            if deflate {
                var buffer = [UInt8](repeating: 0, count: body.count + 1024)
                let written = compression_encode_buffer(&buffer, buffer.count, body, body.count, nil, COMPRESSION_ZLIB)
                packed = Array(buffer.prefix(written))
            }
            let method = deflate ? 8 : 0
            let offset = out.count
            put32(0x0403_4b50, &out); put16(20, &out); put16(0, &out); put16(method, &out); put16(0, &out); put16(0, &out)
            put32(crc, &out); put32(packed.count, &out); put32(body.count, &out); put16(name.count, &out); put16(0, &out)
            out.append(contentsOf: name); out.append(contentsOf: packed)
            put32(0x0201_4b50, &directory); put16(20, &directory); put16(20, &directory); put16(0, &directory); put16(method, &directory); put16(0, &directory); put16(0, &directory)
            put32(crc, &directory); put32(packed.count, &directory); put32(body.count, &directory); put16(name.count, &directory)
            put16(0, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory); put32(0, &directory); put32(offset, &directory)
            directory.append(contentsOf: name)
        }
        let start = out.count
        out.append(directory)
        put32(0x0605_4b50, &out); put16(0, &out); put16(0, &out); put16(files.count, &out); put16(files.count, &out)
        put32(directory.count, &out); put32(start, &out); put16(0, &out)
        return out
    }

    private let rels = ("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>")

    /// A box of 1 x 2 x 3 as the body of an object.
    private let boxMesh = """
    <mesh>
      <vertices>
        <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="1" y="2" z="0"/><vertex x="0" y="2" z="0"/>
        <vertex x="0" y="0" z="3"/><vertex x="1" y="0" z="3"/><vertex x="1" y="2" z="3"/><vertex x="0" y="2" z="3"/>
      </vertices>
      <triangles>
        <triangle v1="3" v2="2" v3="1"/><triangle v1="1" v2="0" v3="3"/><triangle v1="4" v2="5" v3="6"/><triangle v1="6" v2="7" v3="4"/>
        <triangle v1="0" v2="1" v3="5"/><triangle v1="5" v2="4" v3="0"/><triangle v1="1" v2="2" v3="6"/><triangle v1="6" v2="5" v3="1"/>
        <triangle v1="2" v2="3" v3="7"/><triangle v1="7" v2="6" v3="2"/><triangle v1="3" v2="0" v3="4"/><triangle v1="4" v2="7" v3="3"/>
      </triangles>
    </mesh>
    """

    private func model(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- made by hand -->\n<model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" xmlns:p=\"http://schemas.microsoft.com/3dmanufacturing/production/2015/06\" xmlns:m=\"http://schemas.microsoft.com/3dmanufacturing/material/2015/02\">\(body)</model>"
    }

    private func package(_ body: String, others: [(name: String, text: String)] = [], deflate: Bool = false) -> Data {
        zip([rels, ("3D/3dmodel.model", model(body))] + others, deflate: deflate)
    }

    func testABoxLoadsStoredOrDeflatedTurnedYUpAndIsClosed() throws {
        let body = "<resources><object id=\"1\" type=\"model\">\(boxMesh)</object></resources><build><item objectid=\"1\"/></build>"
        for deflate in [false, true] {
            let data = package(body, deflate: deflate)
            XCTAssertEqual(FormatDetector.detect(data, ext: "3mf"), .threeMF)
            let scene = try ThreeMFReader.scene(from: data)
            XCTAssertEqual(scene.topology.faces, 12, "deflated \(deflate)")
            XCTAssertEqual(scene.topology.vertices, 8)
            XCTAssertEqual(scene.topology.label, "Triangle")
            let part = try XCTUnwrap(scene.meshes.first?.parts.first)
            XCTAssertTrue(part.faceted)
            XCTAssertTrue(part.normals.isEmpty)
            // Z up in the file: (x, y, z) lands at (x, z, -y).
            let bounds = try XCTUnwrap(scene.bounds)
            XCTAssertLessThan(simd_distance(bounds.min, SIMD3(0, 0, -2)), 1e-4, "\(bounds)")
            XCTAssertLessThan(simd_distance(bounds.max, SIMD3(1, 3, 0)), 1e-4, "\(bounds)")
            let gpu = try MetalRenderer().makeScene(scene)
            XCTAssertEqual(gpu.triangleCount, 12)
            XCTAssertEqual(gpu.closedPartCount, 1)
        }
    }

    /// An object built from two placements of a box kept in another model file, itself
    /// placed twice by the build.
    func testComponentsSeparateFilesAndPlacements() throws {
        let part = model("<resources><object id=\"7\" type=\"model\">\(boxMesh)</object></resources>")
        let body = """
        <resources>
          <object id="2" type="model">
            <components>
              <component objectid="7" p:path="/3D/Objects/part.model"/>
              <component objectid="7" p:path="/3D/Objects/part.model" transform="1 0 0 0 1 0 0 0 1 10 0 0"/>
            </components>
          </object>
        </resources>
        <build>
          <item objectid="2"/>
          <item objectid="2" transform="2 0 0 0 2 0 0 0 2 0 100 0"/>
        </build>
        """
        let scene = try ThreeMFReader.scene(from: package(body, others: [("3D/Objects/part.model", part)]))
        XCTAssertEqual(scene.meshes.count, 1, "the box is kept once and placed four times")
        XCTAssertEqual(scene.topology.faces, 48)
        XCTAssertEqual(scene.topology.vertices, 32)
        // In the file's own axes the boxes span x 0...11 and, doubled and moved, x 0...22, y 100...104, z 0...6.
        let bounds = try XCTUnwrap(scene.bounds)
        XCTAssertLessThan(simd_distance(bounds.min, SIMD3(0, 0, -104)), 1e-3, "\(bounds)")
        XCTAssertLessThan(simd_distance(bounds.max, SIMD3(22, 6, 0)), 1e-3, "\(bounds)")
    }

    func testColoursPerObjectAndPerTriangle() throws {
        // The whole object in one base material: that is its material's colour.
        var body = """
        <resources>
          <basematerials id="5"><base name="red" displaycolor="#FF0000"/><base name="half blue" displaycolor="#0000FF80"/></basematerials>
          <object id="1" type="model" pid="5" pindex="1">\(boxMesh)</object>
        </resources>
        <build><item objectid="1"/></build>
        """
        var scene = try ThreeMFReader.scene(from: package(body))
        var part = try XCTUnwrap(scene.meshes.first?.parts.first)
        XCTAssertTrue(part.colors.isEmpty)
        var material = try XCTUnwrap(part.material.map { scene.materials[$0] })
        XCTAssertEqual(material.baseColor, SIMD4(0, 0, 1, 1))
        XCTAssertEqual(material.opacity, Float(0x80) / 255, accuracy: 1e-5)
        XCTAssertTrue(scene.hasTexturedAppearance)

        // One triangle in another colour, from a colour group: colours go per vertex, and
        // the vertices shared by both colours are repeated.
        let recoloured = boxMesh.replacingOccurrences(of: "<triangle v1=\"3\" v2=\"2\" v3=\"1\"/>", with: "<triangle v1=\"3\" v2=\"2\" v3=\"1\" pid=\"6\" p1=\"0\"/>")
        body = """
        <resources>
          <basematerials id="5"><base name="red" displaycolor="#FF0000"/></basematerials>
          <m:colorgroup id="6"><m:color color="#00FF00"/></m:colorgroup>
          <object id="1" type="model" pid="5" pindex="0">\(recoloured)</object>
        </resources>
        <build><item objectid="1"/></build>
        """
        scene = try ThreeMFReader.scene(from: package(body))
        part = try XCTUnwrap(scene.meshes.first?.parts.first)
        XCTAssertEqual(part.colors.count, part.positions.count)
        XCTAssertEqual(part.positions.count, 11, "three corners of the green triangle are also red corners")
        XCTAssertEqual(Set(part.colors), [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1)])
        XCTAssertEqual(part.triangleIndices.count, 36)
        XCTAssertEqual((0..<3).map { part.colors[Int(part.triangleIndices[$0])] }, [SIMD4<Float>](repeating: SIMD4(0, 1, 0, 1), count: 3))
        material = try XCTUnwrap(part.material.map { scene.materials[$0] })
        XCTAssertEqual(material.baseColor, SIMD4(1, 1, 1, 1))
        XCTAssertEqual(scene.topology.vertices, 8, "the file's own count")
    }

    func testDamagedAndHostilePackagesFailCleanly() throws {
        XCTAssertThrowsError(try ThreeMFReader.scene(from: Data())) { XCTAssertEqual($0 as? ThreeMFReader.Failure, .notAPackage) }
        XCTAssertThrowsError(try ThreeMFReader.scene(from: Data("not a zip at all, just text".utf8)))
        XCTAssertThrowsError(try ThreeMFReader.scene(from: zip([("readme.txt", "nothing")]))) { XCTAssertEqual($0 as? ThreeMFReader.Failure, .noModel) }
        XCTAssertThrowsError(try ThreeMFReader.scene(from: package("<resources/><build/>"))) { XCTAssertEqual($0 as? ThreeMFReader.Failure, .empty) }
        let whole = package("<resources><object id=\"1\">\(boxMesh)</object></resources><build><item objectid=\"1\"/></build>")
        XCTAssertThrowsError(try ThreeMFReader.scene(from: whole.prefix(whole.count / 2)))

        // Triangles that point outside the vertices are dropped; the rest shows.
        let bad = boxMesh.replacingOccurrences(of: "<triangle v1=\"3\" v2=\"2\" v3=\"1\"/>", with: "<triangle v1=\"3\" v2=\"2\" v3=\"99\"/><triangle v1=\"3\" v2=\"3\" v3=\"1\"/>")
        XCTAssertEqual(try ThreeMFReader.scene(from: package("<resources><object id=\"1\">\(bad)</object></resources><build><item objectid=\"1\"/></build>")).topology.faces, 11)

        // An object made of itself, and one that is missing: no endless loop, the box still shows.
        let loop = """
        <resources>
          <object id="1">\(boxMesh)</object>
          <object id="2"><components><component objectid="2"/><component objectid="1"/><component objectid="77"/></components></object>
        </resources>
        <build><item objectid="2"/></build>
        """
        XCTAssertGreaterThan(try ThreeMFReader.scene(from: package(loop)).topology.faces, 0)

        // Ten levels of ten components each ask for ten thousand million boxes.
        var nested = "<resources><object id=\"1\">\(boxMesh)</object>"
        for level in 2...11 {
            nested += "<object id=\"\(level)\"><components>" + String(repeating: "<component objectid=\"\(level - 1)\"/>", count: 10) + "</components></object>"
        }
        nested += "</resources><build><item objectid=\"11\"/></build>"
        XCTAssertThrowsError(try ThreeMFReader.scene(from: package(nested))) { XCTAssertEqual($0 as? ThreeMFReader.Failure, .tooLarge) }
    }

    /// A 2 x 2 PNG: the top row red, the bottom row see-through.
    private func png() throws -> Data {
        var pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0]
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func texturedPackage(_ resources: String, triangle: String, image: Bool = true) throws -> Data {
        let mesh = boxMesh.replacingOccurrences(of: "<triangle v1=\"3\" v2=\"2\" v3=\"1\"/>", with: triangle)
        let body = "<resources>\(resources)<object id=\"1\" type=\"model\">\(mesh)</object></resources><build><item objectid=\"1\"/></build>"
        var files = [(name: rels.0, data: Data(rels.1.utf8)), (name: "3D/3dmodel.model", data: Data(model(body).utf8))]
        if image { files.append((name: "3D/Textures/red.png", data: try png())) }
        return zip(files)
    }

    private let imageResources = "<m:texture2d id=\"2\" path=\"/3D/Textures/red.png\" contenttype=\"image/png\"/>"
        + "<m:texture2dgroup id=\"4\" texid=\"2\"><m:tex2coord u=\"0\" v=\"0\"/><m:tex2coord u=\"1\" v=\"0\"/><m:tex2coord u=\"0\" v=\"1\"/></m:texture2dgroup>"

    func testATriangleWithAnImageBecomesItsOwnPart() throws {
        let data = try texturedPackage(imageResources, triangle: "<triangle v1=\"3\" v2=\"2\" v3=\"1\" pid=\"4\" p1=\"0\" p2=\"1\" p3=\"2\"/>")
        let scene = try ThreeMFReader.scene(from: data)
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 2)
        let textured = try XCTUnwrap(parts.first { !$0.uv0.isEmpty })
        XCTAssertEqual(textured.triangleIndices.count, 3)
        // v is measured from the bottom in the file, from the top here.
        XCTAssertEqual(textured.uv0, [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0)])
        let material = try XCTUnwrap(textured.material.map { scene.materials[$0] })
        guard case .embedded(let bytes, _)? = material.baseColorTexture.map({ scene.textures[$0] }) else { return XCTFail("no image") }
        XCTAssertEqual(Data(bytes), try png())
        let plain = try XCTUnwrap(parts.first { $0.uv0.isEmpty })
        XCTAssertEqual(plain.triangleIndices.count, 33)
        XCTAssertNil(plain.material.flatMap { scene.materials[$0].baseColorTexture })
        XCTAssertEqual(scene.topology.faces, 12)
        XCTAssertEqual(try MetalRenderer().makeScene(scene).triangleCount, 12)

        // The image is not in the package: the triangle is drawn plain.
        let without = try ThreeMFReader.scene(from: try texturedPackage(imageResources, triangle: "<triangle v1=\"3\" v2=\"2\" v3=\"1\" pid=\"4\" p1=\"0\" p2=\"1\" p3=\"2\"/>", image: false))
        XCTAssertEqual(without.meshes.first?.parts.count, 1)
        XCTAssertTrue(without.textures.isEmpty)
        XCTAssertEqual(without.topology.faces, 12)
    }

    func testAColourWithAnImageOverItBecomesOneImage() throws {
        let resources = "<m:colorgroup id=\"1\"><m:color color=\"#0000FF\"/></m:colorgroup>" + imageResources
            + "<m:multiproperties id=\"6\" pids=\"1 4\"><m:multi pindices=\"0 0\"/><m:multi pindices=\"0 1\"/><m:multi pindices=\"0 2\"/></m:multiproperties>"
        let scene = try ThreeMFReader.scene(from: try texturedPackage(resources, triangle: "<triangle v1=\"3\" v2=\"2\" v3=\"1\" pid=\"6\" p1=\"0\" p2=\"1\" p3=\"2\"/>"))
        let textured = try XCTUnwrap(scene.meshes.first?.parts.first { !$0.uv0.isEmpty })
        let material = try XCTUnwrap(textured.material.map { scene.materials[$0] })
        XCTAssertEqual(material.baseColor, SIMD4(1, 1, 1, 1))
        guard case .pixels(let width, let height, let rgba)? = material.baseColorTexture.map({ scene.textures[$0] }) else { return XCTFail("no image made") }
        XCTAssertEqual([width, height], [2, 2])
        // Red where the image is, the blue beneath where it is see-through.
        XCTAssertEqual(Array(rgba[0..<3]), [255, 0, 0])
        XCTAssertEqual(Array(rgba[8..<11]), [0, 0, 255])
    }

    func testNumbersAndAttributesInAnyFormAndOrder() throws {
        let mesh = """
        <mesh>
          <vertices>
            <vertex z="1e2" y="+3.5" x="-0.125"/><vertex x=".5" y="2." z="-1.5E-1"/><vertex x="0.1" y="16777217" z="123456789012345678"/>
            <vertex x="7" y="oops" z="1"/>
          </vertices>
          <triangles><triangle p1="0" v3="2" pid="6" v1="0" v2="1"/></triangles>
        </mesh>
        """
        let body = "<resources><m:colorgroup id=\"6\"><m:color color=\"#00FF00\"/></m:colorgroup><object id=\"1\">\(mesh)</object></resources><build><item objectid=\"1\"/></build>"
        // Read with no turn applied: the part's own positions.
        let scene = try ThreeMFReader.scene(from: package(body))
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        XCTAssertEqual(part.positions.count, 4, "a vertex that cannot be read keeps its place")
        XCTAssertEqual(part.positions[0], SIMD3(-0.125, 3.5, 100))
        XCTAssertEqual(part.positions[1], SIMD3(0.5, 2, -0.15))
        XCTAssertEqual(part.positions[2], SIMD3(Float("0.1")!, Float(16777217 as Double), Float("123456789012345678")!))
        XCTAssertEqual(part.positions[3], .zero)
        XCTAssertEqual(part.triangleIndices, [0, 1, 2])
        XCTAssertEqual(part.material.map { scene.materials[$0].baseColor }, SIMD4(0, 1, 0, 1))
    }

    func testDisplayPropertiesGiveMetalRoughnessAndSeeThrough() throws {
        // Named by the base, defined after it, as the consortium's samples have it.
        var body = """
        <resources>
          <basematerials id="1"><base name="Metal" displaycolor="#C0C0C0" displaypropertiesid="9"/></basematerials>
          <object id="1" type="model" pid="1" pindex="0">\(boxMesh)</object>
          <m:pbmetallicdisplayproperties id="9"><m:pbmetallic name="m" metallicness="1" roughness="0.2"/></m:pbmetallicdisplayproperties>
        </resources>
        <build><item objectid="1"/></build>
        """
        var scene = try ThreeMFReader.scene(from: package(body))
        var material = try XCTUnwrap(scene.meshes.first?.parts.first?.material.map { scene.materials[$0] })
        XCTAssertEqual(material.metallic, 1)
        XCTAssertEqual(material.roughness, 0.2, accuracy: 1e-6)
        XCTAssertEqual(material.opacity, 1)
        XCTAssertTrue(material.authoredPBR)

        // Named by the group, one entry per base: two triangles in glass, the rest in plain red.
        let glass = boxMesh.replacingOccurrences(of: "<triangle v1=\"3\" v2=\"2\" v3=\"1\"/>", with: "<triangle v1=\"3\" v2=\"2\" v3=\"1\" pid=\"1\" p1=\"1\"/>")
        body = """
        <resources>
          <m:translucentdisplayproperties id="9">
            <m:translucent name="none" attenuation="0 0 0" refractiveindex="1 1 1" roughness="0.9"/>
            <m:translucent name="glass" attenuation="22.5 5.4 64.9" refractiveindex="1.5 1.5 1.5" roughness="0.1"/>
          </m:translucentdisplayproperties>
          <basematerials id="1" displaypropertiesid="9"><base name="a" displaycolor="#FF0000"/><base name="b" displaycolor="#00FF00"/></basematerials>
          <basematerials id="2"><base name="plain" displaycolor="#FF0000"/></basematerials>
          <object id="1" type="model" pid="2" pindex="0">\(glass)</object>
        </resources>
        <build><item objectid="1"/></build>
        """
        scene = try ThreeMFReader.scene(from: package(body))
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 2, "what looks different is a part of its own")
        let seeThrough = try XCTUnwrap(parts.first { $0.triangleIndices.count == 3 })
        material = try XCTUnwrap(seeThrough.material.map { scene.materials[$0] })
        XCTAssertEqual(material.baseColor, SIMD4(0, 1, 0, 1))
        XCTAssertEqual(material.roughness, 0.1, accuracy: 1e-6)
        XCTAssertLessThan(material.opacity, 1)
        let plain = try XCTUnwrap(parts.first { $0.triangleIndices.count == 33 }?.material.map { scene.materials[$0] })
        XCTAssertEqual(plain.opacity, 1)
        XCTAssertFalse(plain.authoredPBR)
        XCTAssertEqual(scene.topology.faces, 12)
    }

    func testTheRouterReadsA3MFFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-box-\(UUID().uuidString).3mf")
        defer { try? FileManager.default.removeItem(at: url) }
        try package("<resources><object id=\"1\">\(boxMesh)</object></resources><build><item objectid=\"1\"/></build>").write(to: url)
        XCTAssertEqual(try ImportRouter.load(url, format: .threeMF).topology.faces, 12)
    }
}
