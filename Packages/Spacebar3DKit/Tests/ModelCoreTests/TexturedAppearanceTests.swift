import ModelCore
import XCTest

final class TexturedAppearanceTests: XCTestCase {
    private func scene(_ parts: [(material: ModelScene.Material?, colors: Bool)], extraTexture: Bool = false) -> ModelScene {
        var s = ModelScene()
        var mesh = ModelScene.Mesh()
        for p in parts {
            var part = ModelScene.MeshPart()
            part.positions = [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
            part.triangleIndices = [0, 1, 2]
            if p.colors { part.colors = Array(repeating: SIMD4(1, 1, 1, 1), count: 3) }
            if let m = p.material { s.materials.append(m); part.material = s.materials.count - 1 }
            mesh.parts.append(part)
        }
        s.meshes = [mesh]
        s.nodes = [ModelScene.Node(mesh: 0)]
        return s
    }

    private func material(_ r: Float, _ g: Float, _ b: Float, texture: Int? = nil) -> ModelScene.Material {
        var m = ModelScene.Material()
        m.baseColor = SIMD4(r, g, b, 1)
        m.baseColorTexture = texture
        return m
    }

    func testEmptySceneHasNoTexturedView() { XCTAssertFalse(ModelScene().hasTexturedAppearance) }

    func testDefaultMaterialAndPlainGreyAreNotTextured() {
        XCTAssertFalse(scene([(nil, false)]).hasTexturedAppearance)
        XCTAssertFalse(scene([(material(0xb4 / 255, 0xb4 / 255, 0xb8 / 255), false)]).hasTexturedAppearance)
    }

    func testTextureVertexColoursAndColourMakeItTextured() {
        XCTAssertTrue(scene([(material(0.7, 0.7, 0.7, texture: 0), false)]).hasTexturedAppearance)
        XCTAssertTrue(scene([(nil, true)]).hasTexturedAppearance)
        XCTAssertTrue(scene([(material(0.9, 0.2, 0.2), false)]).hasTexturedAppearance)
    }

    func testSeveralDifferentShadesAreTexturedButTheSameShadeTwiceIsNot() {
        XCTAssertTrue(scene([(material(0.5, 0.5, 0.5), false), (material(0.6, 0.6, 0.6), false)]).hasTexturedAppearance)
        XCTAssertFalse(scene([(material(0.5, 0.5, 0.5), false), (material(0.5, 0.5, 0.5), false)]).hasTexturedAppearance)
    }

    func testMaterialEffectsKeepTheTexturedViewAvailable() {
        let effects: [(inout ModelScene.Material) -> Void] = [
            { $0.normalTexture = 0 }, { $0.metallicRoughnessTexture = 0 },
            { $0.metallicTexture = 0 }, { $0.roughnessTexture = 0 },
            { $0.emissive = SIMD3(1,0,0) }, { $0.emissiveTexture = 0 },
            { $0.opacity = 0 }, { $0.alphaBlend = true }, { $0.alphaCutoff = 0.5 },
            { $0.authoredPBR = true }, { $0.unlit = true }, { $0.toon = ModelScene.Toon() }
        ]
        for (i, effect) in effects.enumerated() {
            var m = material(0.5, 0.5, 0.5)
            effect(&m)
            XCTAssertTrue(scene([(m, false)]).hasTexturedAppearance, "effect \(i)")
        }
    }

    func testPointCloudsAndUnusedMaterialsAreIgnored() {
        var s = scene([(nil, false)])
        s.materials.append(material(1, 0, 0))   // not used by any part
        XCTAssertFalse(s.hasTexturedAppearance)
        s.meshes[0].parts[0].primitive = .points
        s.meshes[0].parts[0].colors = Array(repeating: SIMD4(1, 0, 0, 1), count: 3)
        XCTAssertFalse(s.hasTexturedAppearance)
    }
}
