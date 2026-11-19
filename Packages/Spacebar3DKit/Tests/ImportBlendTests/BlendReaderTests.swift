import Compression
import Foundation
import ImportBlend
import ImportRouter
import ModelCore
import simd
import XCTest

final class BlendReaderTests: XCTestCase {
    func testExternalImagesLoadFromThePermittedSidecarSource() throws {
        let data = BlendFixture.make(.layers, externalImage: "//art/picture.png")
        let missing = try BlendReader.scene(from: data)
        XCTAssertEqual(missing.diagnostics.missingResources, ["picture.png"])
        let recovered = try BlendReader.scene(from: data, sidecars: SidecarFiles(["art/picture.png": BlendFixture.packed]))
        XCTAssertTrue(recovered.diagnostics.missingResources.isEmpty)
        guard case .embedded(let bytes, _) = try XCTUnwrap(recovered.textures.first) else { return XCTFail("missing image") }
        XCTAssertEqual(Data(bytes), BlendFixture.packed)
    }

    func testExternalImagesUseTheRestrictedFolderWhenLoadingAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("art"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("model.blend")
        try BlendFixture.make(.layers, externalImage: "//art/picture.png").write(to: url)
        XCTAssertEqual(try BlendReader.load(url).diagnostics.missingResources, ["picture.png"])
        try BlendFixture.packed.write(to: folder.appendingPathComponent("art/picture.png"))
        let recovered = try ImportRouter.load(url, format: .blend)
        XCTAssertTrue(recovered.diagnostics.missingResources.isEmpty)
        XCTAssertEqual(recovered.textures.count, 1)
    }

    func testExternalImagesCannotEscapeTheModelFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.png")
        try BlendFixture.packed.write(to: outside)
        let url = folder.appendingPathComponent("model.blend")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.png"), withDestinationURL: outside)
        for path in ["//../outside.png", "//linked.png"] {
            try BlendFixture.make(.layers, externalImage: path).write(to: url)
            let scene = try BlendReader.load(url)
            XCTAssertTrue(scene.textures.isEmpty, path)
            XCTAssertEqual(scene.diagnostics.missingResources.count, 1, path)
        }
    }

    private func node(_ scene: ModelScene, _ name: String) throws -> ModelScene.Node { try XCTUnwrap(scene.nodes.first { $0.name == name }, name) }

    /// Everything the fixture's one mesh and its materials should come out as, whichever way the file lays the mesh out.
    private func check(_ layout: BlendFixture.Layout, file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = try BlendReader.scene(from: BlendFixture.make(layout))
        // Only what a viewport shows: not the disabled, the hidden, nor what is in a
        // collection the view layer hides or leaves out; and the armature is not a mesh.
        XCTAssertEqual(Set(scene.nodes.compactMap { $0.mesh == nil ? nil : $0.name }), ["Shown", "Child", "OnBone"], file: file, line: line)

        // Blender's Z is up; the scene's Y is. Under the node that turns it, objects stand as the file says.
        let up = scene.nodes[0]
        XCTAssertNil(up.parent, file: file, line: line)
        XCTAssertEqual(simd_length((up.transform * SIMD4<Float>(0, 0, 1, 0)) - SIMD4(0, 1, 0, 0)), 0, accuracy: 1e-6, file: file, line: line)
        let shown = try node(scene, "Shown")
        XCTAssertEqual(shown.parent, 0, file: file, line: line)
        XCTAssertEqual(shown.transform.columns.3, SIMD4(1, 2, 3, 1), file: file, line: line)
        // The child: a quarter turn about Z and ten along X, under its parent's place.
        let child = try node(scene, "Child").transform
        XCTAssertEqual(simd_length(child.columns.3 - SIMD4(11, 2, 3, 1)), 0, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(simd_length(child * SIMD4<Float>(1, 0, 0, 0) - SIMD4(0, 1, 0, 0)), 0, accuracy: 1e-5, file: file, line: line)
        // Held by a bone: at the bone's far end (0, 5, 0 in the armature, which is at 100), then its own place.
        XCTAssertEqual(simd_length(try node(scene, "OnBone").transform.columns.3 - SIMD4(100, 5, 1, 1)), 0, accuracy: 1e-5, file: file, line: line)

        // The mesh: one part for each material slot, faces as modelled.
        let mesh = scene.meshes[try XCTUnwrap(shown.mesh)]
        XCTAssertEqual(mesh.name, "Shape", file: file, line: line)
        XCTAssertEqual(mesh.parts.count, 2, file: file, line: line)
        let square = mesh.parts[0], triangle = mesh.parts[1]
        XCTAssertEqual(square.positions, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)], file: file, line: line)
        XCTAssertEqual(square.faceSizes, [4], "the square stays one face", file: file, line: line)
        XCTAssertEqual(square.triangleIndices, [0, 1, 2, 0, 2, 3], file: file, line: line)
        XCTAssertEqual(triangle.positions, [SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(0.5, 2, 1)], file: file, line: line)
        XCTAssertNil(triangle.faceSizes, file: file, line: line)
        // The square is flat: its own direction at every corner. The triangle is smooth:
        // where it meets the square the direction is shared, by area.
        for n in square.normals { XCTAssertEqual(simd_length(n - SIMD3(0, 0, 1)), 0, accuracy: 1e-5, file: file, line: line) }
        XCTAssertEqual(simd_length(triangle.normals[0] - simd_normalize(SIMD3<Float>(0, -1, 3))), 0, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(simd_length(triangle.normals[2] - simd_normalize(SIMD3<Float>(0, -1, 1))), 0, accuracy: 1e-5, file: file, line: line)
        // Texture coordinates of the map that is rendered, counted from the image's top.
        XCTAssertEqual(square.uv0.count, 4, file: file, line: line)
        XCTAssertEqual(simd_length(square.uv0[1] - SIMD2(0.1, 0.75)), 0, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(simd_length(triangle.uv0[2] - SIMD2(0.6, 0.75)), 0, accuracy: 1e-6, file: file, line: line)
        // The statistics count what was modelled, once for each place the mesh stands in.
        XCTAssertEqual(scene.topology.faces, 6, file: file, line: line)
        XCTAssertEqual(scene.topology.quads, 3, file: file, line: line)
        XCTAssertEqual(scene.topology.triangles, 3, file: file, line: line)
        XCTAssertEqual(scene.topology.vertices, 15, file: file, line: line)

        // Materials: the Principled node the output takes, not the stray one before it, and not the viewport's values.
        let red = scene.materials[try XCTUnwrap(square.material)]
        XCTAssertEqual(red.name, "Red", file: file, line: line)
        XCTAssertEqual(red.baseColor.x, 0.7354, accuracy: 1e-3, "half the light is this bright on screen", file: file, line: line)
        XCTAssertEqual(red.baseColor.y, 0, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual([red.metallic, red.roughness, red.opacity], [0.25, 0.75, 0.5], file: file, line: line)
        XCTAssertEqual(red.emissive, SIMD3(0, 0, 2), "the colour times its strength", file: file, line: line)
        XCTAssertTrue(red.doubleSided, file: file, line: line)
        XCTAssertNil(red.baseColorTexture, file: file, line: line)
        // An image packed into the file is used, and carries the colour by itself.
        let picture = scene.materials[try XCTUnwrap(triangle.material)]
        XCTAssertEqual(picture.name, "Picture", file: file, line: line)
        XCTAssertEqual(picture.baseColor, SIMD4(1, 1, 1, 1), file: file, line: line)
        guard case .embedded(let bytes, _) = scene.textures[try XCTUnwrap(picture.baseColorTexture)] else { return XCTFail("not the packed bytes", file: file, line: line) }
        XCTAssertEqual(Data(bytes), BlendFixture.packed, file: file, line: line)
        XCTAssertEqual(scene.materials.count, 2, "each material once, however many objects use it", file: file, line: line)
        XCTAssertEqual(scene.textures.count, 1, file: file, line: line)
    }

    func testAFileAsBlender2Point8WritesIt() throws { try check(.records) }
    func testAFileAsBlender4WritesIt() throws { try check(.layers) }
    func testAFileAsBlender5WritesIt() throws { try check(.attributes) }

    func testWhereTheFileKeepsAnObjectsPlaceThatIsUsed() throws {
        // Older files keep where Blender last had each object (constraints and animation counted in).
        let scene = try BlendReader.scene(from: BlendFixture.make(.records, storedPlacement: true))
        XCTAssertEqual(try node(scene, "Shown").transform.columns.3, SIMD4(7, 8, 9, 1))
    }

    func testAnObjectsOwnMaterialGoesOverTheMeshs() throws {
        let scene = try BlendReader.scene(from: BlendFixture.make(.layers, objectMaterial: true))
        let shown = scene.meshes[try XCTUnwrap(try node(scene, "Shown").mesh)], child = scene.meshes[try XCTUnwrap(try node(scene, "Child").mesh)]
        XCTAssertEqual(scene.materials[try XCTUnwrap(shown.parts[0].material)].name, "Picture", "the object's, in the slot it takes over")
        XCTAssertEqual(scene.materials[try XCTUnwrap(shown.parts[1].material)].name, "Picture", "the mesh's, in the other")
        XCTAssertEqual(scene.materials[try XCTUnwrap(child.parts[0].material)].name, "Red", "another object of the same mesh keeps the mesh's")
    }

    func testConcaveFacesInEveryMeshLayout() throws {
        for layout in [BlendFixture.Layout.records, .layers, .attributes] {
            for reversed in [false, true] {
                let scene = try BlendReader.scene(from: BlendFixture.make(layout, concave: true, reversed: reversed))
                let part = scene.meshes[try XCTUnwrap(try node(scene, "Shown").mesh)].parts[0]
                XCTAssertEqual(part.faceSizes, [4])
                XCTAssertEqual(part.triangleIndices.count, 6)
                var area: Float = 0
                for i in stride(from: 0, to: 6, by: 3) {
                    let a = part.positions[Int(part.triangleIndices[i])], b = part.positions[Int(part.triangleIndices[i+1])], c = part.positions[Int(part.triangleIndices[i+2])]
                    let cross = simd_cross(b-a,c-a).z
                    XCTAssertGreaterThan(cross * (reversed ? -1 : 1), 0)
                    area += abs(cross) / 2
                }
                XCTAssertEqual(area, 1, accuracy: 0.0001)
                XCTAssertEqual(part.uv0, [SIMD2(0,0.75), SIMD2(0.1,0.75), SIMD2(0.2,0.75), SIMD2(0.3,0.75)])
            }
        }
    }

    // MARK: Files that cannot be shown

    private func failure(_ data: Data) -> BlendReader.Failure? {
        do { _ = try BlendReader.scene(from: data); return nil } catch { return error as? BlendReader.Failure }
    }

    func testFilesThatAreNotOrCannotBeRead() throws {
        XCTAssertEqual(failure(Data()), .notBlend)
        XCTAssertEqual(failure(Data("BLENDER".utf8)), .notBlend)
        XCTAssertEqual(failure(Data(repeating: 0x41, count: 4096)), .notBlend)
        let good = BlendFixture.make(.layers)
        // Older than 2.80, and saved on a big-endian computer: said, not guessed at.
        var old = good; old.replaceSubrange(9..<12, with: Data("279".utf8))
        XCTAssertEqual(failure(old), .unsupported("it was saved by a Blender older than 2.80"))
        var other = good; other[8] = UInt8(ascii: "V")
        XCTAssertEqual(failure(other), .unsupported("it was saved on a big-endian computer"))
        // Compressed with Zstandard (Blender 3.0 on) by its first four bytes, and nothing that unpacks after them.
        XCTAssertEqual(failure(Data([0x28, 0xb5, 0x2f, 0xfd]) + Data(count: 64)), .damaged)
        // A file with objects and no scene, and one with nothing a viewport shows.
        XCTAssertEqual(failure(BlendFixture.make(.layers, withScene: false)), .empty)
        XCTAssertEqual(BlendReader.Failure.empty.errorDescription, "The Blender file has no visible mesh objects.")
    }

    func testADamagedFileFailsOrLoadsButNeverReadsOutsideItself() throws {
        for layout in [BlendFixture.Layout.records, .layers, .attributes] {
            let good = BlendFixture.make(layout)
            // Cut short anywhere.
            for length in stride(from: 12, to: good.count, by: max(1, good.count / 150)) { _ = failure(good.prefix(length)) }
            // Any byte turned over: counts, offsets and addresses that lead nowhere or back on themselves.
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<400 {
                var bad = good
                for _ in 0..<3 { bad[Int.random(in: 12..<bad.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator) }
                _ = failure(bad)
            }
            // Everything a count could be.
            for at in stride(from: 12, to: good.count - 4, by: max(4, good.count / 300)) {
                for value in [UInt32.max, 0x7fff_ffff, 0x8000_0000] {
                    var bad = good
                    withUnsafeBytes(of: value) { bad.replaceSubrange(at..<(at + 4), with: $0) }
                    _ = failure(bad)
                }
            }
        }
    }

    // MARK: Compressed files and the router

    func testAGzipCompressedFileIsUnpacked() throws {
        let plain = BlendFixture.make(.records)
        // The deflate stream, in gzip's wrapper with a file name in it.
        let capacity = plain.count + 4096
        var packed = Data(count: capacity)
        let written = packed.withUnsafeMutableBytes { out in plain.withUnsafeBytes { source in
            compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity, source.bindMemory(to: UInt8.self).baseAddress!, plain.count, nil, COMPRESSION_ZLIB)
        } }
        XCTAssertGreaterThan(written, 0)
        let gzip = Data([0x1f, 0x8b, 8, 8, 0, 0, 0, 0, 0, 3]) + Data("scene.blend".utf8) + Data([0]) + packed.prefix(written) + Data(count: 8)
        let scene = try BlendReader.scene(from: gzip)
        XCTAssertEqual(scene.topology.faces, 6)
        // Cut short, it is damaged, not a crash.
        XCTAssertNotNil(failure(gzip.prefix(gzip.count / 2)))
        XCTAssertNotNil(failure(Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3]) + Data(count: 32)))
    }

    func testAZstandardCompressedFileIsUnpacked() throws {
        let plain = BlendFixture.make(.attributes)
        let packed = ZstandardTests.stored(plain)
        let scene = try BlendReader.scene(from: packed), same = try BlendReader.scene(from: plain)
        XCTAssertEqual(scene.topology.faces, same.topology.faces)
        XCTAssertEqual(scene.topology.faces, 6)
        XCTAssertEqual(scene.meshes.count, same.meshes.count)
        XCTAssertEqual(failure(packed.prefix(packed.count / 2)), .damaged)
    }

    func testTheRouterReadsABlenderFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-\(UUID().uuidString).blend")
        defer { try? FileManager.default.removeItem(at: url) }
        try BlendFixture.make(.attributes).write(to: url)
        XCTAssertEqual(try ImportRouter.load(url, format: .blend).topology.faces, 6)
        XCTAssertTrue(ImportRouter.importable.contains(.blend))
    }
}
