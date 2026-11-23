import Foundation
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// Normal maps on a curved mesh (a UV sphere) put in place by a node that mirrors it or
/// stretches it unevenly. The map tilts every normal along the texture's U direction.
final class NormalMapCurvedTests: XCTestCase {
    private let rings = 24, segments = 48
    /// Tilt read from the map's texel: mostly along the tangent, a little out of the surface.
    private let texel: [UInt8] = [26, 128, 153]
    private var tilt: SIMD3<Float> {
        SIMD3(Float(texel[0]) / 255 * 2 - 1, Float(texel[1]) / 255 * 2 - 1, Float(texel[2]) / 255 * 2 - 1)
    }

    private enum Normals { case mapped, baked, plain }

    /// A unit sphere with U round the equator and V from the top down. `mapped` has the
    /// normal map; `baked` has the mapped normal in its vertex normals and no map; `plain`
    /// has neither. `mirrored` is the same sphere with x negated and its winding reversed
    /// (what a mirroring node makes), its tangents mirrored with it.
    private func sphere(_ kind: Normals, mirrored: Bool = false, fileTangents: Bool = false) -> ModelScene.MeshPart {
        var part = ModelScene.MeshPart()
        let sx: Float = mirrored ? -1 : 1
        for i in 0...rings {
            for j in 0...segments {
                let theta = Float.pi * Float(i) / Float(rings), phi = 2 * Float.pi * Float(j) / Float(segments)
                let n = SIMD3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                let t = SIMD3(-sin(phi), 0, cos(phi))
                let b = simd_cross(n, t)
                var normal = n
                if kind == .baked { normal = simd_normalize(tilt.x * t + tilt.y * b + tilt.z * n) }
                part.positions.append(SIMD3(n.x * sx, n.y, n.z))
                part.normals.append(SIMD3(normal.x * sx, normal.y, normal.z))
                part.uv0.append(SIMD2(Float(j) / Float(segments), Float(i) / Float(rings)))
                if fileTangents { part.tangents.append(SIMD4(t.x * sx, t.y, t.z, mirrored ? -1 : 1)) }
            }
        }
        let row = segments + 1
        for i in 0..<rings {
            for j in 0..<segments {
                let a = UInt32(i * row + j), b = a + 1, c = a + UInt32(row) + 1, d = a + UInt32(row)
                part.triangleIndices += mirrored ? [a, d, b, b, d, c] : [a, b, d, b, c, d]
            }
        }
        part.material = 0
        return part
    }

    private func scene(_ kind: Normals, scale: SIMD3<Float> = SIMD3(1, 1, 1), mirrored: Bool = false, fileTangents: Bool = false) -> ModelScene {
        var material = ModelScene.Material()
        material.baseColor = SIMD4(0.6, 0.6, 0.6, 1)
        material.normalYSign = 1
        var scene = ModelScene()
        if kind == .mapped {
            material.normalTexture = 0
            scene.textures = [.pixels(width: 1, height: 1, rgba: texel + [255])]
        }
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [sphere(kind, mirrored: mirrored, fileTangents: fileTangents)])]
        scene.nodes = [ModelScene.Node(transform: simd_float4x4(diagonal: SIMD4(scale.x, scale.y, scale.z, 1)), mesh: 0)]
        return scene
    }

    private func draw(_ scene: ModelScene) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured)
        renderer.camera = OrbitCamera(target: .zero, distance: 9, yaw: 0, pitch: 0, near: 0.01, far: 100)
        return try renderer.renderOffscreen(width: 128, height: 128)
    }

    /// The largest per-channel difference over the picture, where, and how many pixels differ by more than `limit`.
    private func worst(_ a: OffscreenImage, _ b: OffscreenImage, over limit: Int = 6) -> (worst: Int, x: Int, y: Int, many: Int) {
        var result = (worst: 0, x: 0, y: 0, many: 0)
        for y in 0..<a.height { for x in 0..<a.width {
            let p = a.pixel(x, y), q = b.pixel(x, y)
            let d = max(abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b)), abs(Int(p.a) - Int(q.a)))
            if d > result.worst { result.worst = d; result.x = x; result.y = y }
            if d > limit { result.many += 1 }
        } }
        return result
    }

    private func litPixels(_ image: OffscreenImage) -> Int { (0..<image.width * image.height).filter { image.bytes[$0 * 4 + 3] > 0 }.count }

    /// Tolerance: no pixel may differ by more than 6 of 255. Measured: the map and the baked normals differ by at most 1 (rounding of the texel and the
    /// interpolation of 48 x 24 faces); the two mirror builds are identical.
    private let allowedStrays = 0

    /// A sphere put in place by a mirroring node (negative x scale) looked lit from the
    /// wrong side once it carried a normal map: the bumps faced the other way from the
    /// mirrored surface they belong to. It must light as the same shape made in place.
    func testAMirroredCurvedMeshLightsItsNormalMapAsTheSameShapeMadeInPlace() throws {
        for fileTangents in [false, true] {
            let placed = try draw(scene(.mapped, scale: SIMD3(-1, 1, 1), fileTangents: fileTangents))
            let made = try draw(scene(.mapped, mirrored: true, fileTangents: fileTangents))
            XCTAssertGreaterThan(litPixels(placed), 1500)
            let r = worst(placed, made)
            XCTAssertLessThanOrEqual(r.many, allowedStrays, "file tangents \(fileTangents): \(r.many) pixels differ, worst \(r.worst) at \(r.x),\(r.y)")
        }
    }

    /// The same mirrored sphere lit as one whose normals already have the map's tilt in them.
    func testAMirroredCurvedMeshLightsMappedNormalsAsBakedOnes() throws {
        for fileTangents in [false, true] {
            let mapped = try draw(scene(.mapped, scale: SIMD3(-1, 1, 1), fileTangents: fileTangents))
            let baked = try draw(scene(.baked, scale: SIMD3(-1, 1, 1)))
            let r = worst(mapped, baked)
            XCTAssertLessThanOrEqual(r.many, allowedStrays, "file tangents \(fileTangents): \(r.many) pixels differ, worst \(r.worst) at \(r.x),\(r.y)")
        }
    }

    /// A sphere stretched three times as tall by its node showed its normal map tilted the
    /// wrong way over the stretched surface (a tilt carried by the stretch instead of by the
    /// normal's own rule), so bumps were lit too steeply or too flatly. It must light as the
    /// stretched sphere whose normals carry the tilt.
    func testAStretchedCurvedMeshLightsMappedNormalsAsBakedOnes() throws {
        for fileTangents in [false, true] {
            let stretch = SIMD3<Float>(1, 3, 1)
            let mapped = try draw(scene(.mapped, scale: stretch, fileTangents: fileTangents))
            let baked = try draw(scene(.baked, scale: stretch))
            let r = worst(mapped, baked)
            XCTAssertLessThanOrEqual(r.many, allowedStrays, "file tangents \(fileTangents): \(r.many) pixels differ, worst \(r.worst) at \(r.x),\(r.y)")
        }
    }

    /// Guard against passing for nothing: the map must visibly change the sphere under each
    /// placement (the tilt is large), so a match with the baked picture means something.
    func testTheNormalMapVisiblyChangesTheCurvedMeshUnderEachPlacement() throws {
        for scale in [SIMD3<Float>(1, 1, 1), SIMD3(-1, 1, 1), SIMD3(1, 3, 1)] {
            let mapped = try draw(scene(.mapped, scale: scale))
            let plain = try draw(scene(.plain, scale: scale))
            XCTAssertGreaterThan(worst(mapped, plain, over: 20).many, 500, "scale \(scale)")
        }
    }
}
