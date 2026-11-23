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
        // The square is flat: its own direction at every corner. The triangle is smooth,
        // and a smooth face is not joined to a flat one: it keeps its own direction too.
        // Before Blender 4.1 (the oldest layout) it shared its vertices' one direction with
        // the square, each by the angle it fills there: a right angle, and acos(1/3).
        for n in square.normals { XCTAssertEqual(simd_length(n - SIMD3(0, 0, 1)), 0, accuracy: 1e-5, file: file, line: line) }
        let own = simd_normalize(SIMD3<Float>(0, -1, 1))
        let shared = layout == .records ? simd_normalize(SIMD3<Float>(0, 0, 1) * (.pi / 2) + own * acos(1.0 / 3)) : own
        XCTAssertEqual(simd_length(triangle.normals[0] - shared), 0, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(simd_length(triangle.normals[1] - shared), 0, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(simd_length(triangle.normals[2] - own), 0, accuracy: 1e-5, file: file, line: line)
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

    /// An image wired to the Principled node's Alpha as well as to its colour says where the
    /// surface is: cut out at the material's threshold, blended where the material blends,
    /// and cut out at a half where the file asks for neither. Not wired, it is solid.
    func testAlphaWiredToTheColourImageCutsOutOrBlends() throws {
        for layout in [BlendFixture.Layout.records, .layers, .attributes] {
            let cases: [(method: Int, cutoff: Float?, blends: Bool)] = [(3, 0.25, false), (5, nil, true), (0, 0.5, false), (4, 0.5, false)]
            for expected in cases {
                let scene = try BlendReader.scene(from: BlendFixture.make(layout, pictureAlpha: (expected.method, 0.25)))
                let picture = try XCTUnwrap(scene.materials.first { $0.name == "Picture" })
                XCTAssertEqual(picture.alphaCutoff, expected.cutoff, "\(layout), method \(expected.method)")
                XCTAssertEqual(picture.alphaBlend, expected.blends, "\(layout), method \(expected.method)")
                XCTAssertEqual(picture.opacity, 1)
                XCTAssertNotNil(picture.baseColorTexture)
            }
            let solid = try XCTUnwrap(try BlendReader.scene(from: BlendFixture.make(layout)).materials.first { $0.name == "Picture" })
            XCTAssertNil(solid.alphaCutoff)
            XCTAssertFalse(solid.alphaBlend)
        }
    }

    /// From Blender 4.2 a material says "blended" in a field of its own. The older blend
    /// method beside it may say the same or be left at zero, as Blender 5.2 leaves it when
    /// the older setting is the one that was changed.
    func testAlphaWiredToTheColourImageBlendsWhereANewerFileSaysBlended() throws {
        for layout in [BlendFixture.Layout.layers, .attributes] {
            let cases: [(method: Int, surface: Int, cutoff: Float?, blends: Bool)] = [(0, 1, nil, true), (5, 1, nil, true), (4, 0, 0.5, false), (0, 0, 0.5, false)]
            for expected in cases {
                let scene = try BlendReader.scene(from: BlendFixture.make(layout, pictureAlpha: (expected.method, 0.5), surfaceMethod: expected.surface))
                let picture = try XCTUnwrap(scene.materials.first { $0.name == "Picture" })
                XCTAssertEqual(picture.alphaBlend, expected.blends, "\(layout), method \(expected.method), surface \(expected.surface)")
                XCTAssertEqual(picture.alphaCutoff, expected.cutoff, "\(layout), method \(expected.method), surface \(expected.surface)")
                XCTAssertNotNil(picture.baseColorTexture)
            }
        }
    }

    /// The mesh of the object "Shown": its square and its triangle.
    private func shape(_ data: Data) throws -> (square: ModelScene.MeshPart, triangle: ModelScene.MeshPart, scene: ModelScene) {
        let scene = try BlendReader.scene(from: data)
        let mesh = scene.meshes[try XCTUnwrap(try node(scene, "Shown").mesh)]
        return (mesh.parts[0], mesh.parts[1], scene)
    }

    private let ownOfTriangle = simd_normalize(SIMD3<Float>(0, -1, 1))
    /// Where the square and the triangle are joined: each by the angle it fills there.
    private var joined: SIMD3<Float> { simd_normalize(SIMD3<Float>(0, 0, 1) * (.pi / 2) + ownOfTriangle * acos(1.0 / 3)) }

    /// A Mirror modifier's other half is shown: each face again across the object's own
    /// plane, facing the same way out, with the corners on the plane where they were.
    func testAMirrorModifierShowsTheOtherHalf() throws {
        for layout in [BlendFixture.Layout.records, .layers, .attributes] {
            // Bit 3: across X. Bit 6 is set in every file Blender writes (vertex groups).
            let (square, triangle, scene) = try shape(BlendFixture.make(layout, modifiers: [.mirror(flag: 1 << 3 | 1 << 6)]))
            XCTAssertEqual(square.positions, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(-1, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 0)], "\(layout)")
            XCTAssertEqual(triangle.positions, [SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(0.5, 2, 1), SIMD3(-0.5, 2, 1), SIMD3(-1, 1, 0), SIMD3(0, 1, 0)], "\(layout)")
            XCTAssertEqual(square.faceSizes, [4, 4], "\(layout)")
            XCTAssertEqual(square.triangleIndices.count, 12, "\(layout)")
            for n in square.normals { XCTAssertEqual(simd_distance(n, SIMD3(0, 0, 1)), 0, accuracy: 1e-5, "\(layout)") }
            XCTAssertEqual(simd_distance(triangle.normals[3], simd_normalize(SIMD3<Float>(0, -1, 1))), 0, accuracy: 1e-5, "the far corner of the copy, \(layout)")
            // A copied corner has its original's place in the image.
            XCTAssertEqual(square.uv0[4], square.uv0[3], "\(layout)"); XCTAssertEqual(square.uv0[7], square.uv0[0], "\(layout)")
            // What was modelled is counted, not what a modifier adds.
            XCTAssertEqual(scene.topology.faces, try BlendReader.scene(from: BlendFixture.make(layout)).topology.faces, "\(layout)")
            // Across X and Y, not merged: four of each face, and no corner shared.
            let four = try shape(BlendFixture.make(layout, modifiers: [.mirror(flag: 1 << 3 | 1 << 4 | 1 << 7)]))
            XCTAssertEqual(four.square.positions.count, 16, "\(layout)")
            XCTAssertEqual(four.square.positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }, SIMD3(-1, -1, 0), "\(layout)")
            // A mirror that only works when rendering is not what the viewport shows.
            XCTAssertEqual(try shape(BlendFixture.make(layout, modifiers: [.mirror(flag: 1 << 3, shown: false)])).square.positions.count, 4, "\(layout)")
        }
    }

    /// A modifier of a kind that is not applied is said to have been left out.
    func testAModifierThatIsNotAppliedIsNamedAsLeftOut() throws {
        XCTAssertEqual(try BlendReader.scene(from: BlendFixture.make(.layers, modifiers: [.other])).diagnostics.skippedFeatures, ["modifiers"])
        XCTAssertEqual(try BlendReader.scene(from: BlendFixture.make(.layers, modifiers: [.mirror(flag: 1 << 3)])).diagnostics.skippedFeatures, [])
        XCTAssertEqual(try BlendReader.scene(from: BlendFixture.make(.layers)).diagnostics.skippedFeatures, [])
    }

    /// Two smooth faces share a direction where they meet, and an edge marked sharp parts them.
    func testAnEdgeMarkedSharpPartsTwoSmoothFaces() throws {
        for layout in [BlendFixture.Layout.layers, .attributes] {
            let smooth = try shape(BlendFixture.make(layout, smoothSquare: true))
            XCTAssertEqual(simd_distance(smooth.triangle.normals[0], joined), 0, accuracy: 1e-5, "\(layout)")
            XCTAssertEqual(simd_distance(smooth.square.normals[2], joined), 0, accuracy: 1e-5, "\(layout)")
            XCTAssertEqual(simd_distance(smooth.square.normals[0], SIMD3(0, 0, 1)), 0, accuracy: 1e-5, "\(layout)")
            // Edge 2 is the one the square and the triangle share.
            let parted = try shape(BlendFixture.make(layout, smoothSquare: true, sharpEdge: 2))
            XCTAssertEqual(simd_distance(parted.triangle.normals[0], ownOfTriangle), 0, accuracy: 1e-5, "\(layout)")
            XCTAssertEqual(simd_distance(parted.square.normals[2], SIMD3(0, 0, 1)), 0, accuracy: 1e-5, "\(layout)")
            // A mark on another edge parts nothing here.
            XCTAssertEqual(simd_distance(try shape(BlendFixture.make(layout, smoothSquare: true, sharpEdge: 0)).triangle.normals[0], joined), 0, accuracy: 1e-5, "\(layout)")
        }
    }


    /// Custom normals packed as two numbers a corner are unpacked. The square is flat and
    /// lies in the plane of z = 0, so each of its corners has a quarter turn of room either
    /// way: half the first number leans the normal 45 degrees along the corner's first
    /// edge, and all of the second turns that lean to its other edge.
    func testCustomNormalsPackedAsTwoNumbersAreUnpacked() throws {
        // A Blender 4 file keeps them in a layer of their own kind, or in one known by its name.
        for (layout, named) in [(BlendFixture.Layout.layers, false), (.layers, true), (.attributes, false)] {
            let numbers: [Int16] = [16384, 0, 16384, 32767, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            let (square, triangle, _) = try shape(BlendFixture.make(layout, customNormals: .packed(numbers, named: named)))
            // Corner 0 is at the origin, and its first edge runs along X.
            XCTAssertEqual(simd_distance(square.normals[0], simd_normalize(SIMD3(1, 0, 1))), 0, accuracy: 1e-3, "\(layout)")
            // Corner 1 is at 1, 0, 0: its first edge runs along Y, and its other back along X.
            XCTAssertEqual(simd_distance(square.normals[1], simd_normalize(SIMD3(-1, 0, 1))), 0, accuracy: 1e-3, "\(layout)")
            XCTAssertEqual(simd_distance(square.normals[2], SIMD3(0, 0, 1)), 0, accuracy: 1e-5, "no custom normal there, \(layout)")
            XCTAssertEqual(simd_distance(triangle.normals[0], ownOfTriangle), 0, accuracy: 1e-5, "\(layout)")
        }
    }

    /// A Mirror modifier packs each custom normal again for the copy, before it joins the
    /// two halves. Away from the mirror's plane a copy has its original's normal turned
    /// over. On the plane, where a smooth surface runs on into its copy, the two halves'
    /// numbers are averaged and read in the joined fan, and the normal is no longer the one
    /// that was set: that is what Blender shows. Expected here is what Blender 5.2 gives
    /// for this mesh with these numbers.
    func testAMirrorCopiesPackedCustomNormalsAsBlenderDoes() throws {
        let numbers: [Int16] = [9000, 4000, 12000, -8000, 7000, 15000, -5000, 6000, 11000, 2000, 3000, -12000, 8000, 9000]
        func assertEqual(_ normals: [SIMD3<Float>], _ expected: [SIMD3<Float>], _ message: String, line: UInt = #line) {
            XCTAssertEqual(normals.count, expected.count, message, line: line)
            for (i, (n, e)) in zip(normals, expected).enumerated() { XCTAssertEqual(simd_distance(n, e), 0, accuracy: 2e-3, "corner \(i), \(message)", line: line) }
        }
        for layout in [BlendFixture.Layout.layers, .attributes] {
            // Both faces smooth: the square runs on into its copy across the plane of x = 0.
            let joined = try shape(BlendFixture.make(layout, smoothSquare: true, modifiers: [.mirror(flag: 1 << 3)], customNormals: .packed(numbers)))
            assertEqual(joined.square.normals, [SIMD3(0.0, 0.4182, 0.9084), SIMD3(0.4967, 0.222, 0.8391), SIMD3(-0.0957, -0.1639, 0.9818), SIMD3(0.0, -0.4482, 0.8939), SIMD3(0.0, -0.4482, 0.8939), SIMD3(0.0957, -0.164, 0.9818), SIMD3(-0.4967, 0.222, 0.8391), SIMD3(0.0, 0.4182, 0.9084)], "\(layout)")
            assertEqual(joined.triangle.normals, [SIMD3(0.0, -0.4482, 0.8939), SIMD3(-0.0957, -0.1639, 0.9818), SIMD3(-0.0571, -0.9172, 0.3943), SIMD3(0.0571, -0.9172, 0.3943), SIMD3(0.0957, -0.164, 0.9818), SIMD3(0.0, -0.4482, 0.8939)], "\(layout)")
            // The square flat: each of its corners is alone, and its copy's is that turned over.
            let flat = try shape(BlendFixture.make(layout, modifiers: [.mirror(flag: 1 << 3)], customNormals: .packed(numbers)))
            assertEqual(flat.square.normals, [SIMD3(0.4105, 0.0797, 0.9084), SIMD3(0.4967, 0.222, 0.8391), SIMD3(-0.2478, -0.2169, 0.9442), SIMD3(-0.1869, 0.6316, 0.7524), SIMD3(0.1869, 0.6316, 0.7524), SIMD3(0.2478, -0.2169, 0.9442), SIMD3(-0.4967, 0.222, 0.8391), SIMD3(-0.4105, 0.0797, 0.9084)], "\(layout)")
            assertEqual(flat.triangle.normals, [SIMD3(0.5018, -0.5843, 0.6378), SIMD3(0.1431, -0.6937, 0.7059), SIMD3(-0.0571, -0.9172, 0.3943), SIMD3(0.0571, -0.9172, 0.3943), SIMD3(-0.143, -0.6937, 0.7059), SIMD3(-0.5018, -0.5843, 0.6378)], "\(layout)")
            // The two halves not joined (bit 7): turned over everywhere.
            let apart = try shape(BlendFixture.make(layout, smoothSquare: true, modifiers: [.mirror(flag: 1 << 3 | 1 << 7)], customNormals: .packed(numbers)))
            assertEqual(apart.square.normals, [SIMD3(0.4105, 0.0797, 0.9084), SIMD3(0.4967, 0.222, 0.8391), SIMD3(-0.0957, -0.1639, 0.9818), SIMD3(0.0399, -0.4404, 0.8969), SIMD3(-0.0399, -0.4403, 0.897), SIMD3(0.0957, -0.164, 0.9818), SIMD3(-0.4967, 0.222, 0.8391), SIMD3(-0.4105, 0.0797, 0.9084)], "\(layout)")
            assertEqual(apart.triangle.normals, [SIMD3(0.0399, -0.4404, 0.8969), SIMD3(-0.0957, -0.1639, 0.9818), SIMD3(-0.0571, -0.9172, 0.3943), SIMD3(0.0571, -0.9172, 0.3943), SIMD3(0.0957, -0.164, 0.9818), SIMD3(-0.0399, -0.4403, 0.897)], "\(layout)")
        }
    }

    /// A custom normal kept as a direction is copied by a Mirror modifier as it is, not
    /// turned over: Blender 5.2 shows the copy lit as its original is.
    func testAMirrorCopiesCustomNormalsKeptAsDirectionsUnturned() throws {
        let tilts: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(0.6, 0.8, 0), SIMD3(0, 0.6, 0.8), SIMD3(0.8, 0, 0.6), SIMD3(-1, 0, 0)]
        func numbers(_ count: Int) -> [Float] { tilts.prefix(count).flatMap { [$0.x, $0.y, $0.z] } }
        for layout in [BlendFixture.Layout.layers, .attributes] {
            // A copy's corners are its original's in the opposite order.
            let corners = try shape(BlendFixture.make(layout, modifiers: [.mirror(flag: 1 << 3)], customNormals: .corners(numbers(7))))
            XCTAssertEqual(corners.square.normals, Array(tilts[0..<4]) + tilts[0..<4].reversed(), "\(layout)")
            XCTAssertEqual(corners.triangle.normals, Array(tilts[4..<7]) + tilts[4..<7].reversed(), "\(layout)")
            let vertices = try shape(BlendFixture.make(layout, modifiers: [.mirror(flag: 1 << 3)], customNormals: .vertices(numbers(5))))
            XCTAssertEqual(vertices.triangle.normals, [tilts[3], tilts[2], tilts[4], tilts[4], tilts[2], tilts[3]], "\(layout)")
            let faces = try shape(BlendFixture.make(layout, modifiers: [.mirror(flag: 1 << 3)], customNormals: .faces(numbers(2))))
            XCTAssertEqual(faces.triangle.normals, [SIMD3<Float>](repeating: tilts[1], count: 6), "\(layout)")
        }
    }

    /// Custom normals kept as directions are taken as they are, whether there is one for
    /// each corner, each vertex or each face.
    func testCustomNormalsKeptAsDirectionsAreTakenAsTheyAre() throws {
        let tilts: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(0.6, 0.8, 0), SIMD3(0, 0.6, 0.8), SIMD3(0.8, 0, 0.6), SIMD3(-1, 0, 0)]
        func numbers(_ count: Int) -> [Float] { tilts.prefix(count).flatMap { [$0.x, $0.y, $0.z] } }
        func assertEqual(_ normals: [SIMD3<Float>], _ expected: [SIMD3<Float>], _ message: String, line: UInt = #line) {
            XCTAssertEqual(normals.count, expected.count, message, line: line)
            for (n, e) in zip(normals, expected) { XCTAssertEqual(simd_distance(n, e), 0, accuracy: 1e-5, message, line: line) }
        }
        for layout in [BlendFixture.Layout.layers, .attributes] {
            let corners = try shape(BlendFixture.make(layout, customNormals: .corners(numbers(7))))
            assertEqual(corners.square.normals, Array(tilts[0..<4]), "\(layout)")
            assertEqual(corners.triangle.normals, Array(tilts[4..<7]), "\(layout)")
            // The triangle's corners are at vertices 3, 2 and 4.
            let vertices = try shape(BlendFixture.make(layout, customNormals: .vertices(numbers(5))))
            assertEqual(vertices.square.normals, Array(tilts[0..<4]), "\(layout)")
            assertEqual(vertices.triangle.normals, [tilts[3], tilts[2], tilts[4]], "\(layout)")
            let faces = try shape(BlendFixture.make(layout, customNormals: .faces(numbers(2))))
            assertEqual(faces.square.normals, [SIMD3<Float>](repeating: tilts[0], count: 4), "\(layout)")
            assertEqual(faces.triangle.normals, [SIMD3<Float>](repeating: tilts[1], count: 3), "\(layout)")
        }
    }

    /// The Smooth by Angle modifier (what "Shade Auto Smooth" adds since Blender 4.1) parts
    /// faces that meet at more than its angle. The square and the triangle meet at 45 degrees.
    func testASmoothByAngleModifierPartsFacesByTheirAngle() throws {
        for layout in [BlendFixture.Layout.layers, .attributes] {
            func triangle(_ degrees: Float, ignoresMarks: Bool) throws -> SIMD3<Float> {
                try shape(BlendFixture.make(layout, modifiers: [.smoothByAngle(degrees * .pi / 180, ignoresMarks: ignoresMarks)])).triangle.normals[0]
            }
            XCTAssertEqual(simd_distance(try triangle(50, ignoresMarks: true), joined), 0, accuracy: 1e-5, "\(layout)")
            XCTAssertEqual(simd_distance(try triangle(40, ignoresMarks: true), ownOfTriangle), 0, accuracy: 1e-5, "\(layout)")
            // The square is set flat in the file: a mark the modifier keeps unless told not to.
            XCTAssertEqual(simd_distance(try triangle(50, ignoresMarks: false), ownOfTriangle), 0, accuracy: 1e-5, "\(layout)")
        }
    }

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

    /// A mesh says how many edges it has, and room is kept for each of them. A count the
    /// file itself has no room for is not believed: the mesh loads at once, its faces
    /// joined as they are, where it took minutes and gigabytes over a damaged number.
    func testACountOfEdgesTheFileHasNoRoomForIsNotBelieved() throws {
        for layout in [BlendFixture.Layout.layers, .attributes] {
            for edges in [1 << 26, Int(Int32.max)] {
                let began = Date()
                let smooth = try shape(BlendFixture.make(layout, smoothSquare: true, edges: edges))
                let took = Date().timeIntervalSince(began)
                XCTAssertLessThan(took, 2, "\(layout), \(edges) edges")
                XCTAssertEqual(simd_distance(smooth.triangle.normals[0], joined), 0, accuracy: 1e-5, "\(layout), \(edges) edges")
                // Not on to the larger count once the smaller has been slow.
                if took >= 2 { return }
            }
        }
    }

    func testADamagedFileFailsOrLoadsButNeverReadsOutsideItself() throws {
        // The plain file, and one that uses what is read from the edges: modifiers, a mark, custom normals.
        let numbers: [Int16] = [9000, 4000, 12000, -8000, 7000, 15000, -5000, 6000, 11000, 2000, 3000, -12000, 8000, 9000]
        for (layout, plain) in [BlendFixture.Layout.records, .layers, .attributes].flatMap({ [($0, true), ($0, false)] }) {
            let good = plain ? BlendFixture.make(layout) : BlendFixture.make(layout, smoothSquare: true, sharpEdge: 1, modifiers: [.mirror(flag: 1 << 3 | 1 << 4), .smoothByAngle(1, ignoresMarks: false)],
                                                                             customNormals: .packed(numbers))
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
