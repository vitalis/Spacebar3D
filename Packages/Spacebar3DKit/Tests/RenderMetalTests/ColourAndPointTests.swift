import ModelCore
@testable import RenderMetal
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
            // Half of red over half of blue, mixed as light: a quarter of the light is blue.
            // Where nothing is behind, as the colour the screen shows times its coverage.
            let expected = occluder ? [188,188,0,255] : [160,0,117,192]
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
                // The nearer of the two, half there, over the other, mixed as light.
                let expected = time == 0 ? [160,0,117,192] : [117,0,160,192]
                for i in 0..<4 { XCTAssertEqual(actual[i], expected[i], accuracy: 1) }
            }
        }
    }

    /// The middle of a square that faces the viewer, as light (not as screen numbers).
    private func middle(of material: ModelScene.Material, look: RenderLook, light: Float, normal: SIMD3<Float>? = nil) throws -> SIMD3<Double> {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        var part = quad(colours: [], normals: true)
        if let normal { part.normals = [SIMD3<Float>](repeating: simd_normalize(normal), count: 4) }
        part.material = 0
        var source = scene(part)
        source.materials = [material]
        renderer.show(try renderer.makeScene(source))
        renderer.camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100)
        renderer.look = look
        renderer.lightIntensity = light
        let pixel = try renderer.renderOffscreen(width: 64, height: 64).pixel(32, 32)
        func asLight(_ value: UInt8) -> Double { let v = Double(value) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return SIMD3(asLight(pixel.r), asLight(pixel.g), asLight(pixel.b))
    }

    /// More light makes a surface brighter, not another colour. Each of red, green and
    /// blue used to be eased towards white by itself: a strong orange ran out of red
    /// first, its green went on rising, and it turned yellow.
    func testMoreLightDoesNotChangeASurfacesHue() throws {
        var orange = ModelScene.Material()
        orange.baseColor = SIMD4(1, 0.6, 0.2, 1); orange.roughness = 1; orange.metallic = 0
        for view in [RenderLook.View.textured, .solid] {
            var tinted = orange
            if view == .solid { tinted.baseColor = SIMD4(1, 1, 1, 1) }
            let dim = try middle(of: tinted, look: RenderLook(view: view), light: 0.5)
            let bright = try middle(of: tinted, look: RenderLook(view: view), light: 2.5)
            XCTAssertGreaterThan(bright.x, dim.x, "\(view)")
            XCTAssertEqual(bright.y / bright.x, dim.y / dim.x, accuracy: 0.06, "\(view)")
            XCTAssertEqual(bright.z / bright.x, dim.z / dim.x, accuracy: 0.06, "\(view)")
        }
    }

    /// Unshaded shows a colour half as bright again. The brightest third of an image all
    /// came out white; eased towards white instead, two bright shades stay two shades.
    func testUnshadedKeepsBrightShadesApart() throws {
        var pale = ModelScene.Material(), paler = ModelScene.Material()
        pale.baseColor = SIMD4(0.86, 0.86, 0.86, 1); paler.baseColor = SIMD4(0.98, 0.98, 0.98, 1)
        let look = RenderLook(view: .textured, style: .unlit)
        let a = try middle(of: pale, look: look, light: 1), b = try middle(of: paler, look: look, light: 1)
        XCTAssertGreaterThan(b.x, a.x + 0.01)
        // A colour in the lower half is shown as before: half as bright again.
        var mid = ModelScene.Material()
        mid.baseColor = SIMD4(0.5, 0.5, 0.5, 1)
        XCTAssertEqual(try middle(of: mid, look: look, light: 1).x, 0.2140 * 1.5, accuracy: 0.01)
    }

    /// Near an outline a smoothed normal can lean a little past it, away from the viewer.
    /// The shine there was cut to nothing, a dark notch in the highlight; it is the same
    /// shine as a hair's breadth before the outline.
    func testTheShineDoesNotStopWhereANormalLeansPastTheOutline() throws {
        var metal = ModelScene.Material()
        metal.baseColor = SIMD4(1, 0.85, 0.6, 1); metal.metallic = 1; metal.roughness = 1
        let look = RenderLook(view: .textured)
        // Up, and a degree towards the viewer or a degree away.
        let before = try middle(of: metal, look: look, light: 1, normal: SIMD3(0, 1, 0.0175))
        let past = try middle(of: metal, look: look, light: 1, normal: SIMD3(0, 1, -0.0175))
        XCTAssertGreaterThan(before.x, 0.05, "the surface is lit")
        XCTAssertEqual(past.x, before.x, accuracy: before.x * 0.05)
    }

    /// The floor shadow fades out from under the model evenly. Made from seventeen samples
    /// on two rings, it went down in steps instead, each ring's samples leaving the model
    /// together, and a thin part cast eight faint copies of itself.
    func testTheFloorShadowFadesEvenly() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = true
        renderer.backgroundColor = SIMD3(1, 1, 1)
        // A red plate seen from straight above: its shadow shows all round it.
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, 0.5, -1), SIMD3(1, 0.5, -1), SIMD3(1, 0.5, 1), SIMD3(-1, 0.5, 1), SIMD3(-1, 0, -1), SIMD3(1, 0, -1), SIMD3(1, 0, 1), SIMD3(-1, 0, 1)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 8)
        part.triangleIndices = [0, 2, 1, 0, 3, 2, 4, 6, 5, 4, 7, 6]
        part.material = 0
        var red = ModelScene.Material()
        red.baseColor = SIMD4(1, 0, 0, 1); red.unlit = true; red.doubleSided = true
        var source = scene(part)
        source.materials = [red]
        renderer.show(try renderer.makeScene(source))
        var above = renderer.homeCamera
        above.yaw = 0; above.pitch = .pi / 2 - 0.001; above.distance *= 1.2
        renderer.camera = above
        renderer.look = RenderLook(view: .textured)
        let side = 1200
        let image = try renderer.renderOffscreen(width: side, height: side)
        // Along the middle row, from the plate's edge outwards.
        var row = (0..<side).map { image.pixel($0, side / 2) }
        row = Array(row.drop { !($0.r > 200 && $0.g < 60) })
        let floor = row.drop { $0.r > 200 && $0.g < 60 }.map { Double($0.g) / 255 }
        let dark = try XCTUnwrap(floor.first), light = try XCTUnwrap(floor.max())
        XCTAssertGreaterThan(light - dark, 0.08, "there is a shadow to measure")
        let fade = floor.prefix { $0 < dark + (light - dark) * 0.97 }
        XCTAssertGreaterThan(fade.count, 20, "the fade is wide enough to judge")
        let steps = zip(fade, fade.dropFirst()).map { $1 - $0 }
        let even = (light - dark) / Double(fade.count)
        XCTAssertLessThan(try XCTUnwrap(steps.max()), even * 3.5, "largest step, against \(even) for an even fade over \(fade.count) pixels")
    }

    /// A glossy curve seen small: its highlight is far narrower than a pixel. Whether a
    /// pixel's middle caught it was luck, and as the view moved by an eighth of a pixel
    /// the brightest pixel went from nearly black to white and back: the surface sparkled.
    /// Where the surface turns that much within a pixel, the highlight is spread over it.
    func testAGlossyCurveSeenSmallDoesNotSparkleAsTheViewMoves() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        renderer.backgroundColor = SIMD3(0, 0, 0)
        renderer.look = RenderLook(view: .textured)
        // Black, so that only the shine shows, and turning through ninety degrees across.
        var part = quad(colours: [], normals: true)
        part.normals = [SIMD3<Float>(-0.8, -0.8, 1), SIMD3(0.8, -0.8, 1), SIMD3(0.8, 0.8, 1), SIMD3(-0.8, 0.8, 1)].map(simd_normalize)
        part.material = 0
        var source = scene(part)
        var gloss = ModelScene.Material()
        gloss.baseColor = SIMD4(0, 0, 0, 1); gloss.metallic = 0; gloss.roughness = 0.05; gloss.authoredPBR = true
        source.materials = [gloss]
        renderer.show(try renderer.makeScene(source))
        let side = 16
        var brightest: [Int] = []
        for k in 0..<8 {
            var camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100)
            let pixel = 2 * camera.distance * tan(camera.fovY / 2) / Float(side)
            camera.target = SIMD3(pixel * Float(k) / 8, pixel * Float(k) / 8 * 0.6, 0)
            renderer.camera = camera
            let image = try renderer.renderOffscreen(width: side, height: side)
            brightest.append(stride(from: 1, to: image.bytes.count, by: 4).map { Int(image.bytes[$0]) }.max() ?? 0)
        }
        let most = try XCTUnwrap(brightest.max()), least = try XCTUnwrap(brightest.min())
        XCTAssertGreaterThan(least, 20, "the shine is there: \(brightest)")
        XCTAssertLessThan(most - least, most / 3, "\(brightest)")
    }

    /// See-through surfaces and the pixels an edge runs through mix light, not the numbers
    /// the screen stores. Half of white over black is half the light, which the screen
    /// stores as 188; mixed as stored numbers it came out 128, so glass looked dark and
    /// thick and a bright model's outline thin and stepped.
    func testGlassAndEdgesMixLight() throws {
        func asLight(_ value: UInt8) -> Double { let v = Double(value) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.look = RenderLook(view: .textured)
        var white = ModelScene.Material()
        white.baseColor = SIMD4(1, 1, 1, 1); white.unlit = true; white.doubleSided = true
        var glass = white
        glass.opacity = 0.5
        var black = white
        black.baseColor = SIMD4(0, 0, 0, 1)
        // In front of a black wall, which is drawn here: what is behind the view's own
        // background is mixed by whoever lays the picture over something.
        func scene(_ front: ModelScene.Material, turned: Float = 0) -> (ModelScene, [SIMD3<Float>]) {
            let turn = simd_float3x3(simd_quatf(angle: turned, axis: SIMD3(0, 0, 1)))
            var square = quad(colours: [], normals: true)
            square.positions = square.positions.map { turn * $0 }
            square.material = 0
            var wall = quad(colours: [], normals: true)
            wall.positions = wall.positions.map { $0 * 4 - SIMD3(0, 0, 1) }
            wall.material = 1
            var source = self.scene(square)
            source.meshes[0].parts.append(wall)
            source.materials = [front, black]
            return (source, square.positions)
        }
        renderer.show(try renderer.makeScene(scene(glass).0))
        renderer.camera = OrbitCamera(target: .zero, distance: 6, yaw: 0, pitch: 0, near: 0.01, far: 100)
        let middle = try renderer.renderOffscreen(width: 128, height: 128).pixel(64, 64)
        XCTAssertEqual(Int(middle.r), 188, accuracy: 2, "half of white over black")

        // A white square, turned a little so that its edges cross the pixels at every
        // share: added up, the light is the area it covers. Mixed as stored numbers, each
        // pixel an edge runs through came out about a quarter of a pixel short.
        let (square, corners3) = scene(white, turned: 0.17)
        renderer.show(try renderer.makeScene(square))
        // Wholly in the picture.
        renderer.camera = OrbitCamera(target: .zero, distance: 5, yaw: 0, pitch: 0, near: 0.01, far: 100)
        let (width, height) = (480, 320)
        let image = try renderer.renderOffscreen(width: width, height: height)
        let viewProj = renderer.frameUniforms(size: CGSize(width: width, height: height)).viewProj
        let corners = corners3.map { p -> SIMD2<Double> in
            let c = viewProj * SIMD4(p, 1)
            return SIMD2(Double((c.x / c.w * 0.5 + 0.5) * Float(width)), Double((0.5 - c.y / c.w * 0.5) * Float(height)))
        }
        let area = abs((0..<4).reduce(0.0) { $0 + corners[$1].x * corners[($1 + 1) % 4].y - corners[($1 + 1) % 4].x * corners[$1].y }) / 2
        var light = 0.0
        for y in 0..<height { for x in 0..<width { light += asLight(image.pixel(x, y).r) } }
        // About 950 pixels have an edge running through them.
        var full = 0, part = 0, partLight = 0.0, values: [UInt8: Int] = [:]
        for y in 0..<height { for x in 0..<width { let r = image.pixel(x, y).r; if r == 255 { full += 1 } else if r > 0 { part += 1; partLight += asLight(r); values[r, default: 0] += 1 } } }
        XCTAssertEqual(light, area, accuracy: 20, "light against the area covered")
    }
}
