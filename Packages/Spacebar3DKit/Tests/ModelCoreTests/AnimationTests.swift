import ModelCore
import simd
import XCTest

final class AnimationTests: XCTestCase {
    /// Two joints up the y axis, the second one unit above the first.
    private var skeleton: ModelScene.Skeleton {
        let up = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 1)))
        return ModelScene.Skeleton(joints: [
            .init(name: "a"),
            .init(name: "b", parent: 0, rest: up, inverseBind: simd_inverse(up)),
        ])
    }

    private func moved(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> { let r = m * SIMD4(p, 1); return SIMD3(r.x, r.y, r.z) }

    func testTheRestPoseLeavesBoundPointsWhereTheyAre() {
        let m = skeleton.skinMatrices()
        XCTAssertEqual(m.count, 2)
        XCTAssertLessThan(simd_distance(moved(m[0], SIMD3(1, 0, 0)), SIMD3(1, 0, 0)), 1e-5)
        XCTAssertLessThan(simd_distance(moved(m[1], SIMD3(0, 2, 0)), SIMD3(0, 2, 0)), 1e-5)
    }

    func testAClipTurnsTheUpperJointAboutItsOwnOrigin() {
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)), none = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        // Only rotations are animated; the upper joint's place above the lower one comes from rest.
        let clip = ModelScene.AnimationClip(name: "bend", skeleton: 0, start: 1, end: 3,
                                            rotations: .init(times: [1, 3], values: [none, none, none, quarter]))
        XCTAssertEqual(clip.duration, 2)
        // At the end: a point one above the upper joint swings to one to its left.
        var m = skeleton.skinMatrices(clip: clip, time: 2)
        XCTAssertLessThan(simd_distance(moved(m[1], SIMD3(0, 2, 0)), SIMD3(-1, 1, 0)), 1e-5)
        XCTAssertLessThan(simd_distance(moved(m[0], SIMD3(1, 0, 0)), SIMD3(1, 0, 0)), 1e-5)
        // Halfway: 45 degrees.
        m = skeleton.skinMatrices(clip: clip, time: 1)
        let h = Float(0.5).squareRoot()
        XCTAssertLessThan(simd_distance(moved(m[1], SIMD3(0, 2, 0)), SIMD3(-h, 1 + h, 0)), 1e-5)
        // Before the start and past the end it holds the first and the last key.
        XCTAssertLessThan(simd_distance(moved(skeleton.skinMatrices(clip: clip, time: -5)[1], SIMD3(0, 2, 0)), SIMD3(0, 2, 0)), 1e-5)
        XCTAssertLessThan(simd_distance(moved(skeleton.skinMatrices(clip: clip, time: 50)[1], SIMD3(0, 2, 0)), SIMD3(-1, 1, 0)), 1e-5)
    }

    func testAParentCarriesItsChildrenAndTranslationsAndScalesApply() {
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)), none = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        var clip = ModelScene.AnimationClip(skeleton: 0, start: 0, end: 1, rotations: .init(times: [0], values: [quarter, none]))
        // The lower joint turns: the point above the upper one goes with it.
        XCTAssertLessThan(simd_distance(moved(skeleton.skinMatrices(clip: clip, time: 0)[1], SIMD3(0, 2, 0)), SIMD3(-2, 0, 0)), 1e-5)
        clip = ModelScene.AnimationClip(skeleton: 0, start: 0, end: 1,
                                        translations: .init(times: [0], values: [SIMD3(5, 0, 0), SIMD3(0, 1, 0)]),
                                        scales: .init(times: [0], values: [SIMD3(1, 1, 1), SIMD3(2, 2, 2)]))
        XCTAssertLessThan(simd_distance(moved(skeleton.skinMatrices(clip: clip, time: 0)[1], SIMD3(0, 2, 0)), SIMD3(5, 3, 0)), 1e-5)
        // A channel whose values do not cover every joint is ignored, not read out of bounds.
        clip = ModelScene.AnimationClip(skeleton: 0, start: 0, end: 1, rotations: .init(times: [0, 1], values: [quarter]))
        XCTAssertLessThan(simd_distance(moved(skeleton.skinMatrices(clip: clip, time: 0)[1], SIMD3(0, 2, 0)), SIMD3(0, 2, 0)), 1e-5)
    }

    func testComposeAndDecomposeAgree() {
        let t = SIMD3<Float>(1, 2, 3), r = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 0.5))), s = SIMD3<Float>(2, 3, 0.5)
        let back = ModelScene.Skeleton.decompose(ModelScene.Skeleton.compose(t, r, s))
        XCTAssertLessThan(simd_distance(back.translation, t), 1e-5)
        XCTAssertLessThan(simd_distance(back.scale, s), 1e-5)
        XCTAssertLessThan(abs(abs(simd_dot(back.rotation, r)) - 1), 1e-5)
    }
}
