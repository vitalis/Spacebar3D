import CoreGraphics
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// The polygon wire over a surface: lines at full strength while they are wide apart on the
/// screen, fainter where they crowd, so that a dense model is not painted black.
final class WireFadeTests: XCTestCase {
    /// A ball one unit in radius about the origin, `around` squares to its equator and half
    /// as many from pole to pole, each square two triangles.
    private func ball(around: Int) -> ModelScene {
        let rings = around / 2
        var part = ModelScene.MeshPart()
        for r in 0...rings {
            let phi = Float.pi * Float(r) / Float(rings)
            for a in 0...around {
                let theta = 2 * Float.pi * Float(a) / Float(around)
                let p = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                part.positions.append(p); part.normals.append(p)
            }
        }
        let row = UInt32(around + 1)
        for r in 0..<UInt32(rings) {
            for a in 0..<UInt32(around) {
                let i = r * row + a
                part.triangleIndices += [i, i + 1, i + row, i + 1, i + row + 1, i + row]
            }
        }
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    /// The ball without and with its wire, seen level from +z, and where it is in the picture.
    private struct Shot {
        let plain: OffscreenImage, wired: OffscreenImage
        let viewProj: simd_float4x4
        /// The pixel of the ball's middle, and the radius of its outline in pixels.
        let middle: SIMD2<Float>, radius: Float

        func brightness(_ image: OffscreenImage, _ x: Int, _ y: Int) -> Double {
            let p = image.pixel(x, y)
            return Double(p.r) + Double(p.g) + Double(p.b)
        }

        /// The share of the plain surface's brightness left under the wire, over the ring
        /// between two shares of the outline's radius.
        func kept(from inner: Float, to outer: Float) -> Double {
            var plainSum = 0.0, wiredSum = 0.0
            for y in 0..<plain.height {
                for x in 0..<plain.width {
                    let away = simd_distance(SIMD2(Float(x) + 0.5, Float(y) + 0.5), middle) / radius
                    guard away >= inner, away < outer else { continue }
                    plainSum += brightness(plain, x, y); wiredSum += brightness(wired, x, y)
                }
            }
            return wiredSum / plainSum
        }

        func pixel(of point: SIMD3<Float>) -> (x: Int, y: Int) {
            let clip = viewProj * SIMD4(point, 1)
            return (Int((clip.x / clip.w * 0.5 + 0.5) * Float(plain.width)), Int((0.5 - clip.y / clip.w * 0.5) * Float(plain.height)))
        }

        /// How much a level line through a pixel takes from the surface, added up across
        /// the line: its opacity times its width, however its one pixel of width falls on
        /// the rows.
        func weight(ofTheLevelLineAt point: SIMD3<Float>) -> Double {
            let at = pixel(of: point)
            return (-6...6).reduce(0.0) { $0 + 1 - brightness(wired, at.x, at.y + $1) / brightness(plain, at.x, at.y + $1) }
        }
    }

    private func shoot(_ scene: ModelScene, width: Int, height: Int, distance: Float? = nil, pixelsPerPoint: Float = 1) throws -> Shot {
        let renderer = try MetalRenderer()
        renderer.pixelsPerPoint = pixelsPerPoint
        renderer.show(try renderer.makeScene(scene))
        renderer.camera.yaw = 0; renderer.camera.pitch = 0
        if let distance { renderer.camera.distance = distance }
        renderer.look = RenderLook(view: .textured)
        let plain = try renderer.renderOffscreen(width: width, height: height)
        renderer.look = RenderLook(view: .textured, wire: true)
        let wired = try renderer.renderOffscreen(width: width, height: height)
        let uniforms = renderer.frameUniforms(size: CGSize(width: width, height: height))
        let clip = uniforms.viewProj * SIMD4<Float>(0, 0, 0, 1)
        let middle = SIMD2((clip.x / clip.w * 0.5 + 0.5) * Float(width), (0.5 - clip.y / clip.w * 0.5) * Float(height))
        // A ball's outline is where the lines of sight touch it, a little wider than its equator.
        let radius = uniforms.proj.columns.1.y * Float(height) / 2 * tan(asin(1 / simd_length(renderer.camera.position)))
        return Shot(plain: plain, wired: wired, viewProj: uniforms.viewProj, middle: middle, radius: radius)
    }

    /// The middle of the edge along the equator that starts at the point nearest the camera.
    private func nearestEquatorEdge(around: Int) -> SIMD3<Float> {
        let next = 2 * Float.pi * (Float(around / 4) + 1) / Float(around)
        return (SIMD3<Float>(0, 0, 1) + SIMD3(cos(next), 0, sin(next))) / 2
    }

    /// A quarter of a million triangles in a small picture: several lines to every pixel.
    /// Each line at full strength, they left a fifth of the surface's brightness.
    func testACrowdedWireLeavesTheSurfaceMostOfItsBrightness() throws {
        let kept = try shoot(ball(around: 512), width: 400, height: 300).kept(from: 0, to: 0.6)
        XCTAssertGreaterThan(kept, 0.75)
        XCTAssertLessThan(kept, 0.97, "the wire still shows, as a veil")
    }

    /// Towards its outline a surface turns away from the eye and its lines close up on the
    /// screen, however wide apart they are on the surface.
    func testTheLinesDoNotPileUpTowardsTheOutline() throws {
        let shot = try shoot(ball(around: 192), width: 800, height: 600)
        let ring = shot.kept(from: 0.85, to: 0.97)
        XCTAssertGreaterThan(ring, 0.75)
        XCTAssertGreaterThan(ring, shot.kept(from: 0, to: 0.5) - 0.05, "no darker than the middle")
    }

    /// A model of few polygons keeps the wire it had: black at 60%, one pixel wide.
    func testLinesWideApartAreAtFullStrength() throws {
        let shot = try shoot(ball(around: 12), width: 801, height: 601)
        XCTAssertEqual(shot.weight(ofTheLevelLineAt: nearestEquatorEdge(around: 12)), 0.6, accuracy: 0.06)
    }

    /// The fading is by how the lines fall on the screen, not by how many the model has:
    /// close up, the crowded ball's lines are wide apart and at full strength again.
    func testACloseLookAtACrowdedWireShowsItsLinesInFull() throws {
        let shot = try shoot(ball(around: 512), width: 401, height: 301, distance: 1.2)
        XCTAssertEqual(shot.weight(ofTheLevelLineAt: nearestEquatorEdge(around: 512)), 0.6, accuracy: 0.06)
    }

    /// The lines are a point wide, on a screen of two pixels to the point too. They were
    /// one pixel wide whatever the screen, and on a Retina screen hairlines half as wide as
    /// meant. Where they crowd they still veil the surface as much as before.
    func testTheLinesAreAPointWideOnAScreenOfAnyDensity() throws {
        let sharp = try shoot(ball(around: 12), width: 801, height: 601, pixelsPerPoint: 2)
        XCTAssertEqual(sharp.weight(ofTheLevelLineAt: nearestEquatorEdge(around: 12)), 1.2, accuracy: 0.12)
        let crowded = try shoot(ball(around: 512), width: 400, height: 300).kept(from: 0, to: 0.6)
        let crowdedSharp = try shoot(ball(around: 512), width: 400, height: 300, pixelsPerPoint: 2).kept(from: 0, to: 0.6)
        XCTAssertEqual(crowdedSharp, crowded, accuracy: 0.05)
    }

    /// A line that runs from behind the eye to far in front of it is drawn where it is in
    /// front, and only there: a floor reaching past the camera keeps its edges.
    func testALineFromBehindTheEyeIsDrawnWhereItIsInFront() throws {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -0.5, 100), SIMD3(1, -0.5, 100), SIMD3(1, -0.5, -100), SIMD3(-1, -0.5, -100)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 4)
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        renderer.show(try renderer.makeScene(scene))
        // Standing on the floor's middle line, looking along it.
        renderer.camera = OrbitCamera(target: SIMD3(0, 0, -1), distance: 1, yaw: 0, pitch: 0, near: 0.01, far: 1000)
        let (width, height) = (400, 300)
        renderer.look = RenderLook(view: .solid)
        let plain = try renderer.renderOffscreen(width: width, height: height)
        renderer.look = RenderLook(view: .solid, wire: true)
        let wired = try renderer.renderOffscreen(width: width, height: height)
        // A row below the horizon. The floor's diagonal runs from behind the eye to far in
        // front, along the line of sight: it crosses the row in the middle. (Its long edges,
        // at the floor's sides, are faint there: seen so far off and so turned away, their
        // lines are close together on the screen.)
        let y = height * 5 / 8
        let darker = (0..<width).filter { x in
            let a = plain.pixel(x, y), b = wired.pixel(x, y)
            return Int(a.r) + Int(a.g) + Int(a.b) - Int(b.r) - Int(b.g) - Int(b.b) > 60
        }
        XCTAssertFalse(darker.isEmpty, "the diagonal is drawn")
        XCTAssertTrue(darker.allSatisfy { abs($0 - width / 2) < 12 }, "and nothing else is: \(darker)")
    }
}
