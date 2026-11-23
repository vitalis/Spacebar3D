import Metal
import ModelCore
import RenderMetal
import simd
import XCTest

/// The floor shadow is made from a small picture of the model seen from above (the cover
/// map). It need only be drawn again when what casts it changes: the model's pose or
/// morph, its placement, the look, the framing. A frame that only moves the camera reuses it.
///
/// Expects on `MetalRenderer` (read through `Mirror`, internal is enough):
/// - `coverDrawCount: Int`: how many times `encodeCover` really drew the map (a frame that
///   reused it does not count).
final class CoverMapReuseTests: XCTestCase {
    /// The bending strip of SkinningTests, with one morph target that pushes it back, and a
    /// translucent second part so that the look (solid or coloured) changes what it casts.
    private func scene(offset: Float = 0) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-0.2, 0, 0), SIMD3(0.2, 0, 0), SIMD3(-0.2, 1, 0), SIMD3(0.2, 1, 0), SIMD3(-0.2, 2, 0), SIMD3(0.2, 2, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 6)
        part.triangleIndices = [0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4]
        part.morphTargets = [.init(positions: [SIMD3<Float>](repeating: SIMD3(0.6, 0, 0), count: 6))]
        var skin = ModelScene.Skin(skeleton: 0)
        skin.joints = [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0)]
        skin.weights = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 6)
        part.skin = skin
        let up = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 1)))
        var scene = ModelScene()
        scene.skeletons = [ModelScene.Skeleton(joints: [.init(name: "a"), .init(name: "b", parent: 0, rest: up, inverseBind: simd_inverse(up))], node: 0)]
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)), none = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        var clip = ModelScene.AnimationClip(name: "bend", skeleton: 0, start: 0, end: 1, rotations: .init(times: [0, 1], values: [none, none, none, quarter]))
        clip.morphs = [.init(mesh: 0, targetCount: 1, times: [0, 1], values: [0, 1])]
        scene.clips = [clip]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(name: "skeleton", transform: simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(offset, 0, 0, 1)))),
                       ModelScene.Node(name: "mesh", mesh: 0)]
        return scene
    }

    private func draws(_ renderer: MetalRenderer, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let field = Mirror(reflecting: renderer).children.first { $0.label == "coverDrawCount" }
        return try XCTUnwrap(field?.value as? Int, "MetalRenderer has no coverDrawCount: Int", file: file, line: line)
    }

    private func make(clipTime: Float?, look: RenderLook = RenderLook(view: .solid)) throws -> (MetalRenderer, GPUScene) {
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(scene())
        renderer.show(gpu)
        renderer.look = look
        if let clipTime { gpu.pose(clip: 0, time: clipTime) }
        return (renderer, gpu)
    }

    /// The picture a renderer with nothing remembered makes of the same pose, look and camera.
    private func fresh(clipTime: Float, look: RenderLook, camera: OrbitCamera) throws -> [UInt8] {
        let (renderer, _) = try make(clipTime: clipTime, look: look)
        renderer.camera = camera
        return try renderer.renderOffscreen(width: 160, height: 120).bytes
    }

    /// Orbiting a model drew its shadow's map again for every frame, though the model had
    /// not changed. Frames that only turn or zoom the camera must reuse it.
    func testFramesThatOnlyMoveTheCameraReuseTheShadowMap() throws {
        let (renderer, _) = try make(clipTime: 0.5)
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        let first = try draws(renderer)
        XCTAssertEqual(first, 1, "the first frame draws it")
        for step in 1...4 {
            renderer.camera.rotate(yaw: 0.2, pitch: 0)
            _ = try renderer.renderOffscreen(width: 160, height: 120)
            XCTAssertEqual(try draws(renderer), first, "orbit step \(step)")
        }
        renderer.camera.distance *= 0.8
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        XCTAssertEqual(try draws(renderer), first, "zoom")
        // A larger or smaller picture is the same model.
        _ = try renderer.renderOffscreen(width: 200, height: 100)
        XCTAssertEqual(try draws(renderer), first, "other size")
    }

    /// Guard: what casts the shadow changing draws it again, once for each change.
    func testAChangeOfPoseMorphOrSceneDrawsTheShadowMapAgain() throws {
        let (renderer, gpu) = try make(clipTime: 0)
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        var count = try draws(renderer)
        // The skeleton's own motion, then the morph's (the clip has both; at 1 both move).
        for time: Float in [0.5, 1, 0.25] {
            gpu.pose(clip: 0, time: time)
            _ = try renderer.renderOffscreen(width: 160, height: 120)
            XCTAssertEqual(try draws(renderer), count + 1, "pose at \(time)")
            count += 1
        }
        // A different model, framed differently.
        let other = try renderer.makeScene(scene(offset: 3))
        renderer.show(other)
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        XCTAssertGreaterThan(try draws(renderer), count, "another scene")
        count = try draws(renderer)
        // Back to the first, which has the pose it was left in.
        renderer.show(gpu)
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        XCTAssertGreaterThan(try draws(renderer), count, "the first scene again")
    }

    /// Guard: the look changes what the shadow shows (a solid view casts the whole model).
    func testAChangeOfLookDrawsTheShadowMapAgain() throws {
        let (renderer, _) = try make(clipTime: 0.5)
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        var count = try draws(renderer)
        for look in [RenderLook(view: .textured), RenderLook(view: .normal), RenderLook(view: .solid)] {
            renderer.look = look
            _ = try renderer.renderOffscreen(width: 160, height: 120)
            XCTAssertGreaterThan(try draws(renderer), count, "\(look.view)")
            count = try draws(renderer)
        }
    }

    /// Guard: reusing the map must not change a pixel. Every frame of a session that orbits,
    /// moves the model, changes the look and turns the shadow off and on again is the
    /// picture a renderer with no memory makes.
    func testReusedShadowFramesLookExactlyLikeRedrawnOnes() throws {
        let (renderer, gpu) = try make(clipTime: 0.5)
        var look = RenderLook(view: .solid)
        func check(_ label: String, time: Float) throws {
            let shown = try renderer.renderOffscreen(width: 160, height: 120).bytes
            XCTAssertEqual(shown, try fresh(clipTime: time, look: look, camera: renderer.camera), label)
        }
        try check("first", time: 0.5)
        renderer.camera.rotate(yaw: 0.4, pitch: 0)
        try check("orbited", time: 0.5)
        renderer.camera.rotate(yaw: 0.4, pitch: 0.1)
        try check("orbited again", time: 0.5)
        gpu.pose(clip: 0, time: 1)
        try check("the model moved", time: 1)
        renderer.camera.rotate(yaw: -0.3, pitch: 0)
        try check("and orbited", time: 1)
        look = RenderLook(view: .textured)
        renderer.look = look
        try check("the look changed", time: 1)
        // Shadow off, the model moves meanwhile, shadow on: the map must not be the old one.
        renderer.showShadow = false
        gpu.pose(clip: 0, time: 0)
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        renderer.showShadow = true
        try check("shadow back on after the model moved", time: 0)
    }

    /// Guard: the shadow is drawn, and a model that moves changes the picture.
    func testTheShadowStillFollowsAModelThatMoves() throws {
        let (renderer, gpu) = try make(clipTime: 0)
        let rest = try renderer.renderOffscreen(width: 160, height: 120).bytes
        renderer.camera.rotate(yaw: 0.2, pitch: 0)
        _ = try renderer.renderOffscreen(width: 160, height: 120)
        renderer.camera.rotate(yaw: -0.2, pitch: 0)
        gpu.pose(clip: 0, time: 1)
        let moved = try renderer.renderOffscreen(width: 160, height: 120).bytes
        XCTAssertNotEqual(rest, moved)
        // The shadow is part of the picture: the same pose without it differs.
        renderer.showShadow = false
        gpu.pose(clip: 0, time: 0)
        let restNoShadow = try renderer.renderOffscreen(width: 160, height: 120).bytes
        XCTAssertNotEqual(rest, restNoShadow, "the shadow is in the picture")
    }
}
