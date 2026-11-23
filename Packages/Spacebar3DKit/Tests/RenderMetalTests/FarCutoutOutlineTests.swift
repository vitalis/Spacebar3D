import Foundation
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// The ink outline of a cut-out cartoon material (leaves, hair cards) seen from far away.
final class FarCutoutOutlineTests: XCTestCase {
    /// A square facing the camera, seen from behind its winding so that its outline (drawn
    /// from the far faces) shows, with normals pointing out along the diagonals so that the
    /// outline is a ring round the square, clear of the surface. The image is `side` x `side`
    /// texels whose alpha is 255 or 0 by `opaque(x, y)`; the material is a cut-out cartoon
    /// with a blue outline that takes no colour from the surface.
    private func scene(side: Int, cutoff: Float?, opaque: (Int, Int) -> Bool) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        let d: Float = 1 / Float(2).squareRoot()
        part.normals = [SIMD3(-d, -d, 0), SIMD3(d, -d, 0), SIMD3(d, d, 0), SIMD3(-d, d, 0)]
        part.uv0 = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 2, 1, 0, 3, 2]
        part.material = 0
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side { for x in 0..<side { rgba[(y * side + x) * 4 + 3] = opaque(x, y) ? 255 : 0 } }
        var material = ModelScene.Material()
        material.baseColor = SIMD4(1, 1, 1, 1)
        material.alphaCutoff = cutoff
        material.doubleSided = true
        material.baseColorTexture = 0
        var toon = ModelScene.Toon()
        toon.shadeColor = SIMD3(1, 1, 1)
        toon.outlineWidth = 0.3
        toon.outlineColor = SIMD3(0, 0, 1)
        toon.outlineLightingMix = 0
        material.toon = toon
        var scene = ModelScene()
        scene.textures = [.pixels(width: side, height: side, rgba: rgba)]
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    private func draw(_ scene: ModelScene, distance: Float) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured)
        renderer.camera = OrbitCamera(target: .zero, distance: distance, yaw: 0, pitch: 0, near: 0.01, far: 1000)
        return try renderer.renderOffscreen(width: 512, height: 512)
    }

    /// The pixels that are the outline's ring in a picture of the solid cut-out: blue, which
    /// the white surface and the empty background are not.
    private func ring(_ solid: OffscreenImage) -> [Bool] {
        (0..<solid.width * solid.height).map { let p = solid.pixel($0 % solid.width, $0 / solid.width); return Int(p.b) - Int(p.r) > 128 }
    }

    /// How much ink there is on the ring, in pixels: blue where the pixel is blue, in proportion.
    /// (Inside the ring the surface and, behind its holes, the outline's hull overlap in
    /// a way that depends on how the two patterns lie; only the ring is the outline alone.)
    private func ink(_ image: OffscreenImage, on mask: [Bool]) -> Double {
        var total = 0.0
        for i in 0..<image.width * image.height where mask[i] {
            let p = image.pixel(i % image.width, i / image.width)
            total += Double(max(0, Int(p.b) - Int(p.r))) / 255
        }
        return total
    }

    /// The outline's share of what a solid surface's outline would be, near and far.
    private func shares(side: Int, opaque: (Int, Int) -> Bool, near: Float, far: Float) throws -> (near: Double, far: Double) {
        var results: [Double] = []
        for distance in [near, far] {
            let solid = try draw(scene(side: side, cutoff: 0.5, opaque: { _, _ in true }), distance: distance)
            let mask = ring(solid)
            let all = ink(solid, on: mask)
            XCTAssertGreaterThan(all, 100, "a solid cut-out has its outline round it at \(distance)")
            results.append(ink(try draw(scene(side: side, cutoff: 0.5, opaque: opaque), distance: distance), on: mask) / all)
        }
        return (results[0], results[1])
    }

    /// A fine cut-out far away fades to the share of it that is there (see FarCutoutTests),
    /// but its ink outline still said yes or no from the averaged alpha: a checker of half
    /// opaque texels went solid, stripes a quarter opaque vanished. The outline of a thicket
    /// of leaves seen from afar was a solid ring or none, as the picture's mix fell.
    func testTheOutlineOfAFineCutoutFollowsItsShareFarAway() throws {
        let checker: (Int, Int) -> Bool = { ($0 + $1) % 2 == 0 }
        let r = try shares(side: 256, opaque: checker, near: 4.2, far: 50)
        XCTAssertEqual(r.near, 0.5, accuracy: 0.08, "near, half of the checks have their outline")
        XCTAssertEqual(r.far, 0.5, accuracy: 0.12, "far, still about half: far share \(r.far) (a solid ring is 1)")
    }

    func testTheOutlineOfASparseCutoutDoesNotVanishFarAway() throws {
        let stripes: (Int, Int) -> Bool = { x, _ in x % 4 == 0 }
        let r = try shares(side: 256, opaque: stripes, near: 4.2, far: 50)
        XCTAssertEqual(r.near, 0.25, accuracy: 0.08)
        XCTAssertEqual(r.far, 0.25, accuracy: 0.1, "far share \(r.far) (none is 0)")
    }

    /// Guard: a wholly opaque cut-out keeps its whole outline and a wholly clear one has
    /// none, at every distance.
    func testAWhollyOpaqueOrClearCutoutKeepsOrLosesItsWholeOutline() throws {
        for distance: Float in [4.2, 10, 25, 50] {
            let solidImage = try draw(scene(side: 256, cutoff: 0.5, opaque: { _, _ in true }), distance: distance)
            let mask = ring(solidImage)
            let solid = ink(solidImage, on: mask)
            let uncut = ink(try draw(scene(side: 256, cutoff: nil, opaque: { _, _ in true }), distance: distance), on: mask)
            let clear = ink(try draw(scene(side: 256, cutoff: 0.5, opaque: { _, _ in false }), distance: distance), on: mask)
            XCTAssertGreaterThan(uncut, 100)
            XCTAssertEqual(solid, uncut, accuracy: uncut * 0.02, "opaque at \(distance)")
            XCTAssertEqual(clear, 0, accuracy: 0.5, "clear at \(distance)")
        }
    }
}
