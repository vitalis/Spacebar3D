import Foundation
import CoreGraphics
import ImageIO
import ModelCore
@testable import RenderMetal
import ImportGLTF
import ImportOBJ
import simd
import XCTest

final class GlowAndCutoutTests: XCTestCase {
    /// A square facing the camera, with texture coordinates, in the given material.
    private func square(_ material: ModelScene.Material, image: [UInt8]? = nil) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        part.uv0 = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.material = 0
        var scene = ModelScene()
        var material = material
        if let image {
            // Two pixels side by side.
            scene.textures = [.pixels(width: 2, height: 1, rgba: image)]
            material.baseColorTexture = 0
        }
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    private func draw(_ scene: ModelScene) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured)
        return try renderer.renderOffscreen(width: 96, height: 96)
    }

    func testOBJDiffuseFactorMultipliesItsTexture() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        renderer.look = RenderLook(view: .textured, style: .unlit)
        let obj = "mtllib a.mtl\nv -1 -1 0\nv 1 -1 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0.5 1\nusemtl a\nf 1/1 2/2 3/3\n"
        for (factor, texture, expected) in [
            ("Kd 1 0 0\n", [UInt8](arrayLiteral: 255,255,255,255), [255,0,0]),
            ("Kd 1 1 1\n", [UInt8](arrayLiteral: 255,0,0,255), [255,0,0]),
            ("", [UInt8](arrayLiteral: 255,255,255,255), [255,255,255])
        ] {
            let files = SidecarFiles(["a.mtl": Data(("newmtl a\n" + factor + "map_Kd a.png\n").utf8), "a.png": Data(try png(texture, width: 1))])
            let scene = try OBJReader.scene(from: Data(obj.utf8), sidecars: files)
            renderer.show(try renderer.makeScene(scene))
            let pixel = try renderer.renderOffscreen(width: 96, height: 96).pixel(48,48)
            XCTAssertEqual([Int(pixel.r),Int(pixel.g),Int(pixel.b)], expected)
        }
    }

    func testTransparentCastersLeaveNoFloorShadow() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = true; renderer.backgroundAlpha = 0
        var anchor = ModelScene.MeshPart()
        anchor.primitive = .points
        anchor.positions = [SIMD3(-2,-1,-2), SIMD3(2,2,2)]
        func shot(_ material: ModelScene.Material?, image: [UInt8]? = nil, vertexAlpha: Float = 1, halfGeometry: Bool = false) throws -> [UInt8] {
            var scene = square(material ?? ModelScene.Material(), image: image)
            scene.meshes[0].parts[0].positions = [SIMD3(-1,0,-1), SIMD3(1,0,-1), SIMD3(1,0,1), SIMD3(-1,0,1)]
            if halfGeometry {
                scene.meshes[0].parts[0].positions[1].x = 0
                scene.meshes[0].parts[0].positions[2].x = 0
            }
            scene.meshes[0].parts[0].normals = [SIMD3<Float>](repeating: SIMD3(0,1,0), count: 4)
            scene.meshes[0].parts[0].colors = [SIMD4<Float>](repeating: SIMD4(1,1,1,vertexAlpha), count: 4)
            scene.meshes[0].parts = material == nil ? [anchor] : scene.meshes[0].parts + [anchor]
            renderer.show(try renderer.makeScene(scene))
            return try renderer.renderOffscreen(width: 160, height: 160).bytes
        }
        let empty = try shot(nil)
        for cutoff in [false, true] {
            for source in ["texture", "vertex", "material"] {
                var material = ModelScene.Material()
                material.doubleSided = true
                if cutoff { material.alphaCutoff = source == "material" ? 2 : 0.5 }
                else { material.alphaBlend = true; material.opacity = source == "material" ? 0 : 1 }
                let image: [UInt8]? = source == "texture" ? [255,255,255,0, 255,255,255,0] : nil
                XCTAssertTrue(try shot(material, image: image, vertexAlpha: source == "vertex" ? 0 : 1) == empty, "\(cutoff), \(source)")
            }
        }
        // A cut-out must cast the silhouette of the surviving half, including its UV sampling.
        var cutout = ModelScene.Material(); cutout.alphaCutoff = 0.5; cutout.doubleSided = true
        cutout.sampling.sharp = true; cutout.sampling.wrapS = .clamp
        let clipped = try shot(cutout, image: [255,255,255,255, 255,255,255,0])
        let halfGeometry = try shot(cutout, halfGeometry: true)
        XCTAssertLessThan(zip(clipped, halfGeometry).filter { abs(Int($0) - Int($1)) > 2 }.count, clipped.count / 200)

        // Measure only pixels outside the visible model, so the shadow must itself fade.
        var blend = ModelScene.Material(); blend.alphaBlend = true; blend.doubleSided = true
        renderer.showShadow = false
        let noFloor = try shot(nil), noShadow = try shot(blend)
        let floorBytes = (0..<noFloor.count / 4).filter { pixel in
            (0..<4).allSatisfy { noFloor[pixel * 4 + $0] == noShadow[pixel * 4 + $0] }
        }.flatMap { pixel in (0..<4).map { pixel * 4 + $0 } }
        renderer.showShadow = true
        let opaque = try shot(blend)
        blend.opacity = 128.0 / 255
        let half = try shot(blend)
        func difference(_ image: [UInt8]) -> Int { floorBytes.reduce(0) { $0 + abs(Int(image[$1]) - Int(empty[$1])) } }
        XCTAssertGreaterThan(difference(half), 0)
        XCTAssertLessThan(difference(half), difference(opaque))
        blend.opacity = 1
        let vertexHalf = try shot(blend, vertexAlpha: 128.0 / 255)
        let textureHalf = try shot(blend, image: [255,255,255,128, 255,255,255,128])
        for equivalent in [vertexHalf, textureHalf] {
            XCTAssertTrue(floorBytes.allSatisfy { abs(Int(equivalent[$0]) - Int(half[$0])) <= 1 })
        }
        // Solid and normal views ignore the model's alpha, including in the shadow pass.
        for view in [RenderLook.View.solid, .normal] {
            renderer.look = RenderLook(view: view)
            let solid = try shot(blend)
            XCTAssertTrue(try shot(blend, image: [255,255,255,0, 255,255,255,0], vertexAlpha: 0) == solid)
        }
    }

    func testImportedNormalScaleMatchesBakedNormals() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        let normalPNG = Data(try png([179,128,230,255], width: 1)).base64EncodedString()
        let vertices: [Float] = [0,0,0, 1,0,0, 0,1,0]
        let buffer = vertices.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        for strength: Float? in [nil, 0, 0.25, 1, 2] {
            let scale = strength ?? 1
            let property = strength.map { ",\"scale\":\($0)" } ?? ""
            let imported = try GLTFReader.scene(from: Data("""
            {"asset":{"version":"2.0"},"images":[{"uri":"data:image/png;base64,\(normalPNG)"}],
            "buffers":[{"uri":"data:application/octet-stream;base64,\(buffer)","byteLength":36}],
            "bufferViews":[{"buffer":0,"byteLength":36}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
            "nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
            "textures":[{"source":0}],"materials":[{"normalTexture":{"index":0\(property)},
            "pbrMetallicRoughness":{"baseColorFactor":[1,1,1,1],"metallicFactor":0,"roughnessFactor":0.5}}]}
            """.utf8))
            XCTAssertEqual(imported.materials[0].normalScale, scale)
            var actual = square(imported.materials[0])
            actual.textures = imported.textures
            renderer.show(try renderer.makeScene(actual))
            let scaled = try renderer.renderOffscreen(width: 96, height: 96).pixel(48,48)
            if scale == 0 {
                actual.materials[0].normalTexture = nil
                renderer.show(try renderer.makeScene(actual))
                let plain = try renderer.renderOffscreen(width: 96, height: 96).pixel(48,48)
                XCTAssertEqual(Int(scaled.r), Int(plain.r), accuracy: 1)
                XCTAssertEqual(Int(scaled.g), Int(plain.g), accuracy: 1)
                XCTAssertEqual(Int(scaled.b), Int(plain.b), accuracy: 1)
            }
            // Encode the scaled and normalized tangent-space normal as a reference map.
            let n = simd_normalize(SIMD3<Float>((179.0 / 255 * 2 - 1) * scale, (128.0 / 255 * 2 - 1) * scale, 230.0 / 255 * 2 - 1))
            let rgb = [n.x,n.y,n.z].map { UInt8(((Double($0) + 1) * 127.5).rounded()) }
            var referenceMaterial = ModelScene.Material()
            referenceMaterial.baseColor = SIMD4(repeating: 1); referenceMaterial.normalTexture = 0
            var reference = square(referenceMaterial)
            reference.textures = [.pixels(width: 1, height: 1, rgba: rgb + [255])]
            renderer.show(try renderer.makeScene(reference))
            let baked = try renderer.renderOffscreen(width: 96, height: 96).pixel(48,48)
            XCTAssertEqual(Int(scaled.r), Int(baked.r), accuracy: 2, "scale \(scale)")
            XCTAssertEqual(Int(scaled.g), Int(baked.g), accuracy: 2, "scale \(scale)")
            XCTAssertEqual(Int(scaled.b), Int(baked.b), accuracy: 2, "scale \(scale)")
        }
    }

    func testResizedRawTexturesKeepCutoutsAndTranslucency() throws {
        for cutoff in [true, false] {
            var material = ModelScene.Material()
            material.unlit = true
            if cutoff { material.alphaCutoff = 0.5 } else { material.opacity = 0.9 }
            for alpha: UInt8 in [0, 128, 255] {
                let scene = square(material, image: [255, 0, 0, alpha, 255, 0, 0, alpha])
                var pixels: [(r: UInt8, a: UInt8)] = []
                for limit in [1, 2] {
                    let renderer = try MetalRenderer()
                    renderer.maxTextureSide = limit
                    renderer.showGrid = false
                    renderer.showShadow = false
                    renderer.backgroundAlpha = 0
                    renderer.show(try renderer.makeScene(scene))
                    let pixel = try renderer.renderOffscreen(width: 96, height: 96).pixel(48, 48)
                    pixels.append((pixel.r, pixel.a))
                }
                XCTAssertEqual(Int(pixels[0].r), Int(pixels[1].r), accuracy: 2)
                XCTAssertEqual(Int(pixels[0].a), Int(pixels[1].a), accuracy: 2)
                if alpha == 0 { XCTAssertEqual(pixels[0].a, 0) }
                else { XCTAssertGreaterThan(pixels[0].a, 100) }
            }
        }
    }

    func testTranslucentTexturesMatchEquivalentMaterialColors() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        for cutoff in [false, true] {
            for alpha: UInt8 in [64, 128, 192] {
                var plain = ModelScene.Material()
                plain.unlit = true
                plain.baseColor = SIMD4(1, 0.5, 0, 1)
                plain.opacity = cutoff ? 1 : 0.999 * Float(alpha) / 255
                renderer.show(try renderer.makeScene(square(plain)))
                let expected = try renderer.renderOffscreen(width: 96, height: 96).pixel(48, 48)
                var textured = ModelScene.Material()
                textured.unlit = true
                textured.baseColor = SIMD4(repeating: 1)
                textured.opacity = cutoff ? 1 : 0.999
                if cutoff { textured.alphaCutoff = 0.2 }
                let bytes: [UInt8] = [255,128,0,alpha,255,128,0,alpha]
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let png = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                for encoded in [false, true] {
                    var scene = square(textured, image: bytes)
                    if encoded { scene.textures = [.embedded(bytes: Array(png as Data), mime: "image/png")] }
                    for limit in [1, 2] {
                        renderer.maxTextureSide = limit
                        renderer.show(try renderer.makeScene(scene))
                        let pixel = try renderer.renderOffscreen(width: 96, height: 96).pixel(48, 48)
                        XCTAssertEqual(Int(pixel.r), Int(expected.r), accuracy: 2)
                        XCTAssertEqual(Int(pixel.g), Int(expected.g), accuracy: 3)
                        XCTAssertEqual(Int(pixel.a), Int(expected.a), accuracy: 1)
                    }
                }
            }
        }
    }

    private func png(_ rgba: [UInt8], width: Int = 2) throws -> [UInt8] {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return Array(data as Data)
    }

    func testOpaqueImagesIgnoreAlphaAtEverySize() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        for alpha: UInt8 in [0, 128, 255] {
            let bytes: [UInt8] = [255, 0, 0, alpha, 255, 0, 0, alpha]
            for cutoff: Float? in [nil, 0] {
                var material = ModelScene.Material()
                material.unlit = true; material.baseColor = SIMD4(repeating: 1); material.alphaCutoff = cutoff
                for encoded in [false, true] {
                    var scene = square(material, image: bytes)
                    if encoded { scene.textures = [.embedded(bytes: try png(bytes), mime: "image/png")] }
                    for limit in [1, 2] {
                        renderer.maxTextureSide = limit
                        renderer.show(try renderer.makeScene(scene))
                        let pixel = try renderer.renderOffscreen(width: 96, height: 96).pixel(48, 48)
                        XCTAssertEqual(pixel.r, 255)
                        XCTAssertEqual(pixel.g, 0)
                        XCTAssertEqual(pixel.a, 255)
                    }
                }
            }
        }
    }

    func testOneImageCanBeOpaqueAndBlended() throws {
        var opaque = ModelScene.Material()
        opaque.baseColor = SIMD4(repeating: 1); opaque.baseColorTexture = 0
        var blended = opaque; blended.opacity = 0.999
        for materials in [[opaque, blended], [blended, opaque]] {
            var scene = square(opaque, image: [255, 0, 0, 128, 255, 0, 0, 128])
            scene.materials = materials
            var second = scene.meshes[0].parts[0]; second.material = 1
            scene.meshes[0].parts.append(second)
            let gpu = try MetalRenderer().makeScene(scene)
            for i in 0..<2 {
                let texture = try XCTUnwrap(gpu.parts[i].texture)
                var bytes = [UInt8](repeating: 0, count: 8)
                texture.getBytes(&bytes, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
                XCTAssertEqual(Int(bytes[0]), materials[i].opacity == 1 ? 255 : 188, accuracy: 1)
                XCTAssertEqual(bytes[3], materials[i].opacity == 1 ? 255 : 128)
            }
        }
    }

    func testImportedMaskFactorsDiscardAndKeepAtBoundary() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        let positions: [Float] = [-1,-1,0, 1,-1,0, 1,1,0, -1,1,0]
        let coordinates: [Float] = [0,1, 1,1, 1,0, 0,0]
        let indices: [UInt16] = [0,1,2, 0,2,3]
        let bytes = positions.withUnsafeBytes { Data($0) } + coordinates.withUnsafeBytes { Data($0) } + indices.withUnsafeBytes { Data($0) }
        let imageURI = "data:image/png;base64," + Data(try png([255,255,255,255], width: 1)).base64EncodedString()
        for textured in [false, true] {
            for (alpha, cutoff, visible): (Float, Float, Bool) in [(0.2,0.5,false), (0,0.5,false), (0,0,true), (0.5,0.5,true), (1,2,false), (1e-8,1e-9,true)] {
                let texture = textured ? ", \"baseColorTexture\":{\"index\":0}" : ""
                let json = """
                {"asset":{"version":"2.0"},"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"indices":2,"material":0}]}],
                 "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},{"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}],
                 "bufferViews":[{"buffer":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},{"buffer":0,"byteOffset":80,"byteLength":12}],
                 "buffers":[{"byteLength":92,"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}],
                 "images":[{"uri":"\(imageURI)"}],"textures":[{"source":0}],"materials":[{"alphaMode":"MASK","alphaCutoff":\(cutoff),"doubleSided":true,
                 "extensions":{"KHR_materials_unlit":{}},"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,\(alpha)]\(texture)}}]}
                """
                let scene = try GLTFReader.scene(from: Data(json.utf8))
                renderer.show(try renderer.makeScene(scene))
                let pixel = try renderer.renderOffscreen(width: 96, height: 96).pixel(48, 48)
                XCTAssertEqual(pixel.a, visible ? 255 : 0, "alpha \(alpha), cutoff \(cutoff), textured \(textured)")
                if visible { XCTAssertEqual(pixel.r, 255) }
            }
        }
    }


    func testImportedVertexAlphaCombinesWithMaterialAndTextureAlpha() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        func model(mode: String, alphas: [Float], factor: Float, imageAlpha: UInt8?) throws -> ModelScene {
            let positions: [Float] = [-1,-1,0, 1,-1,0, 1,1,0, -1,1,0]
            let uv: [Float] = [0,1, 1,1, 1,0, 0,0]
            let colors: [Float] = alphas.flatMap { [1,0,0,$0] }
            let indices: [UInt16] = [0,1,2, 0,2,3]
            var data = positions.withUnsafeBytes { Data($0) }
            data += uv.withUnsafeBytes { Data($0) }
            data += colors.withUnsafeBytes { Data($0) }
            data += indices.withUnsafeBytes { Data($0) }
            var pbr: [String: Any] = ["baseColorFactor": [1,1,1,factor]]
            var json: [String: Any] = [
                "asset": ["version":"2.0"], "nodes":[["mesh":0]],
                "meshes":[["primitives":[["attributes":["POSITION":0,"TEXCOORD_0":1,"COLOR_0":2],"indices":3,"material":0]]]],
                "accessors":[["bufferView":0,"componentType":5126,"count":4,"type":"VEC3"], ["bufferView":1,"componentType":5126,"count":4,"type":"VEC2"], ["bufferView":2,"componentType":5126,"count":4,"type":"VEC4"], ["bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"]],
                "bufferViews":[["buffer":0,"byteLength":48], ["buffer":0,"byteOffset":48,"byteLength":32], ["buffer":0,"byteOffset":80,"byteLength":64], ["buffer":0,"byteOffset":144,"byteLength":12]],
                "buffers":[["byteLength":156,"uri":"data:application/octet-stream;base64,"+data.base64EncodedString()]]]
            if let alpha = imageAlpha {
                pbr["baseColorTexture"] = ["index":0]
                json["textures"] = [["source":0]]
                json["images"] = [["uri":"data:image/png;base64,"+Data(try png([255,255,255,alpha], width:1)).base64EncodedString()]]
            }
            json["materials"] = [["alphaMode":mode,"alphaCutoff":0.5,"doubleSided":true,"extensions":["KHR_materials_unlit":[:]],"pbrMetallicRoughness":pbr]]
            return try GLTFReader.scene(from: JSONSerialization.data(withJSONObject: json))
        }
        for mode in ["OPAQUE", "MASK", "BLEND"] {
            for vertexAlpha: Float in [0, 0.25, 1] {
                for imageAlpha: UInt8? in [nil, 128, 255] {
                    for factor: Float in [0.5, 1] {
                        let scene = try model(mode: mode, alphas: Array(repeating: vertexAlpha, count: 4), factor: factor, imageAlpha: imageAlpha)
                        let effective = factor * (vertexAlpha * 255).rounded() / 255 * Float(imageAlpha ?? 255) / 255
                        let expected = mode == "OPAQUE" ? 255 : mode == "MASK" ? (effective >= 0.5 ? 255 : 0) : Int((effective * 255).rounded())
                        for flat in [false, true] {
                            renderer.look.flat = flat; renderer.show(try renderer.makeScene(scene))
                            let pixel = try renderer.renderOffscreen(width: 96, height: 96).pixel(48,48)
                            XCTAssertEqual(Int(pixel.a), expected, accuracy: 1, "\(mode), vertex \(vertexAlpha), image \(String(describing: imageAlpha)), factor \(factor), flat \(flat)")
                        }
                    }
                }
            }
        }
        // Vertex alpha must be interpolated across a face, not collapsed to a part-wide value.
        for mode in ["MASK", "BLEND"] {
            renderer.show(try renderer.makeScene(model(mode: mode, alphas: [0,1,1,0], factor: 1, imageAlpha: nil)))
            renderer.camera.yaw = 0; renderer.camera.pitch = 0
            let image = try renderer.renderOffscreen(width: 96, height: 96)
            XCTAssertLessThan(image.pixel(36,48).a, image.pixel(60,48).a)
            if mode == "MASK" { XCTAssertEqual(image.pixel(36,48).a, 0); XCTAssertEqual(image.pixel(60,48).a, 255) }
            else { XCTAssertGreaterThan(image.pixel(36,48).a, 0); XCTAssertLessThan(image.pixel(60,48).a, 255) }
        }
    }

    func testASurfaceGivesOffItsOwnLight() throws {
        var black = ModelScene.Material()
        black.baseColor = SIMD4(0, 0, 0, 1)
        black.roughness = 1
        let dark = try draw(square(black)).pixel(48, 48)
        var lamp = black
        lamp.emissive = SIMD3(0, 1, 0)
        let lit = try draw(square(lamp)).pixel(48, 48)
        XCTAssertLessThan(dark.g, 40)
        XCTAssertGreaterThan(lit.g, 240, "black, but glowing green")
        XCTAssertLessThan(lit.r, 40)
    }

    func testAnUnlitMaterialShowsItsColourAsItIs() throws {
        var material = ModelScene.Material()
        material.baseColor = SIMD4(0.5, 0.25, 1, 1)
        material.unlit = true
        let pixel = try draw(square(material)).pixel(48, 48)
        XCTAssertEqual(Int(pixel.r), 128, accuracy: 3)
        XCTAssertEqual(Int(pixel.g), 64, accuracy: 3)
        XCTAssertEqual(Int(pixel.b), 255, accuracy: 3)
    }

    func testVertexColoursTintTheImageAndAOneSidedSurfaceHasNoBack() throws {
        let material = ModelScene.Material()
        var scene = square(material, image: [255, 255, 255, 255, 255, 255, 255, 255])
        let plain = try draw(scene).pixel(48, 48)
        XCTAssertGreaterThan(plain.b, 120)
        scene.meshes[0].parts[0].colors = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: 4)
        let tinted = try draw(scene).pixel(48, 48)
        XCTAssertGreaterThan(tinted.r, 100)
        XCTAssertLessThan(tinted.b, 60, "white image, red vertices: red")

        // Turned away from the camera: drawn all the same, unless the file means one side only.
        scene.meshes[0].parts[0].triangleIndices = [0, 2, 1, 0, 3, 2]
        XCTAssertEqual(try draw(scene).pixel(48, 48).a, 255)
        scene.materials[0].oneSided = true
        XCTAssertEqual(try draw(scene).pixel(48, 48).a, 0)
    }

    func testAnotherShapeOfAPartShowsByItsWeightAndThroughAClip() throws {
        // The square, bound whole to one joint, with a second shape that moves it far to the right.
        var scene = square(ModelScene.Material())
        scene.skeletons = [ModelScene.Skeleton(joints: [.init()])]
        scene.meshes[0].parts[0].skin = ModelScene.Skin(skeleton: 0, joints: [SIMD4<UInt16>](repeating: .zero, count: 4), weights: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 4))
        scene.meshes[0].parts[0].morphTargets = [ModelScene.MorphTarget(positions: [SIMD3<Float>](repeating: SIMD3(40, 0, 0), count: 4))]
        scene.meshes[0].morphWeights = [0]
        var clip = ModelScene.AnimationClip(skeleton: 0, start: 0, end: 1)
        clip.morphs = [ModelScene.MorphChannel(mesh: 0, targetCount: 1, times: [0, 1], values: [0, 1])]
        scene.clips = [clip]
        XCTAssertEqual(clip.morphs[0].weights(at: 0.25), [0.25])
        XCTAssertEqual(clip.morphs[0].weights(at: 7), [1])
        XCTAssertNil(ModelScene.MorphChannel(mesh: 0, targetCount: 2, times: [0], values: [1]).weights(at: 0), "fewer values than it says")

        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .solid)
        // The view is fitted to everything the clip reaches: the square at rest and far to the right.
        let framing = try XCTUnwrap(renderer.scene).framing
        XCTAssertEqual(framing.center.x, 20, accuracy: 0.01)
        XCTAssertEqual(framing.size.x, 42, accuracy: 0.01)
        /// How much of the picture's left and right halves the square covers.
        func halves() throws -> (left: Int, right: Int) {
            let image = try renderer.renderOffscreen(width: 96, height: 96)
            var left = 0, right = 0
            for y in 0..<96 { for x in 0..<96 where image.pixel(x, y).a == 255 { if x < 48 { left += 1 } else { right += 1 } } }
            return (left, right)
        }
        var seen = try halves()
        XCTAssertGreaterThan(seen.left, 0, "at rest it is on the left"); XCTAssertEqual(seen.right, 0)
        renderer.scene?.pose(clip: 0, time: 1)
        seen = try halves()
        XCTAssertGreaterThan(seen.right, 0, "at the clip's end it has moved to the right, still in view"); XCTAssertEqual(seen.left, 0)
        renderer.scene?.pose(clip: nil)
        seen = try halves()
        XCTAssertGreaterThan(seen.left, 0, "and comes back with no clip"); XCTAssertEqual(seen.right, 0)

        // The file can start with a shape showing: it is drawn so, and the clip's start is without it.
        scene.meshes[0].morphWeights = [1]
        renderer.show(try renderer.makeScene(scene))
        seen = try halves()
        XCTAssertGreaterThan(seen.right, 0); XCTAssertEqual(seen.left, 0)
        renderer.scene?.pose(clip: 0, time: 0)
        seen = try halves()
        XCTAssertGreaterThan(seen.left, 0); XCTAssertEqual(seen.right, 0)

        // A joint that carries the square away is followed in the same way, and a model
        // with no clip is fitted as it stands.
        var carried = square(ModelScene.Material())
        carried.skeletons = [ModelScene.Skeleton(joints: [.init()])]
        carried.meshes[0].parts[0].skin = ModelScene.Skin(skeleton: 0, joints: [SIMD4<UInt16>](repeating: .zero, count: 4), weights: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 4))
        XCTAssertEqual(try renderer.makeScene(carried).framing.size.y, 2, accuracy: 0.01)
        var lift = ModelScene.AnimationClip(skeleton: 0, start: 0, end: 1)
        lift.translations = .init(times: [0, 1], values: [SIMD3(0, 0, 0), SIMD3(0, 10, 0)])
        carried.clips = [lift]
        let reach = try renderer.makeScene(carried).framing
        XCTAssertEqual(reach.size.y, 12, accuracy: 0.01)
        XCTAssertEqual(reach.center.y, 5, accuracy: 0.01)
    }

    func testACutOutIsNotThereBelowItsThresholdAndSolidAboveIt() throws {
        var material = ModelScene.Material()
        material.doubleSided = true
        // Left pixel a third there, right pixel fully.
        let image: [UInt8] = [255, 255, 255, 85, 255, 255, 255, 255]
        let solid = try draw(square(material, image: image))
        XCTAssertEqual(solid.pixel(30, 48).a, 255, "without a threshold the whole square is drawn")
        material.alphaCutoff = 0.5
        let cut = try draw(square(material, image: image))
        XCTAssertEqual(cut.pixel(30, 48).a, 0, "the left half is cut away")
        XCTAssertEqual(cut.pixel(66, 48).a, 255, "the right half is solid")
        material.alphaCutoff = 0.2
        XCTAssertEqual(try draw(square(material, image: image)).pixel(30, 48).a, 255, "a lower threshold keeps it")
    }

    /// Along its edge a cut-out is partly there: the pixel the edge runs through shows as
    /// much of it as lies inside. There or not there, pixel by pixel, a leaf's edge was a
    /// row of steps that crawled as the view turned.
    func testACutOutsEdgeIsPartlyThere() throws {
        var material = ModelScene.Material()
        material.doubleSided = true
        material.alphaCutoff = 0.5
        // From a third there on the left to fully there on the right.
        let cut = try draw(square(material, image: [255, 255, 255, 85, 255, 255, 255, 255]))
        let across = (31..<66).map { cut.pixel($0, 48).a }
        XCTAssertEqual(across.first, 0)
        XCTAssertEqual(across.last, 255)
        XCTAssertTrue(across.contains { $0 > 0 && $0 < 255 }, "\(across)")
        // What is there is there in its own colour, not darkened towards the edge.
        for x in 31..<66 where cut.pixel(x, 48).a > 0 {
            let pixel = cut.pixel(x, 48)
            XCTAssertEqual(Double(pixel.g) / Double(pixel.a), Double(cut.pixel(65, 48).g) / 255, accuracy: 0.04, "at \(x)")
        }
    }

    /// A glTF material's occlusion image says where light from all round cannot reach: in
    /// a fold, under a collar. It was not read, and folds were lit as the open surface.
    /// The lamps' own light still reaches everywhere, so a fold is darker, not black.
    func testAnOcclusionImageDarkensTheLightFromAllRound() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        renderer.look = RenderLook(view: .textured)
        let positions: [Float] = [-1,-1,0, 1,-1,0, 1,1,0, -1,1,0]
        let coordinates: [Float] = [0,1, 1,1, 1,0, 0,0]
        let indices: [UInt16] = [0,1,2, 0,2,3]
        let bytes = positions.withUnsafeBytes { Data($0) } + coordinates.withUnsafeBytes { Data($0) } + indices.withUnsafeBytes { Data($0) }
        // Left half in a fold, right half in the open.
        let imageURI = "data:image/png;base64," + Data(try png([0,0,0,255, 255,255,255,255], width: 2)).base64EncodedString()
        func halves(strength: Float?) throws -> (fold: Int, open: Int) {
            let strengthText = strength.map { ",\"strength\":\($0)" } ?? ""
            let json = """
            {"asset":{"version":"2.0"},"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"indices":2,"material":0}]}],
             "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},{"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}],
             "bufferViews":[{"buffer":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},{"buffer":0,"byteOffset":80,"byteLength":12}],
             "buffers":[{"byteLength":92,"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}],
             "images":[{"uri":"\(imageURI)"}],"samplers":[{"magFilter":9728,"wrapS":33071,"wrapT":33071}],"textures":[{"source":0,"sampler":0}],
             "materials":[{"doubleSided":true,"occlusionTexture":{"index":0\(strengthText)},"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,1],"metallicFactor":0,"roughnessFactor":1}}]}
            """
            renderer.show(try renderer.makeScene(GLTFReader.scene(from: Data(json.utf8))))
            renderer.camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100)
            let image = try renderer.renderOffscreen(width: 96, height: 96)
            return (Int(image.pixel(36, 48).g), Int(image.pixel(60, 48).g))
        }
        let full = try halves(strength: nil)
        XCTAssertLessThan(full.fold, full.open - 10, "\(full)")
        XCTAssertGreaterThan(full.fold, 20, "the lamps still light a fold")
        let none = try halves(strength: 0)
        XCTAssertEqual(none.fold, none.open, accuracy: 2, "\(none)")
        XCTAssertEqual(none.open, full.open, accuracy: 2, "the open surface is lit as before")
    }
}
