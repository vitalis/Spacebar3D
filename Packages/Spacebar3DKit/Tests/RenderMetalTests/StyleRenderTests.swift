import Foundation
import ImportRouter
import ModelCore
@testable import RenderMetal
import simd
import XCTest

final class StyleRenderTests: XCTestCase {
    static let output = URL(fileURLWithPath: "/tmp/p3d-t4")
    private var folder: URL!
    var (w, h) = (400, 300)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// White background, no grid: dark pixels can only come from the model.
    private func loadTorus() throws -> (MetalRenderer, OffscreenImage) {
        let url = folder.appendingPathComponent("torus.stl")
        try torusSTL(segments: 64, sides: 32).write(to: url)
        let scene = try ImportRouter.load(url, format: .stl)
        let renderer = try MetalRenderer()
        renderer.backgroundColor = SIMD3(1, 1, 1)
        renderer.showGrid = false
        // These tests measure the model alone, not what it casts on the floor.
        renderer.showShadow = false
        let empty = try renderer.renderOffscreen(width: w, height: h)
        renderer.show(try renderer.makeScene(scene))
        return (renderer, empty)
    }

    private func covered(_ a: OffscreenImage, _ empty: OffscreenImage) -> [Bool] {
        var out = [Bool](repeating: false, count: a.width * a.height)
        for p in 0..<out.count {
            let i = p * 4
            let d = abs(Int(a.bytes[i]) - Int(empty.bytes[i])) + abs(Int(a.bytes[i + 1]) - Int(empty.bytes[i + 1])) + abs(Int(a.bytes[i + 2]) - Int(empty.bytes[i + 2]))
            out[p] = d > 12
        }
        return out
    }
    private func dark(_ a: OffscreenImage) -> [Bool] {
        (0..<(a.width * a.height)).map { max(a.bytes[$0 * 4], a.bytes[$0 * 4 + 1], a.bytes[$0 * 4 + 2]) < 120 }
    }
    private func difference(_ a: OffscreenImage, _ b: OffscreenImage) -> Double {
        var total = 0
        for i in 0..<a.bytes.count { total += abs(Int(a.bytes[i]) - Int(b.bytes[i])) }
        return Double(total) / Double(a.bytes.count)
    }

    func testEachStyleCoversTheModelAndDiffersFromTheViewsAndTheOtherStyles() throws {
        let (r, empty) = try loadTorus()
        var images: [String: OffscreenImage] = [:]
        func shoot(_ name: String, _ look: RenderLook) throws {
            r.look = look
            let image = try r.renderOffscreen(width: w, height: h)
            images[name] = image
            writePNG(image, to: Self.output.appendingPathComponent("\(name).png"))
        }
        try shoot("textured", RenderLook(view: .textured))
        try shoot("solid", RenderLook(view: .solid))
        for (name, style) in [("unlit", RenderLook.Style.unlit), ("anime", .anime), ("celShaded", .celShaded), ("retro", .retro), ("voxel", .voxel)] {
            try shoot(name, RenderLook(view: .textured, style: style))
            try shoot("\(name)-wire", RenderLook(view: .textured, wire: true, style: style))
            try shoot("\(name)-solid", RenderLook(view: .solid, style: style))
            let share = Double(covered(images[name]!, empty).filter { $0 }.count) / Double(w * h)
            XCTAssertGreaterThan(share, 0.10, "\(name) covers the model's area")
            XCTAssertLessThan(share, 0.9, name)
            XCTAssertGreaterThan(difference(images[name]!, images["textured"]!), 0.05, "\(name) differs from textured")
            XCTAssertGreaterThan(difference(images[name]!, images["solid"]!), 0.05, "\(name) differs from solid")
            XCTAssertGreaterThan(difference(images[name]!, images["\(name)-wire"]!), 0.02, "\(name): wire on differs from off")
        }
        for (a, b) in [("unlit", "anime"), ("anime", "celShaded")] {
            XCTAssertGreaterThan(difference(images[a]!, images[b]!), 0.05, "\(a) and \(b) differ")
        }
        // The normal view ignores unlit and cartoon.
        r.look = RenderLook(view: .normal)
        let normal = try r.renderOffscreen(width: w, height: h)
        r.look = RenderLook(view: .normal, style: .anime)
        XCTAssertEqual(difference(normal, try r.renderOffscreen(width: w, height: h)), 0, accuracy: 1e-9)
    }

    func testUnlitIgnoresTheLightAndTheLitStylesDoNot() throws {
        let (r, _) = try loadTorus()
        func render(_ style: RenderLook.Style, light: Float) throws -> OffscreenImage {
            r.look = RenderLook(view: .textured, style: style)
            r.lightIntensity = light
            return try r.renderOffscreen(width: w, height: h)
        }
        XCTAssertEqual(difference(try render(.unlit, light: 0.3), try render(.unlit, light: 2)), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(difference(try render(.anime, light: 0.3), try render(.anime, light: 2)), 3)
    }

    /// The light slider acts on the Solid view too: dimmer below one, brighter above.
    func testTheSolidViewFollowsTheLight() throws {
        let (r, _) = try loadTorus()
        r.backgroundColor = SIMD3(0, 0, 0)
        func brightness(_ light: Float) throws -> Int {
            r.look = RenderLook(view: .solid)
            r.lightIntensity = light
            let bytes = try r.renderOffscreen(width: w, height: h).bytes
            // Green alone: the fourth byte of each point is its opacity.
            return stride(from: 1, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
        }
        let dim = try brightness(0.2), usual = try brightness(1), bright = try brightness(2)
        XCTAssertLessThan(Double(dim), Double(usual) * 0.8)
        XCTAssertGreaterThan(Double(bright), Double(usual) * 1.1)
    }

    func testOutlineAddsDarkPixelsAroundTheSilhouetteWithoutCracks() throws {
        // The outline is a fixed share of the view (0.0036 of clip space), so
        // render large enough for it to be more than one pixel wide.
        (w, h) = (1200, 900)
        let (r, empty) = try loadTorus()
        r.look = RenderLook(view: .textured, style: .unlit)
        let unlit = try r.renderOffscreen(width: w, height: h)
        let inside = covered(unlit, empty)
        // Silhouette boundary: covered pixels with an uncovered 4-neighbour.
        var boundary: [(Int, Int)] = []
        for y in 1..<(h - 1) { for x in 1..<(w - 1) where inside[y * w + x] {
            if !inside[y * w + x - 1] || !inside[y * w + x + 1] || !inside[(y - 1) * w + x] || !inside[(y + 1) * w + x] { boundary.append((x, y)) }
        } }
        XCTAssertGreaterThan(boundary.count, 600)
        XCTAssertEqual(dark(unlit).filter { $0 }.count, 0, "no ink without an outline")

        for (name, style) in [("anime", RenderLook.Style.anime), ("celShaded", .celShaded)] {
            r.look = RenderLook(view: .textured, style: style)
            let image = try r.renderOffscreen(width: w, height: h)
            let ink = dark(image)
            // Every stretch of the silhouette has ink within 3 pixels: the hull has no gaps.
            var missing = 0
            for (x, y) in boundary {
                var found = false
                for dy in -3...3 { for dx in -3...3 where x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h && ink[(y + dy) * w + x + dx] { found = true } }
                if !found { missing += 1 }
            }
            XCTAssertLessThan(Double(missing) / Double(boundary.count), 0.02, "\(name): outline has gaps (\(missing) of \(boundary.count))")
        }
    }

    func testOutlineNormalsAreSharedByEveryCornerAtOnePosition() throws {
        let (r, _) = try loadTorus()
        let scene = try XCTUnwrap(r.scene)
        scene.prepareOutline()
        XCTAssertTrue(scene.isOutlineReady)
        let part = try XCTUnwrap(scene.parts.first)
        let v = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
        let n = try XCTUnwrap(part.outlineNormals).contents().assumingMemoryBound(to: Float.self)
        var byPosition: [SIMD3<Float>: SIMD3<Float>] = [:]
        var ownDiffers = 0
        for i in 0..<part.vertexCount {
            let p = SIMD3(v[i * 6], v[i * 6 + 1], v[i * 6 + 2])
            let hull = SIMD3(n[i * 3], n[i * 3 + 1], n[i * 3 + 2])
            XCTAssertEqual(simd_length(hull), 1, accuracy: 1e-3)
            if let seen = byPosition[p] { XCTAssertEqual(simd_distance(seen, hull), 0, accuracy: 1e-6) } else { byPosition[p] = hull }
            if simd_distance(hull, SIMD3(v[i * 6 + 3], v[i * 6 + 4], v[i * 6 + 5])) > 0.01 { ownDiffers += 1 }
        }
        // A face-by-face mesh is merged by position at upload, so each position is one vertex
        // and its hull normal is the vertex's own averaged normal.
        XCTAssertEqual(byPosition.count, part.vertexCount, "corners at one position were merged")
        XCTAssertEqual(ownDiffers, 0)
        XCTAssertTrue(part.faceted)
    }

    /// The Anime style smooths an image's fine detail towards its surroundings. Where the
    /// surroundings are more or less see-through than a spot, the spot keeps its own colour:
    /// an image of one colour all over stays that colour, however its alpha varies.
    func testAnimeSmoothingLeavesTheColourOfAnImageWhoseAlphaVaries() throws {
        // A square with an image of one grey, in blocks of four by four pixels that are
        // alternately six and nine tenths there.
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        part.uv0 = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.material = 0
        var material = ModelScene.Material()
        material.baseColor = SIMD4(1, 1, 1, 1); material.baseColorTexture = 0
        material.alphaBlend = true; material.doubleSided = true
        var pixels: [UInt8] = []
        for y in 0..<64 { for x in 0..<64 { pixels += [128, 128, 128, (x / 4 + y / 4) % 2 == 0 ? 153 : 230] } }
        var scene = ModelScene()
        scene.materials = [material]
        scene.textures = [.pixels(width: 64, height: 64, rgba: pixels)]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured, style: .anime)
        // Small enough that a pixel of the picture takes in more than one of the image: what a
        // spot is smoothed towards is then an average over blocks of both kinds.
        let side = 64
        let image = try renderer.renderOffscreen(width: side, height: side)
        let frame = renderer.frameUniforms(size: CGSize(width: side, height: side))
        /// The colour drawn in the middle of a block of the image, with its alpha taken out again.
        func grey(block i: Int, _ j: Int) -> (grey: Double, alpha: Int) {
            let u = (Float(i) + 0.5) / 16, v = (Float(j) + 0.5) / 16
            let clip = frame.viewProj * SIMD4(2 * u - 1, 1 - 2 * v, 0, 1)
            let p = image.pixel(Int((clip.x / clip.w + 1) / 2 * Float(side)), Int((1 - clip.y / clip.w) / 2 * Float(side)))
            return (Double(p.g) * 255 / Double(max(p.a, 1)), Int(p.a))
        }
        for (i, j) in [(7, 7), (8, 8), (6, 8)] {
            let faint = grey(block: i, j), strong = grey(block: i + 1, j)
            XCTAssertNotEqual(faint.alpha, strong.alpha, accuracy: 30, "the two blocks differ in how much is there: \(faint), \(strong)")
            XCTAssertEqual(faint.grey, strong.grey, accuracy: 4, "block \(i), \(j): \(faint) beside \(strong)")
        }
    }

    /// The clay view lights a ball by the way each place faces the eye. It took the way it
    /// faces the middle of the view instead: a ball off to one side had its rim light
    /// weak on one edge and wide on the other, and changed as the model was moved about.
    func testTheClayLooksTheSameWhereverTheModelIsInTheView() throws {
        // A ball of radius one, smooth.
        var part = ModelScene.MeshPart()
        let rings = 48, sides = 96
        for r in 0...rings {
            let a = Float.pi * Float(r) / Float(rings)
            for s in 0...sides {
                let b = 2 * Float.pi * Float(s) / Float(sides)
                let p = SIMD3(sin(a) * cos(b), cos(a), sin(a) * sin(b))
                part.positions.append(p); part.normals.append(p)
            }
        }
        for r in 0..<rings { for s in 0..<sides {
            let i = UInt32(r * (sides + 1) + s), j = i + UInt32(sides + 1)
            part.triangleIndices += [i, i + 1, j, i + 1, j + 1, j]
        } }
        var source = ModelScene()
        source.meshes = [.init(parts: [part])]
        source.nodes = [.init(mesh: 0)]
        let renderer = try MetalRenderer()
        renderer.backgroundAlpha = 0; renderer.showGrid = false; renderer.showShadow = false
        renderer.look = RenderLook(view: .solid)
        renderer.show(try renderer.makeScene(source))
        let side = 300
        /// The mean brightness of the ball's rim and of its middle, where it is drawn `aside`
        /// of the view's middle, to the right and up.
        func rimAndMiddle(_ aside: SIMD2<Float>) throws -> (rim: Double, middle: Double) {
            var camera = OrbitCamera(target: SIMD3(-aside.x, -aside.y, 0), distance: 10, yaw: 0, pitch: 0, near: 0.01, far: 100)
            camera.cancelMotion()
            renderer.camera = camera
            let image = try renderer.renderOffscreen(width: side, height: side)
            var inside: [(Int, Int)] = []
            for y in 0..<side { for x in 0..<side where image.pixel(x, y).a > 250 { inside.append((x, y)) } }
            XCTAssertFalse(inside.contains { $0.0 == 0 || $0.1 == 0 || $0.0 == side - 1 || $0.1 == side - 1 }, "the ball is wholly in view, moved \(aside)")
            let cx = Double(inside.map(\.0).reduce(0, +)) / Double(inside.count), cy = Double(inside.map(\.1).reduce(0, +)) / Double(inside.count)
            let radius = (Double(inside.count) / .pi).squareRoot()
            var rim: [Double] = [], middle: [Double] = []
            for (x, y) in inside {
                let r = hypot(Double(x) - cx, Double(y) - cy) / radius
                let value = Double(image.pixel(x, y).r)
                if r > 0.86 && r < 0.96 { rim.append(value) } else if r < 0.5 { middle.append(value) }
            }
            return (rim.reduce(0, +) / Double(rim.count), middle.reduce(0, +) / Double(middle.count))
        }
        let centred = try rimAndMiddle(.zero)
        // Each still wholly in the view, which is 30 degrees high.
        for aside in [SIMD2<Float>(1.6, 0), SIMD2(-1.6, 0), SIMD2(0, 1.6), SIMD2(0, -1.6), SIMD2(1.5, 1.5), SIMD2(-1.5, -1.5)] {
            let moved = try rimAndMiddle(aside)
            XCTAssertEqual(moved.rim, centred.rim, accuracy: 3, "rim, moved \(aside)")
            XCTAssertEqual(moved.middle, centred.middle, accuracy: 3, "middle, moved \(aside)")
        }
    }

}


/// A mesh stored face by face (STL) is merged to its distinct positions at upload and still
/// looks faceted; a mesh with real shared, smooth normals is left alone.
final class FacetedUploadTests: XCTestCase {
    private func cube(faceNormals: Bool) -> ModelScene {
        let c: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
        let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
        var part = ModelScene.MeshPart()
        for q in quads {
            let n = simd_normalize(simd_cross(c[q[1]] - c[q[0]], c[q[2]] - c[q[0]]))
            for i in [0, 1, 2, 0, 2, 3] {
                part.positions.append(c[q[i]])
                part.normals.append(faceNormals ? n : simd_normalize(c[q[i]]))
            }
        }
        part.triangleIndices = (0..<UInt32(part.positions.count)).map { $0 }
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    func testFaceByFaceMeshIsMergedAndStaysFaceted() throws {
        let renderer = try MetalRenderer()
        // The model alone: its faint image in the floor is seen almost edge-on, where the
        // shading of a sliver depends on how its face happens to be cut into triangles.
        renderer.showShadow = false
        let faceted = try renderer.makeScene(cube(faceNormals: true))
        XCTAssertEqual(faceted.vertexCount, 8)
        XCTAssertTrue(try XCTUnwrap(faceted.parts.first).faceted)
        let smooth = try renderer.makeScene(cube(faceNormals: false))
        XCTAssertEqual(smooth.vertexCount, 36, "a mesh with per-corner normals of its own is not merged")
        XCTAssertFalse(try XCTUnwrap(smooth.parts.first).faceted)

        // The merged cube looks the same whether or not flat shading is asked for, and the
        // same as the unmerged cube shaded flat.
        func shot(_ scene: GPUScene, flat: Bool) throws -> OffscreenImage {
            renderer.show(scene)
            renderer.look = RenderLook(view: .solid, flat: flat)
            return try renderer.renderOffscreen(width: 200, height: 160)
        }
        let a = try shot(faceted, flat: false), b = try shot(faceted, flat: true), c = try shot(smooth, flat: true), d = try shot(smooth, flat: false)
        XCTAssertEqual(a.bytes, b.bytes)
        XCTAssertEqual(a.bytes, c.bytes)
        XCTAssertNotEqual(a.bytes, d.bytes)
    }

    /// A part an importer already merged (STL) goes up as it is and draws like the
    /// face-by-face version of the same mesh.
    func testAPartMergedByTheImporterIsDrawnFaceted() throws {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
        for q: [UInt32] in [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]] {
            part.triangleIndices += [q[0], q[1], q[2], q[0], q[2], q[3]]
        }
        part.faceted = true
        var merged = ModelScene()
        merged.meshes = [ModelScene.Mesh(parts: [part])]
        merged.nodes = [ModelScene.Node(mesh: 0)]

        let renderer = try MetalRenderer()
        let a = try renderer.makeScene(merged), b = try renderer.makeScene(cube(faceNormals: true))
        XCTAssertEqual(a.vertexCount, 8)
        XCTAssertTrue(try XCTUnwrap(a.parts.first).faceted)
        for look in [RenderLook(view: .solid), RenderLook(view: .normal), RenderLook(view: .solid, style: .celShaded)] {
            renderer.look = look
            if look.needsOutline { a.prepareOutline(); b.prepareOutline() }
            renderer.show(a)
            let first = try renderer.renderOffscreen(width: 200, height: 160)
            renderer.show(b)
            XCTAssertEqual(first.bytes, try renderer.renderOffscreen(width: 200, height: 160).bytes)
        }
    }
}

/// The model stands on the floor: there is a soft shadow under it, and none when it is off.
final class ShadowRenderTests: XCTestCase {
    func testTheModelCastsASoftShadowOnTheFloorBesideIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A unit cube, as text.
        let url = folder.appendingPathComponent("cube.obj")
        try """
        v -1 -1 -1\nv 1 -1 -1\nv 1 1 -1\nv -1 1 -1\nv -1 -1 1\nv 1 -1 1\nv 1 1 1\nv -1 1 1
        f 1 2 3 4\nf 5 8 7 6\nf 1 5 6 2\nf 2 6 7 3\nf 3 7 8 4\nf 5 1 4 8
        """.write(to: url, atomically: true, encoding: .utf8)
        let renderer = try MetalRenderer()
        renderer.backgroundColor = SIMD3(1, 1, 1)
        renderer.showGrid = false
        renderer.show(try renderer.makeScene(try ImportRouter.load(url, format: .obj)))
        func brightness(_ image: OffscreenImage, _ x: Int, _ y: Int) -> Int { let p = image.pixel(x, y); return Int(p.r) + Int(p.g) + Int(p.b) }
        let (w, h) = (400, 300)
        let with = try renderer.renderOffscreen(width: w, height: h)
        renderer.showShadow = false
        let without = try renderer.renderOffscreen(width: w, height: h)
        // Somewhere beside the model the floor is darker with the shadow than without it,
        // and nowhere lighter; the far corners of the picture are untouched.
        var darker = 0
        for y in 0..<h { for x in 0..<w {
            let a = brightness(with, x, y), b = brightness(without, x, y)
            XCTAssertLessThanOrEqual(a, b + 3, "\\(x),\\(y)")
            if a < b - 30 { darker += 1 }
        } }
        XCTAssertGreaterThan(darker, 300)
        XCTAssertEqual(brightness(with, 2, 2), brightness(without, 2, 2))
        XCTAssertEqual(brightness(with, w - 3, 2), brightness(without, w - 3, 2))
    }
}
