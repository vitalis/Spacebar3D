import ModelCore
import RenderMetal
import simd
import XCTest

final class SkinningTests: XCTestCase {
    /// A flat strip up the y axis from 0 to 2, its lower half on joint a and upper on joint b,
    /// with a clip that turns b a quarter turn about z.
    private func scene() -> ModelScene {
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
        // The skeleton's node places the part; the mesh's own node (moved far away) does not.
        scene.nodes = [ModelScene.Node(name: "skeleton"),
                       ModelScene.Node(name: "mesh", transform: simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(100, 0, 0, 1))), mesh: 0)]
        return scene
    }

    /// Share of the picture's columns, left and right of the middle, that show the strip.
    private func sides(_ image: OffscreenImage, background: [UInt8]) -> (left: Int, right: Int) {
        var left = 0, right = 0
        for y in 0..<image.height { for x in 0..<image.width {
            let i = (y * image.width + x) * 4
            if abs(Int(image.bytes[i]) - Int(background[i])) + abs(Int(image.bytes[i + 1]) - Int(background[i + 1])) + abs(Int(image.bytes[i + 2]) - Int(background[i + 2])) > 40 {
                if x < image.width / 2 - 8 { left += 1 } else if x > image.width / 2 + 8 { right += 1 }
            }
        } }
        return (left, right)
    }

    func testPosingMovesTheSkinnedPartAndRestPutsItBack() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        // Where the model is, not what it casts on the floor.
        renderer.showShadow = false
        let empty = try renderer.renderOffscreen(width: 200, height: 200).bytes
        let gpu = try renderer.makeScene(scene())
        XCTAssertTrue(gpu.isSkinned)
        XCTAssertEqual(gpu.clips.map(\.name), ["bend"])
        // Framed around the strip where the skeleton puts it, not 100 units away.
        // Conservative rotation intervals include the full arc and may leave a little
        // more room than the old sampled poses (the box now centers at x = -0.5).
        XCTAssertLessThan(abs(gpu.framing.center.x), 0.6)
        renderer.show(gpu)
        renderer.look = RenderLook(view: .solid)

        let rest = try renderer.renderOffscreen(width: 200, height: 200)
        let before = sides(rest, background: empty)
        XCTAssertGreaterThan(before.left + before.right, 0)
        // The view is fitted to the clip's reach as well: the strip stands upright on the
        // right, with room on the left for where it bends to.
        XCTAssertEqual(before.left, 0, "upright: \(before)")

        gpu.pose(clip: 0, time: 1)
        let bent = sides(try renderer.renderOffscreen(width: 200, height: 200), background: empty)
        // The upper half now points to -x, which is the left of the picture.
        XCTAssertGreaterThan(bent.left, 500, "\(bent)")
        XCTAssertLessThan(bent.right, before.right, "\(bent)")

        // The wire and the outline are built from the bound shape and follow the pose.
        renderer.look = RenderLook(view: .solid, wire: true, style: .celShaded)
        let inked = sides(try renderer.renderOffscreen(width: 200, height: 200), background: empty)
        XCTAssertGreaterThan(inked.left, 500, "\(inked)")
        renderer.look = RenderLook(view: .solid)

        // Back to rest, several times over (the buffers are used in turn).
        for _ in 0..<4 { gpu.pose() }
        XCTAssertEqual(try renderer.renderOffscreen(width: 200, height: 200).bytes, rest.bytes)
        // A clip that does not exist is the rest pose.
        gpu.pose(clip: 7, time: 0.5)
        XCTAssertEqual(try renderer.renderOffscreen(width: 200, height: 200).bytes, rest.bytes)
    }

    /// A tube along y of `rings` rings, bending over `joints` joints with blended weights.
    private func tube(rings: Int, around: Int, joints: Int) -> ModelScene {
        var part = ModelScene.MeshPart()
        var skin = ModelScene.Skin(skeleton: 0)
        let length: Float = 4
        for r in 0..<rings {
            let y = length * Float(r) / Float(rings - 1)
            let at = Float(r) / Float(rings - 1) * Float(joints - 1)
            let j = min(joints - 2, Int(at)), blend = at - Float(j)
            for a in 0..<around {
                let angle = Float(a) / Float(around) * 2 * .pi
                part.positions.append(SIMD3(cos(angle) * 0.3, y, sin(angle) * 0.3))
                part.normals.append(SIMD3(cos(angle), 0, sin(angle)))
                skin.joints.append(SIMD4(UInt16(j), UInt16(j + 1), 0, 0))
                skin.weights.append(SIMD4(1 - blend, blend, 0, 0))
            }
        }
        for r in 0..<(rings - 1) { for a in 0..<around {
            let i = UInt32(r * around + a), n = UInt32(r * around + (a + 1) % around)
            part.triangleIndices.append(contentsOf: [i, n, n + UInt32(around), i, n + UInt32(around), i + UInt32(around)])
        } }
        part.skin = skin
        var scene = ModelScene()
        let step = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, length / Float(joints - 1), 0, 1)))
        var bones: [ModelScene.Skeleton.Joint] = []
        var world = matrix_identity_float4x4
        for j in 0..<joints {
            if j > 0 { world = world * step }
            bones.append(.init(name: "j\(j)", parent: j > 0 ? j - 1 : nil, rest: j > 0 ? step : matrix_identity_float4x4, inverseBind: simd_inverse(world)))
        }
        scene.skeletons = [ModelScene.Skeleton(joints: bones, node: 0)]
        let none = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), turn = simd_quatf(angle: 0.5, axis: SIMD3(0, 0, 1))
        scene.clips = [ModelScene.AnimationClip(name: "curl", skeleton: 0, start: 0, end: 1,
                                                rotations: .init(times: [0, 1], values: [simd_quatf](repeating: none, count: joints) + [simd_quatf](repeating: turn, count: joints)))]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(name: "skeleton"), ModelScene.Node(name: "mesh", mesh: 0)]
        return scene
    }

    func testTheGPUPosesAsTheCPUDoes() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        let gpu = try renderer.makeScene(tube(rings: 60, around: 24, joints: 6))
        renderer.show(gpu)
        for look in [RenderLook(view: .solid), RenderLook(view: .solid, wire: true, style: .celShaded)] {
            renderer.look = look
            for time in [Float(0), 0.4, 1] {
                renderer.skinsOnGPU = true
                gpu.pose(clip: 0, time: time)
                let onGPU = try renderer.renderOffscreen(width: 240, height: 240)
                renderer.skinsOnGPU = false
                gpu.pose(clip: 0, time: time)
                let onCPU = try renderer.renderOffscreen(width: 240, height: 240)
                var different = 0
                for i in 0..<onGPU.bytes.count where abs(Int(onGPU.bytes[i]) - Int(onCPU.bytes[i])) > 6 { different += 1 }
                XCTAssertLessThan(different, 40, "time \(time), \(look)")
            }
        }
        // The pose shows: curled over, the tube is no longer upright in the picture.
        renderer.skinsOnGPU = true
        renderer.look = RenderLook(view: .solid)
        gpu.pose()
        let upright = try renderer.renderOffscreen(width: 240, height: 240)
        gpu.pose(clip: 0, time: 1)
        XCTAssertTrue(try renderer.renderOffscreen(width: 240, height: 240).bytes != upright.bytes)
    }

    /// Timing; skipped unless P3D_LARGE=1.
    func testPosingAMillionVertices() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["P3D_LARGE"] == "1")
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(tube(rings: 4000, around: 250, joints: 40))
        renderer.show(gpu)
        renderer.look = RenderLook(view: .solid)
        for onGPU in [false, true, false, true] {
            renderer.skinsOnGPU = onGPU
            _ = try renderer.renderOffscreen(width: 800, height: 600)
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpuBefore = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            let start = CFAbsoluteTimeGetCurrent()
            for frame in 0..<30 {
                gpu.pose(clip: 0, time: Float(frame) / 30)
                _ = try renderer.renderOffscreen(width: 800, height: 600)
            }
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6 - cpuBefore
            print(String(format: "P3D-SKIN %@: %.1f ms a frame, %.1f ms of CPU a frame", onGPU ? "GPU" : "CPU", (CFAbsoluteTimeGetCurrent() - start) / 30 * 1000, cpu / 30 * 1000))
        }
    }

    func testASkinThatDoesNotFitIsIgnored() throws {
        var broken = scene()
        broken.meshes[0].parts[0].skin?.weights.removeLast()
        let gpu = try MetalRenderer().makeScene(broken)
        XCTAssertFalse(gpu.isSkinned)
        broken = scene()
        broken.meshes[0].parts[0].skin?.skeleton = 3
        XCTAssertFalse(try MetalRenderer().makeScene(broken).isSkinned)
    }
}
