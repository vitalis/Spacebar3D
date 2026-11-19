import ModelCore
import simd
import XCTest

final class SpringsTests: XCTestCase {
    /// A bone one long sticking out sideways from a joint at the origin.
    private func arm(stiffness: Float = 0, gravity: Float = 1, drag: Float = 0.4, colliders: [ModelScene.SpringSystem.Collider] = []) -> (SpringSimulator, ModelScene.Skeleton) {
        let skeleton = ModelScene.Skeleton(joints: [.init(name: "root", parent: nil), .init(name: "arm", parent: 0)], node: nil)
        let joint = ModelScene.SpringSystem.Joint(joint: 1, tail: SIMD3(1, 0, 0), stiffness: stiffness, gravityPower: gravity, drag: drag,
                                                  colliders: Array(colliders.indices))
        return (SpringSimulator(ModelScene.SpringSystem(skeleton: 0, colliders: colliders, joints: [joint]), skeleton: skeleton), skeleton)
    }

    /// Where the bone's tail is once `locals` have been through the simulator.
    private func tail(_ locals: [simd_float4x4]) -> SIMD3<Float> {
        let p = locals[0] * locals[1] * SIMD4<Float>(1, 0, 0, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    private func run(_ simulator: inout SpringSimulator, _ skeleton: ModelScene.Skeleton, steps: Int) -> (tail: SIMD3<Float>, last: Float) {
        var at = SIMD3<Float>(1, 0, 0), last: Float = 0
        for _ in 0..<steps {
            var locals = skeleton.localMatrices()
            last = simulator.step(1.0 / 60, locals: &locals)
            at = tail(locals)
            XCTAssertEqual(simd_length(at), 1, accuracy: 1e-3, "the bone keeps its length")
        }
        return (at, last)
    }

    func testABoneFallsToHangStraightDownAndComesToRest() {
        var (simulator, skeleton) = arm()
        XCTAssertFalse(simulator.isEmpty)
        let early = run(&simulator, skeleton, steps: 5)
        XCTAssertLessThan(early.tail.y, 0)
        XCTAssertGreaterThan(early.last, 0)
        let late = run(&simulator, skeleton, steps: 2000)
        XCTAssertEqual(late.tail.x, 0, accuracy: 0.01)
        XCTAssertEqual(late.tail.y, -1, accuracy: 0.01)
        XCTAssertLessThan(late.last, 1e-4)
    }

    func testStiffnessHoldsABoneWhereTheSkeletonHasIt() {
        var (simulator, skeleton) = arm(stiffness: 4, gravity: 0)
        let held = run(&simulator, skeleton, steps: 200)
        XCTAssertEqual(held.tail.x, 1, accuracy: 1e-4)
        XCTAssertEqual(held.last, 0, accuracy: 1e-6)
        // Against gravity it gives way only in part.
        var (pulled, _) = arm(stiffness: 4, gravity: 1)
        let sagging = run(&pulled, skeleton, steps: 2000)
        XCTAssertGreaterThan(sagging.tail.x, 0.5)
        XCTAssertLessThan(sagging.tail.y, -0.05)
    }

    func testABoneStaysOutOfABallAndACapsule() {
        // A ball right below the joint: the bone cannot hang straight down.
        var (simulator, skeleton) = arm(colliders: [.init(joint: 0, offset: SIMD3(0, -1, 0), radius: 0.5)])
        let rested = run(&simulator, skeleton, steps: 2000)
        XCTAssertGreaterThanOrEqual(simd_length(rested.tail - SIMD3(0, -1, 0)), 0.5 - 0.02)
        XCTAssertGreaterThan(rested.tail.x, 0.3)
        // A capsule lying under it from side to side holds it higher still.
        var (other, _) = arm(colliders: [.init(joint: 0, offset: SIMD3(-2, -1, 0), tail: SIMD3(2, -1, 0), radius: 0.5)])
        let held = run(&other, skeleton, steps: 2000)
        // Pushed out, then put back at the bone's length: gravity leaves it a hair inside.
        XCTAssertGreaterThanOrEqual(held.tail.y, -0.5 - 0.02)
    }

    func testColliderPlacementDoesNotDependOnSiblingOrder() {
        for translated in [false, true] {
            for capsule in [false, true] {
                var results: [SIMD3<Float>] = []
                for colliderFirst in [false, true] {
                    var transform = matrix_identity_float4x4
                    transform.columns.3 = SIMD4(translated ? 10 : 0, 0, 0, 1)
                    let root = ModelScene.Skeleton.Joint(name: "root")
                    let spring = ModelScene.Skeleton.Joint(name: "spring", parent: 0)
                    let collider = ModelScene.Skeleton.Joint(name: "collider", parent: 0, rest: transform)
                    let skeleton = ModelScene.Skeleton(joints: [root] + (colliderFirst ? [collider, spring] : [spring, collider]))
                    let springIndex = colliderFirst ? 2 : 1
                    let system = ModelScene.SpringSystem(skeleton: 0, colliders: [
                        .init(joint: colliderFirst ? 1 : 2, offset: SIMD3(0.8, 1, 0), tail: capsule ? SIMD3(0.8, 2, 0) : nil, radius: 1),
                    ], joints: [.init(joint: springIndex, tail: SIMD3(0, 1, 0), stiffness: 0, drag: 1, colliders: [0])])
                    var simulator = SpringSimulator(system, skeleton: skeleton)
                    var locals = skeleton.localMatrices()
                    _ = simulator.step(1.0 / 60, locals: &locals)
                    let tip = locals[springIndex] * SIMD4<Float>(0, 1, 0, 1)
                    results.append(SIMD3(tip.x, tip.y, tip.z))
                }
                XCTAssertLessThan(simd_distance(results[0], results[1]), 1e-6)
                if translated { XCTAssertLessThan(simd_distance(results[0], SIMD3(0, 1, 0)), 1e-6) }
                else { XCTAssertLessThan(results[0].x, -0.1, "the nearby collider must push the tail") }
            }
        }
    }

    func testAColliderOnTheSpringJointUsesItsPlacement() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(10, 0, 0, 1)
        let skeleton = ModelScene.Skeleton(joints: [.init(rest: transform)])
        let system = ModelScene.SpringSystem(skeleton: 0, colliders: [.init(joint: 0, offset: SIMD3(0.8, 1, 0), radius: 1)],
                                            joints: [.init(joint: 0, tail: SIMD3(0, 1, 0), stiffness: 0, drag: 1, colliders: [0])])
        var simulator = SpringSimulator(system, skeleton: skeleton)
        var locals = skeleton.localMatrices()
        _ = simulator.step(1.0 / 60, locals: &locals)
        let tip = locals[0] * SIMD4<Float>(0, 1, 0, 1)
        XCTAssertEqual(tip.x, 10 - 0.19611612, accuracy: 1e-5)
        XCTAssertEqual(tip.y, 0.98058057, accuracy: 1e-5)
    }

    func testForwardColliderFollowsAnAncestorMovedByASpring() {
        let driver = ModelScene.SpringSystem.Joint(joint: 0, tail: SIMD3(0, 1, 0), stiffness: 0,
                                                  gravityPower: 1, gravityDirection: SIMD3(1, 0, 0), drag: 1)
        let driverSkeleton = ModelScene.Skeleton(joints: [.init()])
        var driverSimulator = SpringSimulator(.init(skeleton: 0, joints: [driver]), skeleton: driverSkeleton)
        var driverLocals = driverSkeleton.localMatrices()
        _ = driverSimulator.step(1, locals: &driverLocals)
        var colliderLocal = matrix_identity_float4x4
        colliderLocal.columns.3 = SIMD4(-0.5, 1, 0, 1)

        // A separately posed collider is the reference for a collider carried by the driver.
        let reference = ModelScene.Skeleton(joints: [.init(), .init(rest: driverLocals[0] * colliderLocal)])
        let target = ModelScene.SpringSystem.Joint(joint: 0, tail: SIMD3(0, 1, 0), stiffness: 0, drag: 1, colliders: [0])
        var referenceSimulator = SpringSimulator(.init(skeleton: 0, colliders: [.init(joint: 1, radius: 0.6)], joints: [target]), skeleton: reference)
        var expected = reference.localMatrices()
        _ = referenceSimulator.step(1, locals: &expected)

        let coupled = ModelScene.Skeleton(joints: [.init(), .init(), .init(parent: 0, rest: colliderLocal)])
        var carriedTarget = target
        carriedTarget.joint = 1
        var simulator = SpringSimulator(.init(skeleton: 0, colliders: [.init(joint: 2, radius: 0.6)], joints: [driver, carriedTarget]), skeleton: coupled)
        var actual = coupled.localMatrices()
        _ = simulator.step(1, locals: &actual)
        let tip = SIMD4<Float>(0, 1, 0, 1)
        XCTAssertLessThan(simd_length(actual[1] * tip - expected[0] * tip), 1e-6)
        XCTAssertGreaterThan(simd_length(expected[0] * tip - tip), 0.05)
    }

    func testNoTimeLeavesTheBoneWhereItWasAndBrokenValuesAreLeftOut() {
        var (simulator, skeleton) = arm()
        _ = run(&simulator, skeleton, steps: 30)
        var before = skeleton.localMatrices(), after = skeleton.localMatrices()
        XCTAssertEqual(simulator.step(0, locals: &before), 0, accuracy: 1e-6)
        XCTAssertEqual(simulator.step(0, locals: &after), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_length(tail(before) - tail(after)), 0, accuracy: 1e-6)
        XCTAssertLessThan(tail(before).y, 0, "it is shown where it had fallen to")

        let broken = ModelScene.SpringSystem(skeleton: 0, joints: [
            .init(joint: 7, tail: SIMD3(1, 0, 0)), .init(joint: 1, tail: .zero), .init(joint: 1, tail: SIMD3(1, 0, 0), stiffness: .nan)])
        XCTAssertTrue(SpringSimulator(broken, skeleton: skeleton).isEmpty)
    }
}
