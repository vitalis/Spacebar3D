import ModelCore
import RenderMetal
import simd
import XCTest

final class ColourAndPointTests: XCTestCase {
    private func scene(_ part: ModelScene.MeshPart) -> ModelScene {
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    private func quad(colours: [SIMD4<Float>], normals: Bool, faceted: Bool = false) -> ModelScene.MeshPart {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        if normals { part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4) }
        part.colors = colours
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.faceted = faceted
        return part
    }

    /// Share of pixels that are clearly more red than green and blue.
    private func redShare(_ image: OffscreenImage) -> Double {
        var red = 0
        for i in stride(from: 0, to: image.bytes.count, by: 4) where Int(image.bytes[i + 2]) > Int(image.bytes[i + 1]) + 60 && Int(image.bytes[i + 2]) > Int(image.bytes[i]) + 60 { red += 1 }
        return Double(red) / Double(image.bytes.count / 4)
    }

    /// Vertex colours show in Textured and its styles, on every way a part can be uploaded,
    /// and not in Solid.
    func testVertexColoursShowInTexturedOnly() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        let red = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: 4)
        for (label, part) in [("own normals", quad(colours: red, normals: true)), ("made normals", quad(colours: red, normals: false)), ("faceted", quad(colours: red, normals: false, faceted: true))] {
            renderer.show(try renderer.makeScene(scene(part)))
            for look in [RenderLook(view: .textured), RenderLook(view: .textured, flat: true), RenderLook(view: .textured, style: .unlit), RenderLook(view: .textured, style: .anime)] {
                renderer.look = look
                XCTAssertGreaterThan(redShare(try renderer.renderOffscreen(width: 160, height: 120)), 0.1, "\(label) \(look.style) flat \(look.flat)")
            }
            renderer.look = RenderLook(view: .solid)
            XCTAssertEqual(redShare(try renderer.renderOffscreen(width: 160, height: 120)), 0, label)
        }
        // Without colours nothing is red.
        renderer.show(try renderer.makeScene(scene(quad(colours: [], normals: true))))
        renderer.look = RenderLook(view: .textured)
        XCTAssertEqual(redShare(try renderer.renderOffscreen(width: 160, height: 120)), 0)
    }

    func testAPointCloudIsDrawnAsDotsInItsColours() throws {
        var part = ModelScene.MeshPart()
        part.primitive = .points
        for x in -10...10 { for y in -10...10 { part.positions.append(SIMD3(Float(x) / 10, Float(y) / 10, 0)) } }
        part.colors = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: part.positions.count)
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        let gpu = try renderer.makeScene(scene(part))
        XCTAssertEqual(gpu.pointCount, 441)
        XCTAssertEqual(gpu.triangleCount, 0)
        renderer.show(gpu)
        let small = redShare(try renderer.renderOffscreen(width: 320, height: 240))
        XCTAssertGreaterThan(small, 0.005)
        XCTAssertLessThan(small, 0.2, "dots, not a filled surface")
        // Twice the pixels per point: dots twice as wide.
        renderer.pixelsPerPoint = 2
        XCTAssertGreaterThan(redShare(try renderer.renderOffscreen(width: 320, height: 240)), small * 2)
        // The wire and the outline have nothing to do for a point cloud and do not fail.
        renderer.look = RenderLook(view: .solid, wire: true, style: .celShaded)
        XCTAssertGreaterThan(redShare(try renderer.renderOffscreen(width: 320, height: 240)), 0.005)
        // Without colours the dots are the neutral grey.
        part.colors = []
        renderer.show(try renderer.makeScene(scene(part)))
        XCTAssertEqual(redShare(try renderer.renderOffscreen(width: 320, height: 240)), 0)
    }

    /// A large mesh without normals keeps its shared vertices; a small one gets a normal per corner.
    func testALargeMeshWithoutNormalsKeepsItsSharedVertices() throws {
        func grid(_ n: Int) -> ModelScene.MeshPart {
            var part = ModelScene.MeshPart()
            for y in 0...n { for x in 0...n { part.positions.append(SIMD3(Float(x) / Float(n) - 0.5, Float(y) / Float(n) - 0.5, 0.1 * sin(Float(x) * 0.05))) } }
            for y in 0..<n { for x in 0..<n {
                let a = UInt32(y * (n + 1) + x), b = a + 1, c = a + UInt32(n + 1), d = c + 1
                part.triangleIndices += [a, b, d, a, d, c]
            } }
            return part
        }
        let renderer = try MetalRenderer()
        let small = try renderer.makeScene(scene(grid(10)))
        XCTAssertEqual(small.vertexCount, 600)
        let n = 400      // 320,000 triangles
        let large = try renderer.makeScene(scene(grid(n)))
        XCTAssertEqual(large.vertexCount, (n + 1) * (n + 1))
        renderer.show(large)
        renderer.showGrid = false
        renderer.look = RenderLook(view: .normal)
        let image = try renderer.renderOffscreen(width: 160, height: 120)
        // Smooth normals: the wave shows as more than one colour.
        var colours = Set<UInt32>()
        for i in stride(from: 0, to: image.bytes.count, by: 4) { colours.insert(UInt32(image.bytes[i]) << 16 | UInt32(image.bytes[i + 1]) << 8 | UInt32(image.bytes[i + 2])) }
        XCTAssertGreaterThan(colours.count, 20)
    }
    func testTranslucentPointsSortWithinACloudAndRespectOpaqueGeometry() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.look = RenderLook(view: .textured, style: .unlit)
        for reversed in [false,true] { for occluder in [false,true] {
            var part = ModelScene.MeshPart()
            part.primitive = .points; part.material = 0
            part.positions = [SIMD3(0,0,1),SIMD3(0,0,0)]
            part.colors = [SIMD4(1,0,0,1),SIMD4(0,0,1,1)]
            if reversed { part.positions.reverse(); part.colors.reverse() }
            var source = scene(part), glass = ModelScene.Material(), green = ModelScene.Material()
            glass.baseColor = SIMD4(1,1,1,1); glass.opacity = 0.5; glass.alphaBlend = true
            green.baseColor = SIMD4(0,1,0,1); green.doubleSided = true
            source.materials = [glass,green]
            if occluder {
                var wall = quad(colours: [], normals: true)
                wall.material = 1; wall.positions = wall.positions.map { $0 + SIMD3(0,0,0.5) }
                source.meshes[0].parts.append(wall)
            }
            renderer.show(try renderer.makeScene(source))
            renderer.camera = OrbitCamera(target: .zero, distance: 3, yaw: 0, pitch: 0, near: 0.01, far: 100)
            let p = try renderer.renderOffscreen(width: 128, height: 128).pixel(64,64)
            let actual = [Int(p.r),Int(p.g),Int(p.b),Int(p.a)]
            let expected = occluder ? [128,127,0,255] : [128,0,64,192]
            for i in 0..<4 { XCTAssertEqual(actual[i], expected[i], accuracy: 1) }
        } }
    }

    func testTranslucentPointOrderFollowsTheCurrentPose() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.look = RenderLook(view: .textured, style: .unlit)
        for onGPU in [false,true] {
            var part = ModelScene.MeshPart()
            part.primitive = .points; part.material = 0
            part.positions = [SIMD3(0,0,1),SIMD3(0,0,0)]
            part.colors = [SIMD4(1,0,0,1),SIMD4(0,0,1,1)]
            part.skin = .init(skeleton: 0, joints: [SIMD4(0,0,0,0),SIMD4(1,0,0,0)], weights: [SIMD4(1,0,0,0),SIMD4(1,0,0,0)])
            var source = scene(part), material = ModelScene.Material()
            material.baseColor = SIMD4(1,1,1,1); material.opacity = 0.5; material.alphaBlend = true
            source.materials = [material]; source.skeletons = [.init(joints: [.init(),.init()])]
            var clip = ModelScene.AnimationClip(skeleton: 0, end: 1)
            clip.linearTranslations[0] = .init(times: [0,1], values: [.zero,SIMD3(0,0,-2)])
            source.clips = [clip]
            let gpu = try renderer.makeScene(source)
            renderer.show(gpu); renderer.skinsOnGPU = onGPU
            renderer.camera = OrbitCamera(target: .zero, distance: 3, yaw: 0, pitch: 0, near: 0.01, far: 100)
            for time: Float in [0,1,0] {
                gpu.pose(clip: 0, time: time)
                let p = try renderer.renderOffscreen(width: 128, height: 128).pixel(64,64)
                let actual = [Int(p.r),Int(p.g),Int(p.b),Int(p.a)]
                let expected = time == 0 ? [128,0,64,192] : [64,0,128,192]
                for i in 0..<4 { XCTAssertEqual(actual[i], expected[i], accuracy: 1) }
            }
        }
    }

}
