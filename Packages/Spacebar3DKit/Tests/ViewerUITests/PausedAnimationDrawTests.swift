import Foundation
import MetalKit
import RenderMetal
import XCTest
@testable import ViewerUI

/// Drawing frames of a paused animation must not pose the model again.
///
/// Expects `GPUScene.poseEvaluationCount: Int` (internal is enough; read through `Mirror`):
/// how many times `pose(clip:time:elapsed:)` really worked the joints out, not counting a
/// call skipped (in the scene or by the viewer) because clip and time had not changed.
@MainActor
final class PausedAnimationDrawTests: XCTestCase {
    private let skinned = """
    #usda 1.0
    (
        upAxis = "Y"
        startTimeCode = 0
        endTimeCode = 24
        timeCodesPerSecond = 24
        defaultPrim = "root"
    )

    def SkelRoot "root"
    {
        def Skeleton "skel" (
            prepend apiSchemas = ["SkelBindingAPI"]
        )
        {
            uniform token[] joints = ["a", "a/b"]
            uniform matrix4d[] bindTransforms = [( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) ), ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 1, 0, 1) )]
            uniform matrix4d[] restTransforms = [( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) ), ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 1, 0, 1) )]
            rel skel:animationSource = </root/skel/anim>

            def SkelAnimation "anim"
            {
                uniform token[] joints = ["a", "a/b"]
                float3[] translations = [(0, 0, 0), (0, 1, 0)]
                quatf[] rotations.timeSamples = {
                    0: [(1, 0, 0, 0), (1, 0, 0, 0)],
                    24: [(1, 0, 0, 0), (0.70710678, 0, 0, 0.70710678)],
                }
                half3[] scales = [(1, 1, 1), (1, 1, 1)]
            }
        }

        def Mesh "mesh" (
            prepend apiSchemas = ["SkelBindingAPI"]
        )
        {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 2, 0)]
            int[] primvars:skel:jointIndices = [0, 0, 1] (
                elementSize = 1
                interpolation = "vertex"
            )
            float[] primvars:skel:jointWeights = [1, 1, 1] (
                elementSize = 1
                interpolation = "vertex"
            )
            rel skel:skeleton = </root/skel>
        }
    }
    """

    private func temp(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func evaluations(_ viewer: NativeViewer) throws -> Int {
        let scene = try XCTUnwrap(viewer.renderer.scene)
        let field = Mirror(reflecting: scene).children.first { $0.label == "poseEvaluationCount" }
        return try XCTUnwrap(field?.value as? Int, "GPUScene has no poseEvaluationCount: Int")
    }

    /// Orbiting a model paused on a moment of its animation re-posed and re-skinned it in
    /// every frame, which made the orbit heavy for nothing. While paused, frames that only
    /// move the camera pose nothing; moving the clip, or playing, still poses.
    func testDrawingFramesOfAPausedAnimationDoesNotPoseAgain() async throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        try viewer.load(fileAt: try temp("paused.usda", skinned))
        await viewer.loadTask?.value
        XCTAssertEqual(viewer.model.clipNames, ["anim"])
        let view = MTKView(frame: .init(x: 0, y: 0, width: 64, height: 64), device: viewer.renderer.device)

        // Seeking pauses on that moment.
        viewer.model.onSeek?(0.5)
        XCTAssertFalse(viewer.model.playing)
        viewer.draw(in: view)
        let shown = try evaluations(viewer)
        for _ in 0..<5 {
            viewer.renderer.camera.rotate(yaw: 0.1, pitch: 0)
            viewer.draw(in: view)
        }
        XCTAssertEqual(try evaluations(viewer), shown, "five frames of the same paused moment")

        // Moving the scrubber is a new pose, shown once.
        viewer.model.onSeek?(0.8)
        viewer.draw(in: view)
        viewer.draw(in: view)
        XCTAssertEqual(try evaluations(viewer), shown + 1)

        // Playing poses in every frame again.
        viewer.model.playing = true
        let before = try evaluations(viewer)
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 20_000_000)
            viewer.draw(in: view)
        }
        XCTAssertEqual(try evaluations(viewer), before + 3, "a playing clip changes at every frame")
    }
}
