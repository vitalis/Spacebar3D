import Metal
import ModelCore
import RenderMetal
import simd
import XCTest

/// Changing morph weights blended the shape on the CPU into a new buffer on every change.
/// The same buffer should be rewritten, so that a face that blinks while it talks does not
/// allocate and drop a buffer for each frame.
///
/// Reads, through `Mirror`, `GPUScene.parts[i].skin?.restBuffer` (already exists).
///
/// Care: a frame still queued on the GPU may be reading the buffer (see the comment in
/// `GPUScene.show`). The expectation here is one buffer for the whole sequence; if a short
/// ring of buffers is needed for frames in flight, change `buffersAllowed` to its size.
final class MorphBufferReuseTests: XCTestCase {
    private let buffersAllowed = 1

    private func scene() -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-0.2, 0, 0), SIMD3(0.2, 0, 0), SIMD3(-0.2, 1, 0), SIMD3(0.2, 1, 0), SIMD3(-0.2, 2, 0), SIMD3(0.2, 2, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 6)
        part.triangleIndices = [0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4]
        part.morphTargets = [.init(positions: [SIMD3<Float>](repeating: SIMD3(0.8, 0, 0), count: 6)),
                             .init(positions: [SIMD3<Float>](repeating: SIMD3(0, 0, -0.5), count: 6))]
        var skin = ModelScene.Skin(skeleton: 0)
        skin.joints = [SIMD4<UInt16>](repeating: SIMD4(0, 0, 0, 0), count: 6)
        skin.weights = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 6)
        part.skin = skin
        var scene = ModelScene()
        scene.skeletons = [ModelScene.Skeleton(joints: [.init(name: "a")], node: 0)]
        var clip = ModelScene.AnimationClip(name: "talk", skeleton: 0, start: 0, end: 1)
        clip.morphs = [.init(mesh: 0, targetCount: 2, times: [0, 1], values: [0, 0, 1, 1])]
        scene.clips = [clip]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(name: "skeleton"), ModelScene.Node(name: "mesh", mesh: 0)]
        return scene
    }

    private func restBuffer(_ gpu: GPUScene) throws -> MTLBuffer {
        let parts = try XCTUnwrap(Mirror(reflecting: gpu).children.first { $0.label == "parts" }?.value as? [AnyObject])
        let skin = try XCTUnwrap(Mirror(reflecting: parts[0]).children.first { $0.label == "skin" }?.value)
        // An optional holds its value as its only child.
        let held = try XCTUnwrap(Mirror(reflecting: skin).children.first?.value as AnyObject?)
        return try XCTUnwrap(Mirror(reflecting: held).children.first { $0.label == "restBuffer" }?.value as? MTLBuffer)
    }

    func testChangingMorphWeightsKeepsWritingTheSameBuffer() throws {
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(scene())
        renderer.show(gpu)
        var seen: [MTLBuffer] = []
        for time: Float in [0, 0.1, 0.35, 0.6, 0.9, 1, 0.5, 0] {
            gpu.pose(clip: 0, time: time)
            _ = try renderer.renderOffscreen(width: 64, height: 64)
            let buffer = try restBuffer(gpu)
            if !seen.contains(where: { $0 === buffer }) { seen.append(buffer) }
        }
        XCTAssertLessThanOrEqual(seen.count, buffersAllowed, "\(seen.count) different buffers for eight poses")
    }

    /// Guard: with the buffer reused the picture still follows the weights, on the GPU and
    /// the CPU, and the same weights again give the same picture.
    func testTheShapeStillFollowsTheWeightsWhenTheBufferIsReused() throws {
        for onGPU in [true, false] {
            let renderer = try MetalRenderer()
            renderer.skinsOnGPU = onGPU
            renderer.showGrid = false
            renderer.showShadow = false
            renderer.look = RenderLook(view: .solid)
            let gpu = try renderer.makeScene(scene())
            renderer.show(gpu)
            var pictures: [Float: [UInt8]] = [:]
            for time: Float in [0, 1, 0.5, 1, 0, 0.5, 0.2, 0] {
                gpu.pose(clip: 0, time: time)
                let bytes = try renderer.renderOffscreen(width: 120, height: 120).bytes
                if let before = pictures[time] { XCTAssertEqual(bytes, before, "weights at \(time) again, GPU \(onGPU)") }
                pictures[time] = bytes
            }
            XCTAssertNotEqual(pictures[0], pictures[1], "GPU \(onGPU)")
            XCTAssertNotEqual(pictures[0], pictures[0.5], "GPU \(onGPU)")
            XCTAssertNotEqual(pictures[0.5], pictures[1], "GPU \(onGPU)")
        }
    }

    /// Guard: several poses queued before any frame is drawn (the app may pose faster than
    /// it draws) show the last one, not a mix.
    func testSeveralWeightChangesBeforeOneFrameShowTheLastOne() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.showShadow = false
        renderer.look = RenderLook(view: .solid)
        let gpu = try renderer.makeScene(scene())
        renderer.show(gpu)
        gpu.pose(clip: 0, time: 1)
        let direct = try renderer.renderOffscreen(width: 120, height: 120).bytes
        gpu.pose(clip: 0, time: 0)
        _ = try renderer.renderOffscreen(width: 120, height: 120)
        for time: Float in [0.2, 0.7, 0.4, 1] { gpu.pose(clip: 0, time: time) }
        XCTAssertEqual(try renderer.renderOffscreen(width: 120, height: 120).bytes, direct)
    }
}
