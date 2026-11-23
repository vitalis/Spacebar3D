import Foundation
import ModelCore
import RenderMetal
import simd
import XCTest

final class ToonTests: XCTestCase {
    /// A box of two by two by two around the origin, in the given material.
    private func box(_ material: ModelScene.Material, images: [[UInt8]] = []) -> ModelScene {
        var part = ModelScene.MeshPart()
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))]
        for (n, u, v) in faces {
            let base = UInt32(part.positions.count)
            part.positions += [n - u - v, n + u - v, n + u + v, n - u + v]
            part.normals += [n, n, n, n]
            if !images.isEmpty { part.uv0 += [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)] }
            part.triangleIndices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        part.material = 0
        var scene = ModelScene()
        scene.materials = [material]
        // Each image is one pixel.
        scene.textures = images.map { .pixels(width: 1, height: 1, rgba: $0) }
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    private func draw(_ material: ModelScene.Material, view: RenderLook.View = .textured, images: [[UInt8]] = [], turned: Bool = false, seconds: Double = 0, light: Float = 1) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(box(material, images: images)))
        renderer.look = RenderLook(view: view)
        renderer.materialSeconds = seconds
        renderer.lightIntensity = light
        if view == .textured { XCTAssertEqual(renderer.showsMovingTextures, material.toon.map { $0.uvScroll != .zero || $0.uvRotation != 0 } == true && !images.isEmpty) }
        if turned { renderer.camera.rotate(yaw: 0.6, pitch: 0.4) }
        return try renderer.renderOffscreen(width: 128, height: 128)
    }

    private func cartoon(shift: Float, width: Float = 0) -> ModelScene.Material {
        var material = ModelScene.Material()
        material.baseColor = SIMD4(1, 1, 1, 1)
        var toon = ModelScene.Toon()
        toon.shadeColor = SIMD3(1, 0, 0)
        toon.toony = 1
        toon.shift = shift
        toon.outlineWidth = width
        toon.outlineColor = SIMD3(0, 0, 1)
        toon.outlineLightingMix = 0
        material.toon = toon
        return material
    }

    /// A cartoon's colours are meant to be seen as they are. Under more light they go toward
    /// white without being cut off there: a face keeps its tone, a white shirt its folds.
    func testMoreLightBrightensACartoonWithoutBurningItOut() throws {
        var material = cartoon(shift: 2)
        material.baseColor = SIMD4(0.8, 0.5, 0.3, 1)
        let usual = try draw(material).pixel(64, 64)
        let double = try draw(material, light: 2).pixel(64, 64)
        let triple = try draw(material, light: 3).pixel(64, 64)
        for (dim, bright) in [(usual, double), (double, triple)] {
            XCTAssertGreaterThan(bright.r, dim.r); XCTAssertGreaterThan(bright.g, dim.g); XCTAssertGreaterThan(bright.b, dim.b)
        }
        // Still the same colour, not white: no channel has reached the top, and their order holds.
        XCTAssertLessThan(triple.r, 252)
        XCTAssertGreaterThan(triple.r, triple.g + 8); XCTAssertGreaterThan(triple.g, triple.b + 8)
        // Less light only darkens, in proportion; the usual light changes nothing.
        let half = try draw(material, light: 0.5).pixel(64, 64)
        XCTAssertLessThan(half.r, usual.r); XCTAssertLessThan(half.b, usual.b)
        // White stays white however much light there is, and is never more than white.
        let white = try draw(cartoon(shift: 2), light: 3).pixel(64, 64)
        XCTAssertGreaterThan(white.g, 250)
    }

    func testACartoonSurfaceIsEitherItsColourOrItsShade() throws {
        // Shifted all the way, every side is lit, or every side is in the shade.
        let lit = try draw(cartoon(shift: 2)).pixel(64, 64)
        XCTAssertGreaterThan(lit.r, 240); XCTAssertGreaterThan(lit.g, 240); XCTAssertGreaterThan(lit.b, 240)
        let shaded = try draw(cartoon(shift: -2)).pixel(64, 64)
        XCTAssertGreaterThan(shaded.r, 240); XCTAssertLessThan(shaded.g, 15); XCTAssertLessThan(shaded.b, 15)
        // With no shift the two meet in a hard edge: there is nothing in between on the box.
        let image = try draw(cartoon(shift: 0))
        var white = 0, red = 0, between = 0
        for y in stride(from: 0, to: 128, by: 2) {
            for x in stride(from: 0, to: 128, by: 2) {
                let p = image.pixel(x, y)
                guard p.a == 255 else { continue }
                if p.g > 240 { white += 1 } else if p.g < 15, p.r > 240 { red += 1 } else { between += 1 }
            }
        }
        XCTAssertGreaterThan(white + red, 200)
        XCTAssertLessThan(between, (white + red) / 10, "only the pixels on the edges are mixed")
    }

    func testACartoonOutlineIsDrawnAroundTheShapeInTheTexturedViewOnly() throws {
        func blue(_ image: OffscreenImage) -> Int {
            var count = 0
            for y in 0..<128 { for x in 0..<128 { let p = image.pixel(x, y); if p.b > 200, p.r < 60, p.g < 60, p.a > 200 { count += 1 } } }
            return count
        }
        XCTAssertEqual(blue(try draw(cartoon(shift: 2))), 0)
        let thin = blue(try draw(cartoon(shift: 2, width: 0.05))), thick = blue(try draw(cartoon(shift: 2, width: 0.15)))
        XCTAssertGreaterThan(thin, 50)
        XCTAssertGreaterThan(thick, thin * 2)
        XCTAssertEqual(blue(try draw(cartoon(shift: 2, width: 0.15), view: .solid)), 0)
    }

    /// An outline that takes its colour from the surface takes the surface's own colour,
    /// also where the surface is seen through: the image's alpha makes the surface fainter,
    /// not its outline darker.
    func testTheOutlineOfASeeThroughCartoonKeepsTheSurfacesColour() throws {
        var material = cartoon(shift: 2, width: 0.15)
        material.toon?.outlineColor = SIMD3(1, 1, 1)
        material.toon?.outlineLightingMix = 1
        material.baseColorTexture = 0
        material.opacity = 0.5
        material.alphaBlend = true
        // A white image, half see-through.
        let image = try draw(material, images: [[255, 255, 255, 128]])
        // The outline is solid; the surface it goes round is not.
        var count = 0, darkest = 255
        for y in 0..<128 { for x in 0..<128 { let p = image.pixel(x, y); if p.a == 255 { count += 1; darkest = min(darkest, Int(min(p.r, p.g, p.b))) } } }
        XCTAssertGreaterThan(count, 50)
        XCTAssertGreaterThan(darkest, 240, "white, as the image is")
    }

    /// Black all over, lit or not: whatever shows is the rim or the painted highlight.
    private func dark() -> ModelScene.Material {
        var material = cartoon(shift: 0)
        material.baseColor = SIMD4(0, 0, 0, 1)
        material.toon?.shadeColor = SIMD3(0, 0, 0)
        material.toon?.rimLightingMix = 0
        return material
    }

    func testRimLightShowsAlongTheEdgesThatTurnAway() throws {
        XCTAssertLessThan(try draw(dark()).pixel(64, 64).g, 15)
        var lifted = dark()
        lifted.toon?.rimColor = SIMD3(0, 1, 0)
        lifted.toon?.rimFresnelPower = 1
        lifted.toon?.rimLift = 1
        let all = try draw(lifted).pixel(64, 64)
        XCTAssertGreaterThan(all.g, 240, "lifted all the way, it covers the surface"); XCTAssertLessThan(all.r, 15)
        // Not lifted and sharp, it keeps to the faces seen at a slant: here, the box's top.
        var edge = lifted
        edge.toon?.rimLift = 0
        edge.toon?.rimFresnelPower = 3
        let image = try draw(edge, turned: true)
        var brightest = 0, dimmest = 255
        for y in stride(from: 0, to: 128, by: 2) { for x in stride(from: 0, to: 128, by: 2) {
            let p = image.pixel(x, y)
            if p.a == 255 { brightest = max(brightest, Int(p.g)); dimmest = min(dimmest, Int(p.g)) }
        } }
        XCTAssertGreaterThan(brightest - dimmest, 40, "more on some faces than on others")
        // An image multiplies it.
        var masked = lifted
        masked.toon?.rimTexture = 0
        XCTAssertLessThan(try draw(masked, images: [[0, 0, 0, 255]]).pixel(64, 64).g, 15)
    }

    func testAPaintedHighlightIsAddedToTheSurface() throws {
        var painted = dark()
        painted.toon?.matcapTexture = 0
        let blue = try draw(painted, images: [[0, 0, 255, 255]]).pixel(64, 64)
        XCTAssertGreaterThan(blue.b, 240); XCTAssertLessThan(blue.r, 15)
        painted.toon?.matcapColor = SIMD3(0, 0, 0)
        XCTAssertLessThan(try draw(painted, images: [[0, 0, 255, 255]]).pixel(64, 64).b, 15, "multiplied by the material's factor")
        // Only where the model's own look shows.
        painted.toon?.matcapColor = SIMD3(1, 1, 1)
        let solid = try draw(painted, view: .solid, images: [[0, 0, 255, 255]]).pixel(64, 64)
        XCTAssertLessThan(abs(Int(solid.b) - Int(solid.r)), 30)
    }

    func testAnImageMovesTheEdgeBetweenColourAndShade() throws {
        var material = cartoon(shift: -2)
        XCTAssertLessThan(try draw(material, images: [[255, 0, 0, 255]]).pixel(64, 64).g, 15, "all in the shade without it")
        material.toon?.shiftTexture = 0
        material.toon?.shiftTextureScale = 4
        XCTAssertGreaterThan(try draw(material, images: [[255, 0, 0, 255]]).pixel(64, 64).g, 240, "its red, times the scale, is added")
        XCTAssertLessThan(try draw(material, images: [[0, 255, 0, 255]]).pixel(64, 64).g, 15)
    }

    func testAnImageThinsTheOutline() throws {
        func blue(_ image: OffscreenImage) -> Int {
            var count = 0
            for y in 0..<128 { for x in 0..<128 { let p = image.pixel(x, y); if p.b > 200, p.r < 60, p.g < 60, p.a > 200 { count += 1 } } }
            return count
        }
        var material = cartoon(shift: 2, width: 0.15)
        material.toon?.outlineWidthTexture = 0
        XCTAssertGreaterThan(blue(try draw(material, images: [[0, 255, 0, 255]])), 100, "its green is the share of the width")
        XCTAssertEqual(blue(try draw(material, images: [[255, 0, 255, 255]])), 0)
    }

    func testAMaterialSlidesAndTurnsItsImagesOverTime() throws {
        // The colour image is two pixels side by side, red then green, not repeating
        // smoothly: the middle of a face is on the edge between them.
        func face(_ change: (inout ModelScene.Toon) -> Void, seconds: Double, mask: [UInt8]? = nil, view: RenderLook.View = .textured) throws -> (r: UInt8, g: UInt8) {
            var material = cartoon(shift: 2)
            material.sampling.sharp = true
            change(&material.toon!)
            var scene = box(material, images: [[0, 0, 0, 255]])
            scene.textures = [.pixels(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 255, 0, 255])]
            if let mask { scene.textures.append(.pixels(width: 1, height: 1, rgba: mask)); scene.materials[0].toon?.uvMaskTexture = 1 }
            scene.materials[0].baseColorTexture = 0
            let renderer = try MetalRenderer()
            renderer.showGrid = false
            renderer.backgroundAlpha = 0
            renderer.show(try renderer.makeScene(scene))
            renderer.look = RenderLook(view: view)
            renderer.materialSeconds = seconds
            // A quarter of the way across the face: well inside the red half.
            let p = try renderer.renderOffscreen(width: 128, height: 128).pixel(52, 64)
            return (p.r, p.g)
        }
        let still = try face({ _ in }, seconds: 10)
        XCTAssertGreaterThan(still.r, 200); XCTAssertLessThan(still.g, 60)
        // Half an image a second: after one second the green half is there.
        let slid = try face({ $0.uvScroll = SIMD2(0.5, 0) }, seconds: 1)
        XCTAssertGreaterThan(slid.g, 200); XCTAssertLessThan(slid.r, 60)
        let around = try face({ $0.uvScroll = SIMD2(0.5, 0) }, seconds: 2)
        XCTAssertGreaterThan(around.r, 200, "and after two it has come round")
        // Half a turn about the middle swaps the halves as well.
        let turned = try face({ $0.uvRotation = .pi }, seconds: 1)
        XCTAssertGreaterThan(turned.g, 200); XCTAssertLessThan(turned.r, 60)
        // Where the mask's blue is nothing, nothing moves; and not in the other views.
        let held = try face({ $0.uvScroll = SIMD2(0.5, 0) }, seconds: 1, mask: [255, 255, 0, 255])
        XCTAssertGreaterThan(held.r, 200)
        let moved = try face({ $0.uvScroll = SIMD2(0.5, 0) }, seconds: 1, mask: [0, 0, 255, 255])
        XCTAssertGreaterThan(moved.g, 200)
    }
}
