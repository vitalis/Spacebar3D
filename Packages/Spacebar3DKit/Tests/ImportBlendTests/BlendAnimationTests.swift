import Foundation
import ImportRouter
import Metal
import ModelCore
import RenderMetal
import simd
import XCTest

/// Playing the animation of Blender `.blend` files (the "red" tests: none of it is read yet).
///
/// Expected values are Blender 5.2.2's own: each fixture was built by a script, saved, then evaluated
/// at chosen frames (`scene.frame_set`, `evaluated_get`, `matrix_world @ vertex.co`) and converted to the
/// app's Y-up axes as (x, y, z) -> (x, z, -y). See `BlendAnimationFixtures.swift` for the script.
///
/// TIME RULE (what the developer must match): clip time 0 is the scene's `frame_start`, and
/// `seconds = (frame - frame_start) / fps` (fps / fps_base; 24 here, frame_start 1). The tests pose with
/// `gpu.pose(clip: 0, time: seconds)`. Whether the importer shifts its key times to start at 0 or sets
/// `clip.start = frame_start / fps` is its choice (`localMatrices` adds `clip.start` to the time), the
/// result at `pose(time: (f - frame_start) / fps)` must be Blender's frame f. The glTF, Assimp
/// and USD importers keep `start` 0 or the file's own first time; none uses a frame number.
///
/// MATCHING: the importer may split or reorder vertices (flat faces get their own corners), so each posed
/// vertex is matched by position, not index: every Blender vertex must have a posed vertex within 1e-3, and
/// every posed vertex a Blender vertex within 1e-3. Posed vertices are read as the far glTF tests do
/// (`FarGLTFSkinnedPartsTests.placed`): CPU skinning (`skinsOnGPU = false`), every part's `vertexBuffer`
/// times its `model`. Morph (shape-key) weights must reach that same buffer.
final class BlendAnimationTests: XCTestCase {
    private let tolerance: Float = 1e-3

    // MARK: helpers

    private func scene(_ c: BlenderAnimationCase) throws -> ModelScene {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("\(c.name).blend")
        try c.data.write(to: url)
        return try ImportRouter.load(url, format: .blend)
    }

    /// Every part's vertices as the renderer places them, in the scene's frame, at `time` seconds into clip 0
    /// (`nil` leaves the scene unposed).
    private func placed(_ scene: ModelScene, time: Float?) throws -> [SIMD3<Float>] {
        let renderer = try MetalRenderer()
        renderer.skinsOnGPU = false
        renderer.showGrid = false
        let gpu = try renderer.makeScene(scene)
        renderer.show(gpu)
        if let time { gpu.pose(clip: 0, time: time) }
        _ = try renderer.renderOffscreen(width: 32, height: 32)
        let parts = try XCTUnwrap(Mirror(reflecting: gpu).children.first { $0.label == "parts" }?.value as? [AnyObject])
        var points: [SIMD3<Float>] = []
        for part in parts {
            let fields = Array(Mirror(reflecting: part).children)
            let buffer = try XCTUnwrap(fields.first { $0.label == "vertexBuffer" }?.value as? MTLBuffer)
            let count = try XCTUnwrap(fields.first { $0.label == "vertexCount" }?.value as? Int)
            let model = try XCTUnwrap(fields.first { $0.label == "model" }?.value as? simd_float4x4)
            let floats = buffer.contents().assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                let p = SIMD4<Float>(floats[i * 6], floats[i * 6 + 1], floats[i * 6 + 2], 1)
                let w = model * p
                points.append(SIMD3(w.x, w.y, w.z))
            }
        }
        return points
    }

    /// The farthest any point of `a` is from its nearest in `b`.
    private func reach(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        a.map { p in b.map { simd_distance(p, $0) }.min() ?? .infinity }.max() ?? 0
    }

    /// Poses the imported scene at each of `frames` (all the fixture's when nil) and compares with Blender.
    private func check(_ c: BlenderAnimationCase, frames only: [Double]? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let model = try scene(c)
        _ = try XCTUnwrap(model.clips.first, "\(c.name): the importer made no animation clip (clips is empty)", file: file, line: line)
        for (frame, expected) in zip(c.frames, c.expected) where only?.contains(frame) ?? true {
            let seconds = Float(frame - BlenderAnimation.frameStart) / BlenderAnimation.fps
            let posed = try placed(model, time: seconds)
            let missing = reach(expected, posed), extra = reach(posed, expected)
            print("P3D-BLENDANIM \(c.name) frame \(frame) time \(seconds)s: \(posed.count) posed vs \(expected.count) Blender; Blender point unmatched by \(missing), posed point unmatched by \(extra)")
            XCTAssertLessThan(missing, tolerance, "\(c.name) frame \(frame): a Blender vertex has no posed vertex within \(tolerance) (nearest \(missing) away)", file: file, line: line)
            XCTAssertLessThan(extra, tolerance, "\(c.name) frame \(frame): a posed vertex has no Blender vertex within \(tolerance) (nearest \(extra) away)", file: file, line: line)
        }
    }

    // MARK: armature deformation

    /// A 1 x 1 x 4 bar of two bones bends where the upper bone's Euler XYZ rotation is keyed (Bezier, keys at
    /// frames 1, 15, 30, turns about X and Z at once), its vertices following the bones by explicit vertex-group
    /// weights, half and half at the joint. The user sees the top of the bar swing to the side and back; Blender
    /// puts the top corner at y 3.63 at frame 10 and at (0.42, 3.73, -1.15) at frame 30.
    /// Expected: Blender's evaluated positions of all 36 vertices at frames 1, 10, 20 and 30.
    func testABarBendsAtItsUpperBoneAsBlenderDoesAtFramesOneTenTwentyAndThirty() throws {
        try check(BlenderAnimation.bar)
    }

    /// A bone turned by a quaternion and moved by location keys (both keyed in the bone's own axes, Bezier,
    /// frames 1 and 10) drags a mesh that also has a keyed shape key ("Fat", the top
    /// ring widening and leaning out, 0 to 1 over frames 1 to 10), under an armature that is itself offset 1 on
    /// X. The bottom ring is in no vertex group and stays; the middle ring follows at half weight. The user sees
    /// the box tilt over and fatten at once. Expected: Blender's evaluated positions at frames 1, 4, 7, 10 and 14
    /// (14 is past the last key, so it holds frame 10's pose).
    func testABoneWithQuaternionAndLocationKeysAndAShapeKeyOnTheSameMeshMovesAsBlenderDoes() throws {
        try check(BlenderAnimation.wobbler)
    }

    // MARK: object animation

    /// A cube whose object location is keyed with Bezier keys (frames 1, 11, 21, the middle key's handles set by
    /// hand), rotation_quaternion with linear keys (identity at frame 1 to a 120 degree turn about (1, 1, 1) at
    /// frame 21, blended per component and then normalised as Blender does, not slerped) and scale with constant
    /// keys. The user sees the cube slide along a curve, tumble and jump in size. Expected: Blender's eight
    /// corners at frames 1, 3, 6, 10, 11, 14, 16, 20, 21 and 25.
    func testACubeSlidesTumblesAndStepsInSizeAsBlenderDoesBetweenItsKeys() throws {
        try check(BlenderAnimation.cube)
    }

    /// The constant scale keys: 1 x 1 x 1 at frame 1, 2 x 1 x 1 at frame 11, 1 x 1 x 3 at frame 21. A constant key
    /// holds its value until the next key, and takes over exactly on the next key's frame: the cube keeps its first
    /// size at frame 10 and has the second at frame 11, still has it at frame 20 and has the third at 21. The
    /// user sees a jump, not a ramp. Expected: Blender at frames 10, 11, 20 and 21.
    func testAConstantScaleKeyHoldsUntilTheNextKeysOwnFrame() throws {
        try check(BlenderAnimation.cube, frames: [10, 11, 20, 21])
    }

    // MARK: shape keys

    /// A 3 x 3 plane with a Basis and one relative shape key "Lift" that raises six vertices by 0.5 to 2, its value
    /// keyed 0 at frame 1, 1 at frame 11 and 0.3 at frame 21 (Bezier). The user sees the plane's far edge rise and
    /// settle part way down. Blender puts the highest vertex at y 0.216 at frame 4, 1.0 at frame 11 and 0.3 from
    /// frame 21 on. Expected: Blender's evaluated vertices at frames 1, 4, 8, 11, 15, 21 and 25.
    func testAShapeKeyValueKeyedZeroOneThenPointThreeLiftsAPlaneAsBlenderDoes() throws {
        try check(BlenderAnimation.shapeKeys)
    }

    // MARK: guards

    /// A `.blend` with no animation imports as it does today: no clip and no skeleton, and its eight corners where
    /// Blender has them. The user sees a still cube. Expected: Blender at frame 1 (the cube made without keys).
    func testAFileWithNoAnimationImportsAsAStillModel() throws {
        let c = BlenderAnimation.staticCube
        let model = try scene(c)
        XCTAssertTrue(model.clips.isEmpty, "clips of a still file")
        XCTAssertTrue(model.skeletons.isEmpty, "skeletons of a still file")
        let posed = try placed(model, time: nil)
        XCTAssertEqual(reach(c.expected[0], posed), 0, accuracy: tolerance, "a Blender corner is missing")
        XCTAssertEqual(reach(posed, c.expected[0]), 0, accuracy: tolerance, "a corner is not Blender's")
        XCTAssertEqual(posed.count, Self.stillCubeVertexCount, "vertex count today")
    }

    /// An animated file posed at its first frame shows what Blender shows at frame_start, so a clip that is
    /// shifted by one frame (time 0 taken as frame 0, not frame 1) fails. The cube at frame 1 is its rest cube.
    /// Expected: Blender at frame 1, from `pose(time: 0)`.
    func testClipTimeZeroIsTheScenesStartFrame() throws {
        try check(BlenderAnimation.cube, frames: [1])
    }

    /// Recorded from the importer before the feature: the still cube imports as 8 vertices (shared corners).
    private static let stillCubeVertexCount = 8
}
