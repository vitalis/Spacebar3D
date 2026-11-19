import ModelCore
import RenderMetal
import simd
import XCTest

final class TextureRenderTests: XCTestCase {
    /// A quad facing the camera with an image whose top half is red and bottom half blue.
    private func scene(flipped: Bool = false, normals: Bool = true) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        if normals { part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4) }
        // v = 0 is the top row of the image.
        part.uv0 = flipped ? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)] : [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.material = 0
        var rgba: [UInt8] = []
        for y in 0..<8 { for _ in 0..<8 { rgba += y < 4 ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        var material = ModelScene.Material()
        material.baseColor = SIMD4(1, 1, 1, 1)
        material.baseColorTexture = 0
        var scene = ModelScene()
        scene.textures = [.pixels(width: 8, height: 8, rgba: rgba)]
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    func testMissingImagesDisableTexturedUntilAnImageIsUsable() throws {
        let renderer = try MetalRenderer()
        var model = scene()
        model.materials[0].authoredPBR = true
        let images = model.textures
        model.textures = []
        model.diagnostics.missingResources = ["color.jpg"]
        XCTAssertFalse(try renderer.makeScene(model).hasTexturedView)
        model.textures = images
        model.diagnostics.missingResources = []
        XCTAssertTrue(try renderer.makeScene(model).hasTexturedView)
    }

    /// Whether the upper and lower halves of the picture are mostly red or mostly blue.
    private func halves(_ image: OffscreenImage) -> (top: String, bottom: String) {
        func name(_ rows: Range<Int>) -> String {
            var red = 0, blue = 0
            for y in rows { for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                // Bytes are blue, green, red, alpha.
                if Int(image.bytes[i + 2]) > Int(image.bytes[i]) + 60 { red += 1 } else if Int(image.bytes[i]) > Int(image.bytes[i + 2]) + 60 { blue += 1 }
            } }
            return red > blue * 4 ? "red" : blue > red * 4 ? "blue" : "neither (\(red) red, \(blue) blue)"
        }
        return (name(0..<image.height / 2), name(image.height / 2..<image.height))
    }

    func testTheImageIsDrawnTheRightWayUpInTexturedOnly() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        for normals in [true, false] {
            for look in [RenderLook(view: .textured), RenderLook(view: .textured, flat: true), RenderLook(view: .textured, style: .unlit)] {
                renderer.look = look
                renderer.show(try renderer.makeScene(scene(normals: normals)))
                var result = halves(try renderer.renderOffscreen(width: 160, height: 120))
                XCTAssertEqual(result.top, "red", "normals \(normals) \(look.style) flat \(look.flat)")
                XCTAssertEqual(result.bottom, "blue")
                renderer.show(try renderer.makeScene(scene(flipped: true, normals: normals)))
                result = halves(try renderer.renderOffscreen(width: 160, height: 120))
                XCTAssertEqual(result.top, "blue")
                XCTAssertEqual(result.bottom, "red")
            }
        }
        renderer.look = RenderLook(view: .solid)
        renderer.show(try renderer.makeScene(scene()))
        let solid = halves(try renderer.renderOffscreen(width: 160, height: 120))
        XCTAssertTrue(solid.top.hasPrefix("neither") && solid.bottom.hasPrefix("neither"), "\(solid)")
    }

    /// A normal map changes the lighting; a metallic-roughness map changes it too; a value
    /// set in the view settings replaces the map.
    func testNormalAndMetallicRoughnessMapsTakeEffect() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.look = RenderLook(view: .textured)
        func shot(_ change: (inout ModelScene) -> Void) throws -> [UInt8] {
            var s = scene()
            change(&s)
            renderer.show(try renderer.makeScene(s))
            return try renderer.renderOffscreen(width: 160, height: 120).bytes
        }
        let plain = try shot { _ in }
        // Tilted hard to one side.
        let tilted = try shot { s in
            s.textures.append(.pixels(width: 1, height: 1, rgba: [255, 128, 128, 255]))
            s.materials[0].normalTexture = 1
        }
        XCTAssertNotEqual(plain, tilted)
        // Straight up changes nothing visible.
        let straight = try shot { s in
            s.textures.append(.pixels(width: 1, height: 1, rgba: [128, 128, 255, 255]))
            s.materials[0].normalTexture = 1
        }
        let differing = zip(plain, straight).filter { abs(Int($0) - Int($1)) > 3 }.count
        XCTAssertLessThan(differing, plain.count / 200)

        let metal = try shot { s in
            s.textures.append(.pixels(width: 1, height: 1, rgba: [255, 60, 255, 255]))
            s.materials[0].metallicRoughnessTexture = 1
            s.materials[0].metallic = 1; s.materials[0].roughness = 1
        }
        XCTAssertNotEqual(plain, metal)
        renderer.look = RenderLook(view: .textured, metallic: 0, roughness: 0.5)
        let overridden = try shot { s in
            s.textures.append(.pixels(width: 1, height: 1, rgba: [255, 60, 255, 255]))
            s.materials[0].metallicRoughnessTexture = 1
            s.materials[0].metallic = 1; s.materials[0].roughness = 1
        }
        let reference = try shot { _ in }
        XCTAssertEqual(overridden, reference)
    }
}
