import ModelCore
@testable import RenderMetal
import simd
import XCTest

private func square(left: Float, right: Float, z: Float, material: Int) -> ModelScene.MeshPart {
    var part = ModelScene.MeshPart()
    part.positions = [SIMD3(left,-1,z),SIMD3(right,-1,z),SIMD3(right,1,z),SIMD3(left,1,z)]
    part.normals = Array(repeating:SIMD3(0,0,1),count:4)
    part.triangleIndices = [0,1,2,0,2,3];part.material=material
    return part
}
private func transparent(frontRight: Float, redZ: Float = 1) -> ModelScene {
    var r = ModelScene.Material(), b = ModelScene.Material()
    r.baseColor=SIMD4(1,0,0,1);b.baseColor=SIMD4(0,0,1,1)
    r.opacity=0.5;b.opacity=0.5;r.doubleSided=true;b.doubleSided=true
    var scene=ModelScene();scene.materials=[r,b]
    scene.meshes=[.init(parts:[square(left:-1,right:frontRight,z:redZ,material:0),square(left:-1,right:1,z:0,material:1)])]
    scene.nodes=[.init(mesh:0)]
    return scene
}

final class AnimatedBoundsAndTransparencyTests: XCTestCase {
    private func renderer() throws -> MetalRenderer {
        let r = try MetalRenderer(); r.showGrid = false; r.showShadow = false; r.backgroundAlpha = 0
        r.look = RenderLook(view:.textured,style:.unlit)
        return r
    }
    private func shot(_ scene: ModelScene, _ r: MetalRenderer, pose: Bool = false) throws -> [UInt8] {
        let gpu = try r.makeScene(scene)
        r.show(gpu); r.camera = OrbitCamera(target:.zero,distance:3,yaw:0,pitch:0,near:0.01,far:100)
        if pose { gpu.pose(clip:0,time:1) }
        let p = try r.renderOffscreen(width:96,height:96).pixel(48,48)
        return [p.r,p.g,p.b,p.a]
    }
    func testTransparentDepthOrderIgnoresLateralExtent() throws {
        let r = try renderer()
        XCTAssertEqual(try shot(transparent(frontRight:21),r),try shot(transparent(frontRight:1),r))
    }
    func testTransparentPosedDepthOrderMatchesStaticGeometry() throws {
        let r = try renderer()
        for onGPU in [false,true] { for morph in [false,true] {
            r.skinsOnGPU = onGPU
            var scene = transparent(frontRight:1)
            scene.skeletons = [.init(joints:[.init()])]
            scene.meshes[0].parts[0].skin = .init(skeleton:0,joints:Array(repeating:SIMD4(0,0,0,0),count:4),weights:Array(repeating:SIMD4(1,0,0,0),count:4))
            var clip = ModelScene.AnimationClip(skeleton:0,start:0,end:1)
            if morph {
                scene.meshes[0].parts[0].morphTargets = [.init(positions:Array(repeating:SIMD3(0,0,-2),count:4))]
                clip.morphs = [.init(mesh:0,targetCount:1,times:[0,1],values:[0,1])]
            } else { clip.linearTranslations[0] = .init(times:[0,1],values:[.zero,SIMD3(0,0,-2)]) }
            scene.clips = [clip]
            XCTAssertEqual(try shot(scene,r,pose:true),try shot(transparent(frontRight:1,redZ:-1),r))
        } }
    }
    func testFramingIncludesShortJointAndMorphPeaks() throws {
        for step in [false,true] { for morph in [false,true] {
            var scene = transparent(frontRight:1)
            scene.meshes[0].parts.removeLast(); scene.materials[0].opacity = 1
            scene.skeletons = [.init(joints:[.init()])]
            scene.meshes[0].parts[0].skin = .init(skeleton:0,joints:Array(repeating:SIMD4(0,0,0,0),count:4),weights:Array(repeating:SIMD4(1,0,0,0),count:4))
            var clip = ModelScene.AnimationClip(skeleton:0,start:0,end:1)
            let times: [Float] = [0,1.0/60,1.0/30,1]
            if morph {
                scene.meshes[0].parts[0].morphTargets = [.init(positions:Array(repeating:SIMD3(10,0,0),count:4))]
                clip.morphs = [.init(mesh:0,targetCount:1,times:times,values:[0,1,0,0],step:step)]
            } else {
                let channel = ModelScene.Channel(times:times,values:[SIMD3<Float>.zero,SIMD3(10,0,0),.zero,.zero])
                if step { clip.stepTranslations[0] = channel } else { clip.linearTranslations[0] = channel }
            }
            scene.clips = [clip]
            let r = try renderer(), gpu = try r.makeScene(scene)
            r.show(gpu)
            XCTAssertGreaterThanOrEqual(gpu.framing.center.x + gpu.framing.size.x / 2,11)
            for t: Float in [0,1.0/120,1.0/60,1.0/40,1.0/30] {
                gpu.pose(clip:0,time:t); r.camera = r.homeCamera
                let image = try r.renderOffscreen(width:96,height:96)
                XCTAssertTrue(stride(from:3,to:image.bytes.count,by:4).contains { image.bytes[$0] > 0 })
            }
        } }
    }
    func testRotationBoundsContainInteriorArcAndNestedTransforms() {
        var parent = ModelScene.Skeleton.Joint()
        parent.restComponents = (.zero, simd_quatf(angle: 0, axis: SIMD3(0,0,1)), SIMD3(1,1,1))
        var child = ModelScene.Skeleton.Joint(parent: 0)
        child.animationPrefix = ModelScene.Skeleton.compose(SIMD3(2,-1,0), simd_quatf(angle: 0.3, axis: SIMD3(1,0,0)), SIMD3(-1,2,1))
        let skeleton = ModelScene.Skeleton(joints: [parent, child])
        var clip = ModelScene.AnimationClip(skeleton: 0, end: 1)
        clip.linearRotations[0] = .init(times: [0,1], values: [simd_quatf(angle: -.pi/3, axis: SIMD3(0,0,1)), simd_quatf(angle: .pi/3, axis: SIMD3(0,0,1))])
        clip.linearRotations[1] = .init(times: [0,0.02,1], values: [simd_quatf(angle: -1, axis: simd_normalize(SIMD3(1,2,3))), simd_quatf(angle: 1.8, axis: simd_normalize(SIMD3(2,1,3))), simd_quatf(angle: 0, axis: SIMD3(1,0,0))])
        clip.linearTranslations[1] = .init(times: [0,0.013,1], values: [.zero,SIMD3(3,-2,4),.zero])
        clip.linearScales[1] = .init(times: [0,1], values: [SIMD3(1,-1,2),SIMD3(-2,3,0.5)])
        let ranges = AnimationBounds.worldTransforms(skeleton, clips: [clip])
        let rootPoint = ranges[0].apply(.init(SIMD3(1,0,0)))
        // Both endpoint x values are 0.5; the middle of the arc reaches 1.
        XCTAssertGreaterThanOrEqual(rootPoint.high.x, 1 - 1e-6)
        for time in (0...200).map({ Float($0) / 200 }) + [0.013,0.02] {
            let actual = skeleton.skinMatrices(clip: clip, time: time)
            for joint in 0..<2 { for point in [SIMD3<Float>(1,2,3),SIMD3(-2,0.3,-4)] {
                let expected = actual[joint] * SIMD4(point,1), bound = ranges[joint].apply(.init(point))
                for axis in 0..<3 {
                    XCTAssertGreaterThanOrEqual(expected[axis], bound.low[axis] - 1e-4)
                    XCTAssertLessThanOrEqual(expected[axis], bound.high[axis] + 1e-4)
                }
            } }
        }
    }

    /// A limb that swings is framed by where it goes. Taking each joint's widest turn and
    /// letting every joint above it turn its own worst way at once made room nothing ever
    /// reached: half as much again for an arm, and more the longer the chain.
    func testASwingingLimbIsFramedByWhereItGoes() throws {
        for (depth, swing) in [(4, Float.pi / 6), (6, Float.pi / 3), (10, Float.pi / 9)] {
            var joints: [ModelScene.Skeleton.Joint] = []
            var bind = matrix_identity_float4x4
            for j in 0..<depth {
                var joint = ModelScene.Skeleton.Joint(parent: j == 0 ? nil : j - 1)
                joint.restComponents = (SIMD3(0, j == 0 ? 0 : 1, 0), simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), SIMD3(1, 1, 1))
                joint.rest = ModelScene.Skeleton.compose(SIMD3(0, j == 0 ? 0 : 1, 0), simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), SIMD3(1, 1, 1))
                bind = bind * joint.rest
                joint.inverseBind = bind.inverse
                joints.append(joint)
            }
            let skeleton = ModelScene.Skeleton(joints: joints)
            var clip = ModelScene.AnimationClip(skeleton: 0, start: 0, end: 1)
            for j in 0..<depth {
                // Each joint swings about its own axis and out of step with the others.
                let axis = SIMD3<Float>(j % 2 == 0 ? 1 : 0, 0, j % 2 == 0 ? 0 : 1)
                clip.linearRotations[j] = .init(times: [0, 0.25, 0.5, 0.75, 1], values: [0, 1, 0, -1, 0].map { simd_quatf(angle: swing * Float($0) * (j % 3 == 0 ? 1 : -1), axis: axis) })
            }
            // A strip on the last joint and one on the first.
            let top = Float(depth - 1)
            var part = ModelScene.MeshPart()
            part.positions = [SIMD3(-0.1, top, 0), SIMD3(0.1, top, 0), SIMD3(0.1, top + 1, 0), SIMD3(-0.1, top + 1, 0), SIMD3(-0.1, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0.1, 1, 0), SIMD3(-0.1, 1, 0)]
            part.normals = Array(repeating: SIMD3(0, 0, 1), count: 8)
            part.triangleIndices = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
            part.material = 0
            part.skin = .init(skeleton: 0, joints: Array(repeating: SIMD4(UInt16(depth - 1), 0, 0, 0), count: 4) + Array(repeating: SIMD4(0, 0, 0, 0), count: 4), weights: Array(repeating: SIMD4(1, 0, 0, 0), count: 8))
            var scene = ModelScene()
            scene.materials = [ModelScene.Material()]
            scene.meshes = [.init(parts: [part])]
            scene.nodes = [.init(mesh: 0)]
            scene.skeletons = [skeleton]
            scene.clips = [clip]

            let framing = try renderer().makeScene(scene).framing
            var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
            for step in 0...400 {
                let matrices = skeleton.skinMatrices(clip: clip, time: Float(step) / 400)
                for (i, p) in part.positions.enumerated() {
                    let at = matrices[i < 4 ? depth - 1 : 0] * SIMD4(p, 1)
                    low = simd_min(low, SIMD3(at.x, at.y, at.z)); high = simd_max(high, SIMD3(at.x, at.y, at.z))
                }
            }
            for axis in 0..<3 {
                let name = "\(depth) joints, axis \(axis)"
                XCTAssertLessThanOrEqual(framing.center[axis] - framing.size[axis] / 2, low[axis] + 1e-3, name)
                XCTAssertGreaterThanOrEqual(framing.center[axis] + framing.size[axis] / 2, high[axis] - 1e-3, name)
                XCTAssertLessThan(framing.size[axis], (high[axis] - low[axis]) * 1.1 + 0.3, name)
            }
        }
    }
}
