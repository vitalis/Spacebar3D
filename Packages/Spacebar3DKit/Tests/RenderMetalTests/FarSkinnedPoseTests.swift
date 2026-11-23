import Metal
import ModelCore
import RenderMetal
import simd
import XCTest

/// A skinned model far from the origin, posed on the CPU path (`skinsOnGPU = false`).
final class FarSkinnedPoseTests: XCTestCase {
    /// A flat strip up the y axis (0 to 2, 0.5 wide), lower half on joint a, upper on joint b,
    /// the whole rig `far` units out in every axis; a clip turns b a quarter turn about z.
    /// Every offset is a multiple of 0.25 and `far` a multiple of 2^20 below 2^22 (Float step at most 0.25), so each input is exact as a Float.
    private func scene(far: Float) -> ModelScene {
        let t = SIMD3<Float>(repeating: far)
        var part = ModelScene.MeshPart()
        let offsets: [SIMD3<Float>] = [SIMD3(-0.25, 0, 0), SIMD3(0.25, 0, 0), SIMD3(-0.25, 1, 0), SIMD3(0.25, 1, 0), SIMD3(-0.25, 2, 0), SIMD3(0.25, 2, 0)]
        part.positions = offsets.map { $0 + t }
        // The fixture must be exact: a far input that is not near + far would test the file, not the code.
        for (near, placed) in zip(offsets, part.positions) {
            for k in 0..<3 { precondition(Double(placed[k]) == Double(near[k]) + Double(far), "fixture is not exact at \(far): \(placed) for \(near)") }
        }
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 6)
        part.triangleIndices = [0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4]
        var skin = ModelScene.Skin(skeleton: 0)
        skin.joints = [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0)]
        skin.weights = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 6)
        part.skin = skin
        func move(_ v: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(v, 1))) }
        let root = move(t), up = move(SIMD3(0, 1, 0))
        var scene = ModelScene()
        scene.skeletons = [ModelScene.Skeleton(joints: [.init(name: "a", rest: root, inverseBind: move(-t)),
                                                         .init(name: "b", parent: 0, rest: up, inverseBind: move(-t - SIMD3(0, 1, 0)))], node: 0)]
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)), none = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        scene.clips = [ModelScene.AnimationClip(name: "bend", skeleton: 0, start: 0, end: 1, rotations: .init(times: [0, 1], values: [none, none, none, quarter]))]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(name: "skeleton"), ModelScene.Node(name: "mesh", mesh: 0)]
        return scene
    }

    /// Where the posed vertices are, in the scene's own frame, worked out in Double from what
    /// the renderer holds (the part's placement and its posed vertices).
    private func posed(_ scene: ModelScene, time: Float) throws -> [SIMD3<Double>] {
        let renderer = try MetalRenderer()
        renderer.skinsOnGPU = false
        renderer.showGrid = false
        let gpu = try renderer.makeScene(scene)
        renderer.show(gpu)
        gpu.pose(clip: 0, time: time)
        _ = try renderer.renderOffscreen(width: 32, height: 32)
        let parts = try XCTUnwrap(Mirror(reflecting: gpu).children.first { $0.label == "parts" }?.value as? [AnyObject])
        let part = try XCTUnwrap(parts.first)
        let fields = Mirror(reflecting: part).children
        let buffer = try XCTUnwrap(fields.first { $0.label == "vertexBuffer" }?.value as? MTLBuffer)
        let model = try XCTUnwrap(fields.first { $0.label == "model" }?.value as? simd_float4x4, "Part has no model: simd_float4x4")
        let floats = buffer.contents().assumingMemoryBound(to: Float.self)
        return (0..<6).map { i in
            let p = SIMD3<Double>(Double(floats[i * 6]), Double(floats[i * 6 + 1]), Double(floats[i * 6 + 2]))
            func col(_ c: SIMD4<Float>) -> SIMD3<Double> { SIMD3(Double(c.x), Double(c.y), Double(c.z)) }
            return col(model.columns.0) * p.x + col(model.columns.1) * p.y + col(model.columns.2) * p.z + col(model.columns.3)
        }
    }

    /// The far model, as the app reads it (brought near the origin), must come out the shape
    /// the same model has at the origin. Posed a quarter turn about a joint a million units
    /// out, the strip's corners landed on the Float steps of the joint's matrix (an eighth of
    /// a unit): the bar looked bent wrongly and crept about from pose to pose.
    func testASkinnedModelAMillionUnitsOutPosesLikeOneAtTheOrigin() throws {
        let far = Float(1_048_576)
        for time in [Float(0), 0.25, 0.5, 1] {
            let near = try posed(scene(far: 0), time: time)
            let moved = try posed(scene(far: far).movedNearTheOrigin(), time: time)
            var worst = 0.0
            for i in 1..<6 { worst = max(worst, simd_distance(moved[i] - moved[0], near[i] - near[0])) }
            print("P3D-FARSKIN time \(time): worst shape error \(worst)")
            XCTAssertLessThan(worst, 1e-3, "time \(time)")
        }
    }

    /// The same, three million units out, where a Float steps by a quarter unit.
    func testASkinnedModelThreeMillionUnitsOutPosesLikeOneAtTheOrigin() throws {
        let far = Float(3_145_728)
        let near = try posed(scene(far: 0), time: 1)
        let moved = try posed(scene(far: far).movedNearTheOrigin(), time: 1)
        var worst = 0.0
        for i in 1..<6 { worst = max(worst, simd_distance(moved[i] - moved[0], near[i] - near[0])) }
        print("P3D-FARSKIN 3M: worst shape error \(worst)")
        XCTAssertLessThan(worst, 1e-3)
    }
}
