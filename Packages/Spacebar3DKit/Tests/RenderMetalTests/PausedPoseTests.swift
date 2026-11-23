import Metal
import ModelCore
import RenderMetal
import simd
import XCTest

/// A paused animation (or a pose asked for again with the same clip and time) must not be
/// posed and skinned again for every frame drawn.
///
/// Names expected on `GPUScene` (read through `Mirror`, internal is enough):
/// - `poseEvaluationCount: Int`: how many times `pose(clip:time:elapsed:)` really worked the
///   joints' matrices out (not counting a call it skipped because nothing had changed).
/// - `skinPassCount: Int`: how many times `encodePose` really moved the vertices to a pose,
///   on the GPU or the CPU (not counting a frame that found the pose already applied).
final class PausedPoseTests: XCTestCase {
    private func scene(springs: Bool = false) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-0.2, 0, 0), SIMD3(0.2, 0, 0), SIMD3(-0.2, 1, 0), SIMD3(0.2, 1, 0), SIMD3(-0.2, 2, 0), SIMD3(0.2, 2, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 6)
        part.triangleIndices = [0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4]
        var skin = ModelScene.Skin(skeleton: 0)
        skin.joints = [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0)]
        skin.weights = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 6)
        part.skin = skin
        let up = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 1)))
        var scene = ModelScene()
        scene.skeletons = [ModelScene.Skeleton(joints: [.init(name: "a"), .init(name: "b", parent: 0, rest: up, inverseBind: simd_inverse(up))], node: 0)]
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)), none = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        scene.clips = [ModelScene.AnimationClip(name: "bend", skeleton: 0, start: 0, end: 1, rotations: .init(times: [0, 1], values: [none, none, none, quarter]))]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(name: "skeleton"), ModelScene.Node(name: "mesh", mesh: 0)]
        if springs {
            scene.springs = ModelScene.SpringSystem(skeleton: 0, colliders: [], joints: [.init(joint: 1, tail: SIMD3(0, 1, 0), stiffness: 0, gravityPower: 1, drag: 0.4, colliders: [])])
        }
        return scene
    }

    private func counter(_ name: String, of gpu: GPUScene, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let field = Mirror(reflecting: gpu).children.first { $0.label == name }
        return try XCTUnwrap(field?.value as? Int, "GPUScene has no \(name): Int", file: file, line: line)
    }

    private func vertexBuffers(of gpu: GPUScene) throws -> [MTLBuffer] {
        let parts = try XCTUnwrap(Mirror(reflecting: gpu).children.first { $0.label == "parts" }?.value as? [AnyObject])
        return try parts.map { part in
            try XCTUnwrap(Mirror(reflecting: part).children.first { $0.label == "vertexBuffer" }?.value as? MTLBuffer)
        }
    }

    /// Orbiting a paused model made the app work out the same joints again for every frame.
    /// Asking for the pose that is already shown must be free; a different time must not be.
    func testAskingForThePoseAlreadyShownWorksNothingOut() throws {
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(scene())
        gpu.pose(clip: 0, time: 0.5)
        let first = try counter("poseEvaluationCount", of: gpu)
        for _ in 0..<5 { gpu.pose(clip: 0, time: 0.5) }
        XCTAssertEqual(try counter("poseEvaluationCount", of: gpu), first, "five more frames of the same pose")
        gpu.pose(clip: 0, time: 0.75)
        XCTAssertEqual(try counter("poseEvaluationCount", of: gpu), first + 1, "a new moment is worked out")
        gpu.pose(clip: 0, time: 0.5)
        XCTAssertEqual(try counter("poseEvaluationCount", of: gpu), first + 2, "and so is going back")
        gpu.pose()
        XCTAssertEqual(try counter("poseEvaluationCount", of: gpu), first + 3, "the rest pose is a different pose")
        for _ in 0..<3 { gpu.pose() }
        XCTAssertEqual(try counter("poseEvaluationCount", of: gpu), first + 3, "and asking for it again is free")
    }

    /// The vertices were moved to the pose in every frame, on the GPU or the CPU, though the
    /// pose had not changed.
    func testFramesOfAPausedPoseDoNotSkinAgain() throws {
        for onGPU in [true, false] {
            let renderer = try MetalRenderer()
            renderer.skinsOnGPU = onGPU
            let gpu = try renderer.makeScene(scene())
            renderer.show(gpu)
            gpu.pose(clip: 0, time: 0.5)
            _ = try renderer.renderOffscreen(width: 64, height: 64)
            let first = try counter("skinPassCount", of: gpu)
            XCTAssertGreaterThan(first, 0, "the first frame skins (GPU \(onGPU))")
            for frame in 0..<4 {
                gpu.pose(clip: 0, time: 0.5)
                renderer.camera.rotate(yaw: 0.1, pitch: 0)
                _ = try renderer.renderOffscreen(width: 64, height: 64)
                XCTAssertEqual(try counter("skinPassCount", of: gpu), first, "frame \(frame) of the same pose (GPU \(onGPU))")
            }
            gpu.pose(clip: 0, time: 1)
            _ = try renderer.renderOffscreen(width: 64, height: 64)
            XCTAssertEqual(try counter("skinPassCount", of: gpu), first + 1, "a new pose skins once (GPU \(onGPU))")
        }
    }

    /// On the CPU every skinning publishes a new vertex buffer, so repeated frames of one
    /// pose must keep the very same buffer. Needs no new name.
    func testAPausedPoseKeepsTheSameVertexBufferOnTheCPU() throws {
        let renderer = try MetalRenderer()
        renderer.skinsOnGPU = false
        let gpu = try renderer.makeScene(scene())
        renderer.show(gpu)
        gpu.pose(clip: 0, time: 0.5)
        _ = try renderer.renderOffscreen(width: 64, height: 64)
        let before = try vertexBuffers(of: gpu)
        for _ in 0..<3 {
            gpu.pose(clip: 0, time: 0.5)
            _ = try renderer.renderOffscreen(width: 64, height: 64)
        }
        let after = try vertexBuffers(of: gpu)
        XCTAssertEqual(before.count, after.count)
        for (a, b) in zip(before, after) { XCTAssertTrue(a === b, "re-skinned into a new buffer") }
        gpu.pose(clip: 0, time: 1)
        _ = try renderer.renderOffscreen(width: 64, height: 64)
        XCTAssertFalse(try vertexBuffers(of: gpu).enumerated().allSatisfy { $1 === before[$0] }, "a new pose does make a new buffer")
    }

    /// Guard: skipping repeats must not leave the picture on an old pose. Drawn after each
    /// change of pose the picture shows the new one, and the same pose gives the same picture.
    func testAChangedPoseStillShowsAfterAPausedStretch() throws {
        for onGPU in [true, false] {
            let renderer = try MetalRenderer()
            renderer.skinsOnGPU = onGPU
            renderer.showGrid = false
            renderer.showShadow = false
            let gpu = try renderer.makeScene(scene())
            renderer.show(gpu)
            renderer.look = RenderLook(view: .solid)
            gpu.pose()
            let rest = try renderer.renderOffscreen(width: 120, height: 120).bytes
            gpu.pose(clip: 0, time: 1)
            let bent = try renderer.renderOffscreen(width: 120, height: 120).bytes
            XCTAssertNotEqual(bent, rest, "GPU \(onGPU)")
            for _ in 0..<3 {
                gpu.pose(clip: 0, time: 1)
                XCTAssertEqual(try renderer.renderOffscreen(width: 120, height: 120).bytes, bent, "paused on the bend, GPU \(onGPU)")
            }
            gpu.pose()
            XCTAssertEqual(try renderer.renderOffscreen(width: 120, height: 120).bytes, rest, "back at rest, GPU \(onGPU)")
            gpu.pose(clip: 0, time: 1)
            XCTAssertEqual(try renderer.renderOffscreen(width: 120, height: 120).bytes, bent, "bent again, GPU \(onGPU)")
        }
    }

    /// Guard: a model with swinging parts is not paused when the clip is: the same time with
    /// time passing must still step the springs every call.
    func testSpringsStillAdvanceWhileTheClipTimeStandsStill() throws {
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(scene(springs: true))
        XCTAssertTrue(gpu.hasSprings)
        gpu.pose(clip: 0, time: 0.5, elapsed: 1.0 / 60)
        let first = try counter("poseEvaluationCount", of: gpu)
        for _ in 0..<5 { gpu.pose(clip: 0, time: 0.5, elapsed: 1.0 / 60) }
        XCTAssertEqual(try counter("poseEvaluationCount", of: gpu), first + 5)
    }
}
