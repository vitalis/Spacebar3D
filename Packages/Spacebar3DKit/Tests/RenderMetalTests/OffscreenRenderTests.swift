import Foundation
import ImageIO
import ImportRouter
import ModelCore
import RenderMetal
import simd
import UniformTypeIdentifiers
import XCTest

/// Binary STL of a torus lying in the XY plane (Z up, as STL files are).
func torusSTL(segments: Int, sides: Int, major: Float = 3, minor: Float = 1) -> Data {
    func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
        let u = Float(i % segments) / Float(segments) * 2 * .pi, v = Float(j % sides) / Float(sides) * 2 * .pi
        return SIMD3((major + minor * cos(v)) * cos(u), (major + minor * cos(v)) * sin(u), minor * sin(v))
    }
    var data = Data(count: 80)
    let count = segments * sides * 2
    withUnsafeBytes(of: UInt32(count).littleEndian) { data.append(contentsOf: $0) }
    data.reserveCapacity(84 + count * 50)
    func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        for v in [n, a, b, c] { for x in [v.x, v.y, v.z] { withUnsafeBytes(of: x.bitPattern.littleEndian) { data.append(contentsOf: $0) } } }
        data.append(contentsOf: [0, 0])
    }
    for i in 0..<segments {
        for j in 0..<sides {
            let a = point(i, j), b = point(i + 1, j), c = point(i + 1, j + 1), d = point(i, j + 1)
            add(a, b, c); add(a, c, d)
        }
    }
    return data
}

func writePNG(_ image: OffscreenImage, to url: URL) {
    guard let cg = image.cgImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

final class OffscreenRenderTests: XCTestCase {
    static let output = URL(fileURLWithPath: "/tmp/p3d-t3")
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func loadTorus(segments: Int = 64, sides: Int = 32) throws -> (MetalRenderer, ModelScene) {
        let url = folder.appendingPathComponent("torus.stl")
        try torusSTL(segments: segments, sides: sides).write(to: url)
        let scene = try ImportRouter.load(url, format: .stl)
        let renderer = try MetalRenderer()
        renderer.show(try renderer.makeScene(scene))
        return (renderer, scene)
    }

    /// Share of pixels that differ from a render of the empty scene.
    private func coverage(_ image: OffscreenImage, empty: OffscreenImage) -> Double {
        var differing = 0
        for i in stride(from: 0, to: image.bytes.count, by: 4) {
            let d = abs(Int(image.bytes[i]) - Int(empty.bytes[i])) + abs(Int(image.bytes[i + 1]) - Int(empty.bytes[i + 1])) + abs(Int(image.bytes[i + 2]) - Int(empty.bytes[i + 2]))
            if d > 12 { differing += 1 }
        }
        return Double(differing) / Double(image.width * image.height)
    }

    private func difference(_ a: OffscreenImage, _ b: OffscreenImage) -> Double {
        var total = 0
        for i in 0..<a.bytes.count { total += abs(Int(a.bytes[i]) - Int(b.bytes[i])) }
        return Double(total) / Double(a.bytes.count)
    }

    func testEachViewDrawsTheModelAndTheViewsDiffer() throws {
        let (renderer, scene) = try loadTorus()
        XCTAssertEqual(scene.topology.faces, 64 * 32 * 2)
        let (w, h) = (400, 300)
        let empty = try MetalRenderer()
        empty.camera = renderer.camera
        empty.showGrid = renderer.showGrid
        let blank = try empty.renderOffscreen(width: w, height: h)
        writePNG(blank, to: Self.output.appendingPathComponent("empty.png"))

        var images: [String: OffscreenImage] = [:]
        func shoot(_ name: String, _ look: RenderLook) throws {
            renderer.look = look
            let image = try renderer.renderOffscreen(width: w, height: h)
            images[name] = image
            writePNG(image, to: Self.output.appendingPathComponent("\(name).png"))
            XCTAssertGreaterThan(coverage(image, empty: blank), 0.10, "\(name) should cover the model's area")
            XCTAssertLessThan(coverage(image, empty: blank), 0.9, name)
        }
        try shoot("solid", RenderLook(view: .solid))
        try shoot("textured", RenderLook(view: .textured))
        try shoot("textured-metal", RenderLook(view: .textured, metallic: 1, roughness: 0.3))
        try shoot("textured-diffuse", RenderLook(view: .textured, pbr: false))
        try shoot("normal", RenderLook(view: .normal))
        try shoot("solid-flat", RenderLook(view: .solid, flat: true))
        try shoot("normal-flat", RenderLook(view: .normal, flat: true))
        try shoot("solid-wire", RenderLook(view: .solid, wire: true))
        try shoot("textured-wire", RenderLook(view: .textured, wire: true))

        let pairs: [(String, String)] = [("solid", "textured"), ("solid", "normal"), ("textured", "normal"), ("textured", "textured-metal"),
                                         ("textured", "textured-diffuse"), ("solid", "solid-wire")]
        // Solid and solid-flat are not compared: STL carries one normal per face, so smooth and
        // flat look the same for it. GeometryTests covers smooth normals.
        for (a, b) in pairs {
            XCTAssertGreaterThan(difference(images[a]!, images[b]!), 0.05, "\(a) and \(b) should differ")
        }
    }

    func testNormalViewShowsUpwardFacesGreenAndIsTheSameFlatOrSmoothInOrientation() throws {
        let (renderer, _) = try loadTorus(segments: 96, sides: 48)
        // Look straight down onto the torus (Y up after the import): its top surface faces the camera.
        renderer.camera = OrbitCamera.preset(.top, framing: renderer.framing, like: renderer.homeCamera)
        renderer.showGrid = false
        renderer.look = RenderLook(view: .normal)
        let smooth = try renderer.renderOffscreen(width: 200, height: 200)
        renderer.look = RenderLook(view: .normal, flat: true)
        let flat = try renderer.renderOffscreen(width: 200, height: 200)
        writePNG(smooth, to: Self.output.appendingPathComponent("normal-top-smooth.png"))
        // The torus's ring top, seen from above, faces the viewer: normal (0,0,1) in view space = (0.5, 0.5, 1).
        let p = smooth.pixel(100, 100 - 60)      // on the ring, away from the hole
        let q = flat.pixel(100, 100 - 60)
        for (name, px) in [("smooth", p), ("flat", q)] {
            XCTAssertGreaterThan(Int(px.b), 200, "\(name): blue means facing the camera")
            XCTAssertEqual(Int(px.r), 188, accuracy: 40, name)   // sRGB of 0.5
        }
        XCTAssertEqual(Int(p.b), Int(q.b), accuracy: 25)
    }

    func testBackgroundCanBeTransparentWhileTheModelStaysOpaque() throws {
        let (renderer, _) = try loadTorus()
        renderer.backgroundAlpha = 0
        renderer.showGrid = false
        renderer.look = RenderLook(view: .solid)
        let image = try renderer.renderOffscreen(width: 200, height: 160)
        XCTAssertEqual(image.pixel(2, 2).a, 0)
        XCTAssertEqual(image.pixel(100, 80 + 5).a, 255)
        renderer.backgroundAlpha = 1
        XCTAssertEqual(try renderer.renderOffscreen(width: 200, height: 160).pixel(2, 2).a, 255)
    }

    func testSolidColourTintsTheSolidViewAndLightIntensityTheTexturedOne() throws {
        let (renderer, _) = try loadTorus()
        renderer.showGrid = false
        renderer.look = RenderLook(view: .solid)
        let grey = try renderer.renderOffscreen(width: 160, height: 120)
        renderer.solidColor = SIMD3(0.8, 0.2, 0.2)
        let red = try renderer.renderOffscreen(width: 160, height: 120)
        XCTAssertGreaterThan(difference(grey, red), 1)
        renderer.look = RenderLook(view: .textured)
        renderer.lightIntensity = 0.3
        let dim = try renderer.renderOffscreen(width: 160, height: 120)
        renderer.lightIntensity = 2
        let bright = try renderer.renderOffscreen(width: 160, height: 120)
        XCTAssertGreaterThan(difference(dim, bright), 3)
    }

    func testWireHasTheLinesOfEveryTriangleEdgeOnce() throws {
        let (renderer, _) = try loadTorus(segments: 8, sides: 6)
        let scene = try XCTUnwrap(renderer.scene)
        scene.prepareWire()
        // 96 triangles of a closed mesh: V - E + F = 0 -> E = 144 (48 vertices, 96 faces) unique edges.
        XCTAssertEqual(scene.wireLineCount, 144)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, message, file: file, line: line)
}
