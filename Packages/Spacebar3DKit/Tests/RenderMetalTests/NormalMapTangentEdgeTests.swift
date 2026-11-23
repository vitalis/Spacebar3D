import Foundation
import ModelCore
@testable import RenderMetal
import ImportGLTF
import simd
import XCTest

/// The edges of vertex tangents: placement that mirrors, the floor's reflection, models from
/// formats whose V was flipped, and a part that cannot have tangents.
final class NormalMapTangentEdgeTests: XCTestCase {
    private typealias UV = [SIMD2<Float>]
    private let standard: UV = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]

    /// A square facing the camera with a tilting normal map. `mirrored` is the same square
    /// as seen in world space, built from x-negated vertices and put back by a node that
    /// mirrors x. `oldFrame` adds a do-nothing morph shape so that the part has no vertex
    /// tangents and is lit by the per-pixel frame the renderer used before them.
    private func scene(uv: UV, texel: [UInt8] = [26, 128, 153], ySign: Float = 1, mirrored: Bool = false,
                       fileTangent: SIMD4<Float>? = nil, oldFrame: Bool = false, doubleSided: Bool = false) -> ModelScene {
        let sx: Float = mirrored ? -1 : 1
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-sx, -1, 0), SIMD3(sx, -1, 0), SIMD3(sx, 1, 0), SIMD3(-sx, 1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        part.uv0 = uv
        part.triangleIndices = mirrored ? [0, 2, 1, 0, 3, 2] : [0, 1, 2, 0, 2, 3]
        if let t = fileTangent { part.tangents = [SIMD4<Float>](repeating: t, count: 4) }
        if oldFrame {
            part.morphTargets = [ModelScene.MorphTarget(positions: [SIMD3<Float>](repeating: .zero, count: 4))]
        }
        part.material = 0
        var material = ModelScene.Material()
        material.baseColor = SIMD4(0.6, 0.6, 0.6, 1)
        material.normalTexture = 0
        material.normalYSign = ySign
        material.doubleSided = doubleSided
        var scene = ModelScene()
        scene.textures = [.pixels(width: 1, height: 1, rgba: texel + [255])]
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        if oldFrame { scene.meshes[0].morphWeights = [0] }
        scene.nodes = [ModelScene.Node(transform: simd_float4x4(diagonal: SIMD4(sx, 1, 1, 1)), mesh: 0)]
        return scene
    }

    private func draw(_ scene: ModelScene, floor: Bool = false) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.showShadow = floor
        renderer.backgroundAlpha = floor ? 1 : 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured)
        if !floor { renderer.camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100) }
        return try renderer.renderOffscreen(width: 96, height: 96)
    }

    /// The largest per-channel difference over a window, and where.
    private func worst(_ a: OffscreenImage, _ b: OffscreenImage, _ range: Range<Int> = 20..<76) -> (Int, Int, Int) {
        var worst = 0, wx = 0, wy = 0
        for y in range { for x in range {
            let p = a.pixel(x, y), q = b.pixel(x, y)
            let d = max(abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b)))
            if d > worst { worst = d; wx = x; wy = y }
        } }
        return (worst, wx, wy)
    }

    /// A normal map on a part placed with a mirroring node looked lit from the wrong side:
    /// the tilt was turned the way the placement turns it, not as the mirrored model shows.
    func testAMirroredPlacementLightsANormalMapAsTheUnmirroredPart() throws {
        let skewed: UV = [SIMD2(0, 0.8), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0.2)]
        for (name, uv, tangent): (String, UV, SIMD4<Float>?) in [("generated, plain", standard, nil), ("generated, skewed", skewed, nil), ("file tangents", standard, SIMD4(1, 0, 0, 1))] {
            for texel: [UInt8] in [[26, 128, 153], [90, 40, 190]] {
                let plain = try draw(scene(uv: uv, texel: texel, fileTangent: tangent))
                // Seen in the mirrored vertices the file's tangent along +U points along -x, and
                // its handedness is the other.
                let mirrored = try draw(scene(uv: uv, texel: texel, mirrored: true, fileTangent: tangent.map { SIMD4(-$0.x, $0.y, $0.z, -$0.w) }))
                let (d, x, y) = worst(plain, mirrored)
                XCTAssertLessThanOrEqual(d, 3, "\(name), texel \(texel): differ by \(d) at \(x),\(y); \(plain.pixel(48, 48)) vs \(mirrored.pixel(48, 48))")
            }
        }
    }

    /// Tilted a long way, the same on both: in the floor's reflection the model is upside
    /// down under the floor, and its tilt must be lit as the vertex-less frame lit it.
    func testTheFloorsReflectionOfANormalMapIsAsBefore() throws {
        for ySign: Float in [1, -1] {
            let generated = try draw(scene(uv: standard, texel: [26, 200, 153], ySign: ySign), floor: true)
            let old = try draw(scene(uv: standard, texel: [26, 200, 153], ySign: ySign, oldFrame: true), floor: true)
            let (d, x, y) = worst(generated, old, 0..<96)
            XCTAssertLessThanOrEqual(d, 3, "ySign \(ySign): whole picture differs by \(d) at \(x),\(y)")
        }
    }

    /// Formats whose V was flipped on import (normalYSign -1), and any turning or flipping of
    /// the texture coordinates, were lit by following increasing V; the vertex tangents'
    /// handedness must follow it too. Compared with the same part lit by the per-pixel frame.
    func testGeneratedTangentsLightEveryTextureOrientationAsThePerPixelFrameDid() throws {
        let orientations: [(String, UV)] = [
            ("upright", standard),
            ("u flipped", [SIMD2(1, 1), SIMD2(0, 1), SIMD2(0, 0), SIMD2(1, 0)]),
            ("v flipped", [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]),
            ("turned", [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)]),
            ("turned and flipped", [SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1), SIMD2(0, 0)])]
        for ySign: Float in [1, -1] {
            for (name, uv) in orientations {
                for texel: [UInt8] in [[26, 128, 153], [90, 40, 190]] {
                    let generated = try draw(scene(uv: uv, texel: texel, ySign: ySign))
                    let old = try draw(scene(uv: uv, texel: texel, ySign: ySign, oldFrame: true))
                    let (d, x, y) = worst(generated, old)
                    XCTAssertLessThanOrEqual(d, 3, "ySign \(ySign), \(name), texel \(texel): differ by \(d) at \(x),\(y)")
                }
            }
        }
    }

    /// Seen from behind, a two-sided normal-mapped part must be lit as the per-pixel frame lit it.
    func testTheBackOfATwoSidedNormalMappedPartIsAsBefore() throws {
        for ySign: Float in [1, -1] {
            for mirrored in [false, true] {
                var results: [OffscreenImage] = []
                for oldFrame in [false, true] {
                    let renderer = try MetalRenderer()
                    renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
                    renderer.show(try renderer.makeScene(scene(uv: standard, ySign: ySign, mirrored: mirrored, oldFrame: oldFrame, doubleSided: true)))
                    renderer.look = RenderLook(view: .textured)
                    renderer.camera = OrbitCamera(target: .zero, distance: 4, yaw: .pi, pitch: 0, near: 0.01, far: 100)
                    results.append(try renderer.renderOffscreen(width: 96, height: 96))
                }
                let (d, x, y) = worst(results[0], results[1])
                XCTAssertEqual(results[0].pixel(48, 48).a, 255)
                XCTAssertLessThanOrEqual(d, 3, "back, ySign \(ySign), mirrored \(mirrored): differ by \(d) at \(x),\(y)")
            }
        }
    }

    /// A texture transform that turns the coordinates drops the file's tangents: the part must
    /// still draw, lit as the per-pixel frame lit it.
    func testATurnedTextureTransformStillShowsTheNormalMap() throws {
        let positions: [Float] = [-1,-1,0, 1,-1,0, 1,1,0, -1,1,0]
        let normals: [Float] = [0,0,1, 0,0,1, 0,0,1, 0,0,1]
        let coordinates: [Float] = [0,1, 1,1, 1,0, 0,0]
        let tangents: [Float] = [1,0,0,1, 1,0,0,1, 1,0,0,1, 1,0,0,1]
        let indices: [UInt16] = [0,1,2, 0,2,3]
        var bytes = Data()
        for values in [positions, normals, coordinates, tangents] { bytes.append(values.withUnsafeBytes { Data($0) }) }
        bytes.append(indices.withUnsafeBytes { Data($0) })
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg=="))
        func picture(rotation: Float, tangent: Bool) throws -> OffscreenImage {
            let attributes = "\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2" + (tangent ? ",\"TANGENT\":3" : "")
            let json = """
            {"asset":{"version":"2.0"},"extensionsUsed":["KHR_texture_transform"],"nodes":[{"mesh":0}],
             "meshes":[{"primitives":[{"attributes":{\(attributes)},"indices":4,"material":0}]}],
             "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5126,"count":4,"type":"VEC3"},
               {"bufferView":2,"componentType":5126,"count":4,"type":"VEC2"},{"bufferView":3,"componentType":5126,"count":4,"type":"VEC4"},
               {"bufferView":4,"componentType":5123,"count":6,"type":"SCALAR"}],
             "bufferViews":[{"buffer":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":48},{"buffer":0,"byteOffset":96,"byteLength":32},
               {"buffer":0,"byteOffset":128,"byteLength":64},{"buffer":0,"byteOffset":192,"byteLength":12}],
             "buffers":[{"byteLength":204,"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}],
             "images":[{"uri":"data:image/png;base64,\(png.base64EncodedString())"}],"textures":[{"source":0}],
             "materials":[{"doubleSided":true,"normalTexture":{"index":0,"extensions":{"KHR_texture_transform":{"rotation":\(rotation)}}},
               "pbrMetallicRoughness":{"baseColorFactor":[0.6,0.6,0.6,1],"metallicFactor":0,"roughnessFactor":0.8}}]}
            """
            return try draw(try GLTFReader.scene(from: Data(json.utf8)))
        }
        let withTangent = try picture(rotation: 0.6, tangent: true)
        let without = try picture(rotation: 0.6, tangent: false)
        XCTAssertEqual(withTangent.pixel(48, 48).a, 255)
        let (d, x, y) = worst(withTangent, without)
        XCTAssertLessThanOrEqual(d, 2, "rotated map keeps the per-pixel frame: differ by \(d) at \(x),\(y)")
    }
}
