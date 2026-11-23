import Foundation
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// Cut-out materials (leaves, hair cards, fences) seen from far away.
final class FarCutoutTests: XCTestCase {
    /// A square facing the camera, textured with `side` x `side` texels whose alpha is
    /// given by `opaque(x, y)` (alpha 255 or 0 only), in a material with the given cut-off.
    private func scene(side: Int, cutoff: Float?, opaque: (Int, Int) -> Bool) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        part.uv0 = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.material = 0
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side { for x in 0..<side { rgba[(y * side + x) * 4 + 3] = opaque(x, y) ? 255 : 0 } }
        var material = ModelScene.Material()
        material.alphaCutoff = cutoff
        material.doubleSided = true
        material.baseColorTexture = 0
        var scene = ModelScene()
        scene.textures = [.pixels(width: side, height: side, rgba: rgba)]
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    /// The picture, with nothing behind the square so that its alpha is its coverage.
    private func draw(_ scene: ModelScene, distance: Float, size: Int = 512) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured, style: .unlit)
        renderer.camera = OrbitCamera(target: .zero, distance: distance, yaw: 0, pitch: 0, near: 0.01, far: 1000)
        return try renderer.renderOffscreen(width: size, height: size)
    }

    /// Total coverage in pixels (alpha as a share of a pixel).
    private func area(_ image: OffscreenImage) -> Double {
        stride(from: 3, to: image.bytes.count, by: 4).reduce(0.0) { $0 + Double(image.bytes[$1]) / 255 }
    }

    /// Where the square is: its width in pixels along the middle row.
    private func widthInPixels(_ image: OffscreenImage) -> Int {
        (0..<image.width).filter { image.pixel($0, image.height / 2).a > 0 }.count
    }

    /// Share of the square (as drawn with no cut-out) that the cut-out covers, near and far.
    private func shares(side: Int, opaque: (Int, Int) -> Bool, near: Float, far: Float) throws -> (near: Double, far: Double, nearWidth: Int, farWidth: Int) {
        var results: [Double] = [], widths: [Int] = []
        for distance in [near, far] {
            let full = try draw(scene(side: side, cutoff: nil, opaque: { _, _ in true }), distance: distance)
            let cut = try draw(scene(side: side, cutoff: 0.5, opaque: opaque), distance: distance)
            results.append(area(cut) / area(full)); widths.append(widthInPixels(full))
        }
        return (results[0], results[1], widths[0], widths[1])
    }

    /// Leaves and fences thinned out or vanished with distance: a texture that is half
    /// opaque (fine checks, one texel each) was drawn half there up close, but far away its
    /// smaller copies average the alpha, and the average is under (or over) the cut-off
    /// everywhere, so the whole square drew as nothing (or as solid) instead of half.
    func testACutoutKeepsItsShareOfCoverageFarAway() throws {
        let checker: (Int, Int) -> Bool = { ($0 + $1) % 2 == 0 }
        // 256 texels over about 460 pixels near (1.6 pixels to a texel, mip 0) and about 38 far (6.7 texels to a pixel, nearly three mips down).
        let r = try shares(side: 256, opaque: checker, near: 4.2, far: 50)
        XCTAssertGreaterThan(r.nearWidth, 400)
        XCTAssertGreaterThan(r.farWidth, 30, "the square is still many pixels across")
        XCTAssertEqual(r.near, 0.5, accuracy: 0.03, "near, half of the checks show")
        // 0.1: the far share is a count of a few thousand pixels, each drawn in 4 samples,
        // so sampling noise is under 0.02; a mip-averaged alpha gives 0 or 1, 0.5 off.
        XCTAssertEqual(r.far, r.near, accuracy: 0.1, "far, about as much shows as near: far share \(r.far)")
    }

    /// The same with stripes, three texels clear and one opaque (a quarter there): thinning
    /// is the failure, not only the wrong way round.
    func testASparseCutoutDoesNotVanishFarAway() throws {
        let stripes: (Int, Int) -> Bool = { x, _ in x % 4 == 0 }
        let r = try shares(side: 256, opaque: stripes, near: 4.2, far: 50)
        XCTAssertEqual(r.near, 0.25, accuracy: 0.03)
        XCTAssertEqual(r.far, r.near, accuracy: 0.1, "far share \(r.far)")
    }

    /// Guard: a cut-out whose texture is wholly opaque or wholly clear stays so at every
    /// distance (the cure for thinning must not make solid parts holey or clear parts fill).
    func testAWhollyOpaqueOrClearCutoutStaysSoAtEveryDistance() throws {
        for distance: Float in [4.2, 10, 25, 50] {
            let full = try draw(scene(side: 256, cutoff: nil, opaque: { _, _ in true }), distance: distance)
            let solid = try draw(scene(side: 256, cutoff: 0.5, opaque: { _, _ in true }), distance: distance)
            let clear = try draw(scene(side: 256, cutoff: 0.5, opaque: { _, _ in false }), distance: distance)
            XCTAssertGreaterThan(area(full), 10)
            XCTAssertEqual(area(solid), area(full), accuracy: 0.5, "opaque at \(distance)")
            XCTAssertEqual(area(clear), 0, accuracy: 0.001, "clear at \(distance)")
        }
    }
}
