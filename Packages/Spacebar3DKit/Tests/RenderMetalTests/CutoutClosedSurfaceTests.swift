import ModelCore
import RenderMetal
import simd
import XCTest

/// A closed, outward cube whose material is a cut-out (holes by texture or vertex alpha) must
/// keep its back faces: through a hole one sees the inside of the far wall. Judged closed
/// (split vertices with UVs now are), such a cube was culled whenever the camera was outside
/// its box, and the hole showed the background.
final class CutoutClosedSurfaceTests: XCTestCase {
    private let corners: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
    private let faces: [(quad: [Int], normal: SIMD3<Float>)] = [
        ([0, 3, 2, 1], SIMD3(0, 0, -1)), ([4, 5, 6, 7], SIMD3(0, 0, 1)), ([0, 1, 5, 4], SIMD3(0, -1, 0)),
        ([2, 3, 7, 6], SIMD3(0, 1, 0)), ([1, 2, 6, 5], SIMD3(1, 0, 0)), ([0, 4, 7, 3], SIMD3(-1, 0, 0))]

    /// A cube of 24 vertices. The faces in `holes` map to the texture's transparent pixel (u 0.75)
    /// or, with `alphaHoles`, get vertex alpha 0; the others map to its opaque red pixel (u 0.25).
    private func cube(holes: Set<Int>, alphaHoles: Bool = false, cutout: Bool, textured: Bool = true) -> ModelScene {
        var part = ModelScene.MeshPart()
        for (f, face) in faces.enumerated() {
            let base = UInt32(part.positions.count)
            for c in face.quad {
                part.positions.append(corners[c]); part.normals.append(face.normal)
                part.uv0.append(SIMD2(!alphaHoles && holes.contains(f) ? 0.75 : 0.25, 0.5))
                part.colors.append(alphaHoles ? SIMD4(1, 0, 0, holes.contains(f) ? 0 : 1) : SIMD4(1, 1, 1, 1))
            }
            part.triangleIndices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        if !alphaHoles { part.colors = [] }
        part.material = 0
        var material = ModelScene.Material()
        material.doubleSided = true
                if cutout { material.alphaCutoff = 0.5 }
        var scene = ModelScene()
        if textured {
            scene.textures = [.pixels(width: 2, height: 1, rgba: [255, 0, 0, 255, 255, 0, 0, 0])]
            material.baseColorTexture = 0
            material.sampling.sharp = true; material.sampling.wrapS = .clamp
        }
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    /// Looks at the cube from outside along z; returns the face index (0 or 1) that faces the camera.
    private func setUp(_ scene: ModelScene) throws -> (MetalRenderer, GPUScene, towardCamera: Int) {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        let gpu = try renderer.makeScene(scene)
        renderer.show(gpu)
        renderer.look = RenderLook(view: .textured, style: .unlit)
        renderer.camera.yaw = 0; renderer.camera.pitch = 0
        return (renderer, gpu, renderer.camera.position.z > 0 ? 1 : 0)
    }

    private func pair(_ renderer: MetalRenderer) throws -> (culled: OffscreenImage, all: OffscreenImage) {
        renderer.cullsHiddenFaces = true
        let culled = try renderer.renderOffscreen(width: 96, height: 96)
        renderer.cullsHiddenFaces = false
        return (culled, try renderer.renderOffscreen(width: 96, height: 96))
    }

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }

    /// Through a hole in the near wall of a cut-out cube you must see its far wall's inside.
    /// With the back faces left out you saw the background instead.
    func testAHoleInACutOutCubeShowsTheFarWallInside() throws {
        let probe = try setUp(cube(holes: [], cutout: true))
        let (renderer, _, _) = try setUp(cube(holes: [probe.2], cutout: true))
        let (culled, all) = try pair(renderer)
        XCTAssertTrue(isRed(all.pixel(48, 48)), "reference: the far wall shows through the hole, \(all.pixel(48, 48))")
        XCTAssertTrue(isRed(culled.pixel(48, 48)), "culled: \(culled.pixel(48, 48))")
        XCTAssertEqual(culled.bytes, all.bytes)
    }

    /// The same where the holes are cut by vertex alpha, with no texture.
    func testAHoleCutByVertexAlphaShowsTheFarWallInside() throws {
        let probe = try setUp(cube(holes: [], alphaHoles: true, cutout: true, textured: false))
        let (renderer, _, _) = try setUp(cube(holes: [probe.2], alphaHoles: true, cutout: true, textured: false))
        let (culled, all) = try pair(renderer)
        XCTAssertTrue(isRed(all.pixel(48, 48)), "reference: \(all.pixel(48, 48))")
        XCTAssertTrue(isRed(culled.pixel(48, 48)), "culled: \(culled.pixel(48, 48))")
        XCTAssertEqual(culled.bytes, all.bytes)
    }

    /// Guard: a closed cube that is not a cut-out is still culled, with the same picture.
    func testAClosedCubeThatIsNotACutOutIsStillCulled() throws {
        for textured in [true, false] {
            let (renderer, gpu, _) = try setUp(cube(holes: [], cutout: false, textured: textured))
            XCTAssertEqual(gpu.closedPartCount, 1, "textured \(textured)")
            let (culled, all) = try pair(renderer)
            XCTAssertEqual(culled.bytes, all.bytes, "textured \(textured)")
        }
    }
}
