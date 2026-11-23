import Foundation
@testable import ImportOBJ
import ModelCore
import simd
import XCTest

final class OBJReaderTests: XCTestCase {
    private func part(_ text: String) throws -> (ModelScene.MeshPart, ModelScene) {
        let scene = try OBJReader.scene(from: Data(text.utf8))
        return (try XCTUnwrap(scene.meshes.first?.parts.first), scene)
    }

    func testVerticalTabAndFormFeedSeparateOBJValues() throws {
        for gap in ["\u{000B}", "\u{000C}"] {
            let text = "v 0 0 0\(gap)\nv\(gap)1 0 0\nv 0\(gap)1 0\nvt 0\(gap)0\(gap)\nvn 0 0\(gap)1\(gap)\nf 1/1/1\(gap)2/1/1 3/1/1\(gap)\n"
            // Check progress before invoking the importer, so a tokenizer regression
            // fails this test without hanging the test process.
            let advances = Array(text.utf8).withUnsafeBufferPointer { buffer in
                var scanner = ByteScanner(buffer)
                while !scanner.isAtEnd {
                    let before = scanner.at
                    if scanner.tokenOnLine() == nil { scanner.skipLine() }
                    if scanner.at <= before { return false }
                }
                return true
            }
            guard advances else { XCTFail("scanner did not advance"); return }
            let (part, scene) = try part(text)
            XCTAssertEqual(part.positions, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
            XCTAssertEqual(part.normals, [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 3))
            XCTAssertTrue(part.uv0.isEmpty, "unused UVs are discarded when there is no texture")
            XCTAssertEqual(part.triangleIndices, [0, 1, 2])
            XCTAssertEqual(scene.topology.faces, 1)
        }
    }

    func testAQuadAndATriangleKeepTheirPolygons() throws {
        let (part, scene) = try part("""
        # a comment
        mtllib scene.mtl
        o thing
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 2 0 0
        usemtl red
        f 1 2 3 4
        f 2 5 3
        """)
        XCTAssertEqual(part.positions.count, 5)
        XCTAssertEqual(part.triangleIndices.count, 9)
        XCTAssertEqual(part.faceSizes, [4, 3])
        XCTAssertTrue(part.normals.isEmpty)
        XCTAssertFalse(part.faceted)
        XCTAssertEqual(scene.topology.faces, 2)
        XCTAssertEqual(scene.topology.vertices, 5)
        XCTAssertEqual(scene.topology.label, "Mixed")
        XCTAssertFalse(scene.hasTexturedAppearance)
        XCTAssertEqual(FormatDetector.detect(Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8), ext: "obj"), .obj)
    }

    func testNormalsTextureCoordinatesAndIndicesFromTheEnd() throws {
        let (part, _) = try part("""
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vt 0 0
        vn 0 0 1
        vn 0 1 0
        f 1/1/1 2/1/1 3/1/1
        f -3//2 -2//2 -1//2
        """)
        // The same position with another normal is another vertex.
        XCTAssertEqual(part.positions.count, 6)
        XCTAssertEqual(part.normals, [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 0)])
        XCTAssertEqual(part.triangleIndices, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(Array(part.positions[3...]), Array(part.positions[..<3]))
        XCTAssertNil(part.faceSizes)
    }

    /// The colours a file gives its vertices are how it looks. The grey that stands in for
    /// a missing material must not darken them, on faces any more than on points. A colour
    /// the material library names (Kd) is the author's and still tints them.
    func testColouredFacesAreNotTintedByTheStandInGrey() throws {
        let triangle = "v 0 0 0 1 0 0\nv 1 0 0 0 1 0\nv 0 1 0 0 0 1\n"
        XCTAssertEqual(try part(triangle + "f 1 2 3\n").1.materials.first?.baseColor, SIMD4(1, 1, 1, 1))
        XCTAssertEqual(try part("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n").1.materials.first?.baseColor, OBJReader.neutral.baseColor)

        // With a library: an entry that names no colour leaves the vertices as they are.
        let files = SidecarFiles(["look.mtl": Data("newmtl bare\nNs 10\nnewmtl tinted\nKd 0.5 0.25 1\n".utf8)])
        let text = "mtllib look.mtl\n" + triangle + "usemtl bare\nf 1 2 3\nusemtl tinted\nf 1 2 3\n"
        let scene = try OBJReader.scene(from: Data(text.utf8), sidecars: files)
        XCTAssertEqual(scene.materials.map(\.baseColor), [SIMD4(1, 1, 1, 1), SIMD4(0.5, 0.25, 1, 1)])
    }

    /// A material that glows says so with `Ke`: a lamp, a screen, a sign. Blender writes
    /// the colour times its strength; none, or black, is a material that does not glow.
    func testAMaterialsGlowIsRead() throws {
        let files = SidecarFiles(["look.mtl": Data("newmtl lamp\nKd 0.8 0.8 0.8\nKe 1 0.5 0.25\nnewmtl strong\nKe 3 0 0\nnewmtl dull\nKe 0 0 0\nnewmtl plain\nKd 1 1 1\n".utf8)])
        let text = "mtllib look.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\n" + ["lamp", "strong", "dull", "plain"].map { "usemtl \($0)\nf 1 2 3\n" }.joined()
        let scene = try OBJReader.scene(from: Data(text.utf8), sidecars: files)
        XCTAssertEqual(scene.materials.map(\.emissive), [SIMD3(1, 0.5, 0.25), SIMD3(3, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 0)])
    }

    /// How glossy a material is comes as `Ns`, as Blender writes it: a thousand times
    /// (1 - roughness) squared. It was not read, and every material was equally dull. A
    /// roughness of its own (`Pr`) is read in its place.
    func testAMaterialsShineIsRead() throws {
        let library = MTLReader.library(from: Data("""
        newmtl mirror
        Ns 1000
        newmtl half
        Ns 250
        newmtl dull
        Ns 0
        newmtl both
        Ns 1000
        Pr 0.4
        newmtl over
        Ns 4000
        newmtl none
        Kd 1 1 1
        """.utf8))
        func roughness(_ name: String) throws -> Float { try XCTUnwrap(library.materials[name]).material(named: name).roughness }
        XCTAssertEqual(try roughness("mirror"), 0, accuracy: 1e-6)
        XCTAssertEqual(try roughness("half"), 0.5, accuracy: 1e-6)
        XCTAssertEqual(try roughness("dull"), 1, accuracy: 1e-6)
        XCTAssertEqual(try roughness("both"), 0.4, accuracy: 1e-6)
        XCTAssertEqual(try roughness("over"), 0, accuracy: 1e-6)
        XCTAssertEqual(try roughness("none"), OBJReader.neutral.roughness)
    }

    /// A file without normals says where its surface is smooth with smoothing groups: the
    /// faces of one group are smooth across every edge between them, faces of different
    /// groups meet at a sharp edge, and a face in none (`s off`) is flat. Only "off" was
    /// read; the renderer then guessed by angle, cut a six-sided column into six flat sides
    /// and rounded an edge between two groups that the file calls sharp.
    func testSmoothingGroupsSayWhereTheSurfaceIsSmooth() throws {
        // A six-sided column, its sides in one group, its ends in none.
        var lines: [String] = []
        for y in [0, 1] { for k in 0..<6 { let a = Double(k) * .pi / 3; lines.append("v \(cos(a)) \(y) \(-sin(a))") } }
        lines.append("s 1")
        for k in 0..<6 { let n = (k + 1) % 6; lines.append("f \(k + 1) \(n + 1) \(n + 7) \(k + 7)") }
        lines.append("s off")
        lines.append("f 7 8 9 10 11 12")
        lines.append("f 6 5 4 3 2 1")
        let (column, _) = try part(lines.joined(separator: "\n"))
        XCTAssertEqual(column.normals.count, column.positions.count)
        guard column.normals.count == column.positions.count else { return }
        for t in stride(from: 0, to: column.triangleIndices.count, by: 3) {
            let v = (0..<3).map { Int(column.triangleIndices[t + $0]) }
            let p = v.map { column.positions[$0] }
            let facing = simd_normalize(simd_cross(p[1] - p[0], p[2] - p[0]))
            for k in v {
                let n = column.normals[k], at = column.positions[k]
                if abs(facing.y) > 0.9 {
                    XCTAssertEqual(simd_distance(n, SIMD3(0, facing.y > 0 ? 1 : -1, 0)), 0, accuracy: 1e-5, "an end is flat")
                } else {
                    XCTAssertEqual(simd_distance(n, simd_normalize(SIMD3(at.x, 0, at.z))), 0, accuracy: 1e-5, "the sides are round")
                }
            }
        }

        // Two faces thirty degrees apart: smooth across the edge in one group, sharp in two.
        let chamfer = "v -1 0 0\nv 0 0 0\nv 0 0 -1\nv -1 0 -1\nv 0.8660254 0.5 0\nv 0.8660254 0.5 -1\n"
        func normalsOnTheEdge(_ groups: (Int, Int)) throws -> [SIMD3<Float>] {
            let (two, _) = try part(chamfer + "s \(groups.0)\nf 1 2 3 4\ns \(groups.1)\nf 2 5 6 3\n")
            guard two.normals.count == two.positions.count else { return [] }
            return two.positions.indices.filter { two.positions[$0].x == 0 }.map { two.normals[$0] }
        }
        let tilted = simd_normalize(SIMD3<Float>(-0.5, 0.8660254, 0))
        let between = simd_normalize(SIMD3<Float>(0, 1, 0) + tilted)
        let smooth = try normalsOnTheEdge((1, 1))
        XCTAssertEqual(smooth.count, 2)
        for n in smooth { XCTAssertEqual(simd_distance(n, between), 0, accuracy: 1e-5) }
        let sharp = try normalsOnTheEdge((1, 2))
        XCTAssertEqual(sharp.count, 4, "each side has its own corners on the edge")
        XCTAssertEqual(sharp.filter { simd_distance($0, SIMD3(0, 1, 0)) < 1e-5 }.count, 2)
        XCTAssertEqual(sharp.filter { simd_distance($0, tilted) < 1e-5 }.count, 2)

        // A file that names no groups is left to the renderer, as before.
        XCTAssertTrue(try part(chamfer + "f 1 2 3 4\nf 2 5 6 3\n").0.normals.isEmpty)
    }

    func testColoursAfterThePositionAndWindowsLineEndings() throws {
        let (part, scene) = try part("v 0 0 0 1 0 0\r\nv 1 0 0 0 1 0\r\nv 0 1 0 0 0 1\r\nf 1 2 3\r\n")
        XCTAssertEqual(part.colors, [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1)])
        XCTAssertEqual(part.triangleIndices, [0, 1, 2])
        XCTAssertTrue(scene.hasTexturedAppearance)
        // A fourth value alone is a weight, not a colour.
        XCTAssertTrue(try self.part("v 0 0 0 1\nv 1 0 0 1\nv 0 1 0 1\nf 1 2 3\n").0.colors.isEmpty)
    }

    func testSmoothingOffMakesAFacetedPart() throws {
        XCTAssertTrue(try part("v 0 0 0\nv 1 0 0\nv 0 1 0\ns off\nf 1 2 3\n").0.faceted)
        XCTAssertTrue(try part("v 0 0 0\nv 1 0 0\nv 0 1 0\ns 0\nf 1 2 3\n").0.faceted)
        XCTAssertFalse(try part("v 0 0 0\nv 1 0 0\nv 0 1 0\ns 1\nf 1 2 3\n").0.faceted)
    }

    func testPositionsWithoutFacesAreAPointCloud() throws {
        let (part, scene) = try part("v 0 0 0\nv 1 2 3\nv 4 5 6\n")
        XCTAssertEqual(part.primitive, .points)
        XCTAssertEqual(part.positions.count, 3)
        XCTAssertEqual(scene.topology.vertices, 3)
        XCTAssertEqual(scene.topology.faces, 0)
    }

    func testFacesThatPointNowhereAreLeftOutAndAnEmptyFileFails() throws {
        let (part, _) = try part("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 9\nf 1 2 0\nf 1 2 3\nf 1 2\n")
        XCTAssertEqual(part.triangleIndices, [0, 1, 2])
        XCTAssertThrowsError(try OBJReader.scene(from: Data("# nothing\n".utf8)))
        XCTAssertThrowsError(try OBJReader.scene(from: Data()))
    }

    // MARK: Materials

    private static let twoMaterials = """
    mtllib look.mtl
    v 0 0 0
    v 1 0 0
    v 1 1 0
    v 0 1 0
    v 2 0 0
    vt 0 0
    vt 1 0
    vt 1 1
    vt 0 1
    usemtl skin
    f 1/1 2/2 3/3 4/4
    usemtl glass
    f 2/1 5/2 3/3
    usemtl skin
    f 1/1 3/3 4/4
    """

    private static let library = """
    # two materials
    newmtl skin
    Kd 0.2 0.4 0.6
    map_Kd -s 1 1 1 -clamp on my skin.png
    Ns 20
    newmtl glass
    Kd 1 0 0
    d 0.25
    Pr 0.1
    Pm 1
    newmtl unused
    Tr 0.2
    """

    func testEachMaterialIsAPartWithItsColourOpacityAndImage() throws {
        let files = SidecarFiles(["look.mtl": Data(Self.library.utf8), "my skin.png": Data([1, 2, 3])])
        let scene = try OBJReader.scene(from: Data(Self.twoMaterials.utf8), sidecars: files)
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(scene.diagnostics.missingResources.isEmpty)

        // The two runs of "skin" are one part; its image multiplies its colour.
        let skin = scene.materials[try XCTUnwrap(parts[0].material)]
        XCTAssertEqual(skin.name, "skin")
        XCTAssertEqual(skin.baseColor, SIMD4(0.2, 0.4, 0.6, 1))
        XCTAssertEqual(skin.baseColorTexture, 0)
        XCTAssertFalse(skin.authoredPBR)
        XCTAssertEqual(parts[0].triangleIndices.count, 9)
        XCTAssertEqual(parts[0].faceSizes, [4, 3])
        XCTAssertEqual(parts[0].positions.count, 4)
        // Rows of the image are counted from the top.
        XCTAssertEqual(parts[0].uv0, [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)])
        guard case .embedded(let bytes, _) = scene.textures[0] else { return XCTFail("the image is not carried") }
        XCTAssertEqual(bytes, [1, 2, 3])

        let glass = scene.materials[try XCTUnwrap(parts[1].material)]
        XCTAssertEqual(glass.baseColor, SIMD4(1, 0, 0, 1))
        XCTAssertEqual(glass.opacity, 0.25)
        XCTAssertEqual(glass.roughness, 0.1)
        XCTAssertEqual(glass.metallic, 1)
        XCTAssertTrue(glass.authoredPBR)
        XCTAssertNil(glass.baseColorTexture)
        XCTAssertTrue(parts[1].uv0.isEmpty, "no image, no texture coordinates")
        XCTAssertNil(parts[1].faceSizes)
        XCTAssertTrue(scene.hasTexturedAppearance)
        XCTAssertEqual(scene.topology.faces, 3)
        XCTAssertEqual(scene.topology.vertices, 5)
    }

    func testWithoutTheLibraryEverythingIsNeutralAndTheFileIsNamed() throws {
        let scene = try OBJReader.scene(from: Data(Self.twoMaterials.utf8), sidecars: SidecarFiles())
        XCTAssertEqual(scene.diagnostics.missingResources, ["look.mtl"])
        XCTAssertEqual(scene.meshes[0].parts.count, 2)
        XCTAssertFalse(scene.hasTexturedAppearance)
        XCTAssertTrue(scene.meshes[0].parts.allSatisfy { $0.uv0.isEmpty })
        // With nowhere to ask, nothing is reported missing.
        XCTAssertTrue(try OBJReader.scene(from: Data(Self.twoMaterials.utf8)).diagnostics.missingResources.isEmpty)
    }

    func testAnImageOutOfReachLeavesTheColourAndIsNamed() throws {
        let files = SidecarFiles(["look.mtl": Data(Self.library.utf8)])
        let scene = try OBJReader.scene(from: Data(Self.twoMaterials.utf8), sidecars: files)
        XCTAssertEqual(scene.diagnostics.missingResources, ["my skin.png"])
        let skin = scene.materials[try XCTUnwrap(scene.meshes[0].parts[0].material)]
        XCTAssertEqual(skin.baseColor, SIMD4(0.2, 0.4, 0.6, 1))
        XCTAssertNil(skin.baseColorTexture)
        XCTAssertTrue(scene.textures.isEmpty)
    }

    func testALibraryNamedAfterTheFacesIsStillRead() throws {
        let text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl a\nf 1/1 2/2 3/3\nmtllib late one.mtl\n"
        let files = SidecarFiles(["late one.mtl": Data("newmtl a\nmap_Kd t.jpg\n".utf8), "t.jpg": Data([9])])
        let scene = try OBJReader.scene(from: Data(text.utf8), sidecars: files)
        XCTAssertEqual(scene.meshes[0].parts[0].uv0.count, 3)
        XCTAssertEqual(scene.materials[0].baseColorTexture, 0)
        XCTAssertTrue(scene.diagnostics.missingResources.isEmpty)
    }

    func testSeveralLibrariesOnOneLineAndCornersWithoutCoordinates() throws {
        let text = "mtllib a.mtl b.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nusemtl two\nf 1/1 2 3\nusemtl one\nf 1 2 3\n"
        let files = SidecarFiles(["a.mtl": Data("newmtl one\nKd 0 1 0\n".utf8), "b.mtl": Data("newmtl two\nKd 0 0 1\nmap_Kd t.png\n".utf8), "t.png": Data([1])])
        let scene = try OBJReader.scene(from: Data(text.utf8), sidecars: files)
        // A part whose corners lack texture coordinates shows its colour, not the image.
        XCTAssertNil(scene.materials[0].baseColorTexture)
        XCTAssertEqual(scene.materials[0].baseColor, SIMD4(0, 0, 1, 1))
        XCTAssertTrue(scene.meshes[0].parts[0].uv0.isEmpty)
        XCTAssertEqual(scene.materials[1].baseColor, SIMD4(0, 1, 0, 1))
    }

    func testMapLinesAndOddLibraries() {
        XCTAssertEqual(MTLReader.imageName("wood.png"), "wood.png")
        XCTAssertEqual(MTLReader.imageName("-o 0.5 0.5 -mm 0 1 -bm 2 dark wood.png"), "dark wood.png")
        XCTAssertEqual(MTLReader.imageName("-s 2 2 2 123.png"), "123.png")
        XCTAssertNil(MTLReader.imageName("   "))
        let library = MTLReader.library(from: Data("Kd 1 1 1\nnewmtl a\nKd spectral file.rfl\nd -halo 0.5\nnewmtl a\nKd 1 0 0\nnewmtl g\nKd 0.5\nTr 7\n".utf8))
        XCTAssertEqual(library.materials.count, 2)
        XCTAssertNil(library.materials["a"]?.colour, "the first of two with one name counts; odd colours are not read")
        XCTAssertEqual(library.materials["a"]?.opacity, 0.5)
        XCTAssertEqual(library.materials["g"]?.colour, SIMD3(0.5, 0.5, 0.5))
        XCTAssertEqual(library.materials["g"]?.opacity, 0)
        XCTAssertTrue(MTLReader.library(from: Data()).materials.isEmpty)
    }

    func testTheFolderBesideAModelIsReadWithinItsRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-sidecars-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("model"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("textures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.twoMaterials.utf8).write(to: folder.appendingPathComponent("m.obj"))
        try Data(Self.library.utf8).write(to: folder.appendingPathComponent("look.mtl"))
        try Data([7]).write(to: folder.appendingPathComponent("textures/my skin.png"))
        try Data([8]).write(to: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))

        let sidecars = SidecarFolder(modelURL: folder.appendingPathComponent("m.obj"))
        XCTAssertEqual(sidecars.data(named: "C:\\work\\my skin.png"), Data([7]), "by its name, in a usual texture folder")
        XCTAssertNil(sidecars.data(named: "../outside/secret.png"))
        XCTAssertNil(sidecars.data(named: outside.appendingPathComponent("secret.png").path))
        XCTAssertNil(sidecars.data(named: "link.png"), "a link out of the folder is not followed")
        XCTAssertNil(sidecars.data(named: "textures"))
        XCTAssertNil(sidecars.data(named: ".."))

        let scene = try OBJReader.load(folder.appendingPathComponent("m.obj"))
        XCTAssertEqual(scene.materials[0].baseColorTexture, 0)
        XCTAssertTrue(scene.diagnostics.missingResources.isEmpty)
    }

    /// A survey writes its corners where they are on the map, millions of units out and a
    /// quarter of a unit apart. A Float so large comes in steps of half a unit, so the
    /// corners must be brought near the origin before they are rounded to one.
    func testAModelFarFromTheOriginKeepsItsShape() throws {
        let (part, _) = try part("""
        v 4194304.10 2097152.20 1048576.30
        v 4194304.35 2097152.20 1048576.30
        v 4194304.10 2097152.45 1048576.30
        f 1 2 3
        """)
        let p = part.positions
        XCTAssertEqual(simd_distance(p[0], p[1]), 0.25, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(p[0], p[2]), 0.25, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(p[1], p[2]), Float(0.125).squareRoot(), accuracy: 1e-5)
        XCTAssertLessThan(simd_reduce_max(simd_abs(p[0])), 1, "the model is read from its own middle")
    }

    /// A model that is large, not far, is read as its file gives it.
    func testALargeModelAboutTheOriginIsReadAsWritten() throws {
        let (part, _) = try part("v 4194304 0 0\nv -4194304 0 0\nv 0 2097152 0\nf 1 2 3\n")
        XCTAssertEqual(part.positions, [SIMD3(4_194_304, 0, 0), SIMD3(-4_194_304, 0, 0), SIMD3(0, 2_097_152, 0)])
    }
}
