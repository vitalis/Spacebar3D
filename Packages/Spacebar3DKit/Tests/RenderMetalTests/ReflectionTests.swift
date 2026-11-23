import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// How much of its surroundings a surface mirrors as it turns to metal.
final class ReflectionTests: XCTestCase {
    /// A smooth grey ball of the given metal, in the Textured view.
    private func picture(metallic: Float) throws -> OffscreenImage {
        let around = 64, rings = 32
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
        part.material = 0
        var material = ModelScene.Material()
        material.baseColor = SIMD4(0.5, 0.5, 0.5, 1); material.metallic = metallic; material.roughness = 0.1; material.authoredPBR = true
        var scene = ModelScene()
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        let renderer = try MetalRenderer()
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured)
        return try renderer.renderOffscreen(width: 240, height: 180)
    }

    /// The greatest difference of any colour of any pixel, of 255.
    private func difference(_ a: OffscreenImage, _ b: OffscreenImage) -> Int {
        zip(a.bytes, b.bytes).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    /// The least step an 8-bit metallic image can take from no metal is not another
    /// material: a surface of mostly none, with noise in its image, is not speckled with mirrors.
    func testATraceOfMetalLooksLikeNoMetal() throws {
        XCTAssertLessThanOrEqual(difference(try picture(metallic: 0), try picture(metallic: 1.0 / 255)), 2)
    }

    /// The mirror comes in with the metal, evenly: half metal is halfway between none and all.
    func testTheMirrorComesInEvenlyWithTheMetal() throws {
        let none = try picture(metallic: 0), half = try picture(metallic: 0.5), all = try picture(metallic: 1)
        XCTAssertGreaterThan(difference(none, all), 40, "metal mirrors its surroundings")
        let halfway = difference(none, half), rest = difference(half, all)
        XCTAssertGreaterThan(halfway, 10)
        XCTAssertGreaterThan(rest, 10)
    }
}
