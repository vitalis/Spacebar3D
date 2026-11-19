import Foundation
import CoreGraphics
import ImageIO
import ImportGLTF
import ModelCore
import RenderMetal
import simd
import XCTest

final class RenderingContractTests: XCTestCase {
    private struct Pack {
        var data = Data(), views: [[String: Any]] = [], accessors: [[String: Any]] = []
        mutating func add(_ values: [Float], _ type: String) -> Int {
            let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][type]!
            let bytes = values.withUnsafeBufferPointer { Data(buffer: $0) }
            return add(bytes, type, 5126, values.count / width)
        }
        mutating func indices(_ values: [UInt32]) -> Int {
            add(values.withUnsafeBufferPointer { Data(buffer: $0) }, "SCALAR", 5125, values.count)
        }
        private mutating func add(_ bytes: Data, _ type: String, _ component: Int, _ count: Int) -> Int {
            views.append(["buffer": 0, "byteOffset": data.count, "byteLength": bytes.count]); data += bytes
            accessors.append(["bufferView": views.count - 1, "componentType": component, "type": type, "count": count])
            return accessors.count - 1
        }
        func scene(_ body: [String: Any]) throws -> ModelScene {
            var root = body; root["asset"] = ["version": "2.0"]
            root["bufferViews"] = views; root["accessors"] = accessors
            root["buffers"] = [["byteLength": data.count, "uri": "data:application/octet-stream;base64," + data.base64EncodedString()]]
            return try GLTFReader.scene(from: JSONSerialization.data(withJSONObject: root))
        }
    }
    private func renderer() throws -> MetalRenderer {
        let r = try MetalRenderer(); r.showGrid = false; r.showShadow = false; r.backgroundAlpha = 0
        r.look = .init(view: .textured, style: .unlit)
        return r
    }
    private let camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100)
    private func indexed(extra: Bool, animated: Bool) throws -> ModelScene {
        var p = Pack()
        let positions: [Float] = [-1,-1,1, 1,-1,1, 1,1,1, -1,1,1] + (extra ? [1000,0,-100] : [])
        let a = p.add(positions, "VEC3"), n = p.add(Array(repeating: [Float](arrayLiteral: 0,0,1), count: positions.count / 3).flatMap { $0 }, "VEC3")
        let b = p.add([-1,-1,0, 1,-1,0, 1,1,0, -1,1,0], "VEC3"), bn = p.add([0,0,1, 0,0,1, 0,0,1, 0,0,1], "VEC3")
        let indices = p.indices([0,1,2,0,2,3])
        var body: [String: Any] = ["nodes": [["mesh": 0]], "meshes": [["primitives": [
            ["attributes": ["POSITION": a, "NORMAL": n], "indices": indices, "material": 0],
            ["attributes": ["POSITION": b, "NORMAL": bn], "indices": indices, "material": 1]]]],
            "materials": [["alphaMode": "BLEND", "doubleSided": true, "pbrMetallicRoughness": ["baseColorFactor": [1,0,0,0.5]]],
                          ["alphaMode": "BLEND", "doubleSided": true, "pbrMetallicRoughness": ["baseColorFactor": [0,0,1,0.5]]]]]
        if animated {
            let t = p.add([0,1], "SCALAR"), v = p.add([0,0,0, 0,0,0], "VEC3")
            body["animations"] = [["samplers": [["input": t, "output": v]], "channels": [["sampler": 0, "target": ["node": 0, "path": "translation"]]]]]
        }
        return try p.scene(body)
    }
    func testUnusedIndexedVerticesDoNotAffectFitOrTransparency() throws {
        let r = try renderer()
        for animated in [false, true] {
            let clean = try r.makeScene(indexed(extra: false, animated: animated))
            r.show(clean)
            let fit = try r.renderOffscreen(width: 128, height: 128)
            r.camera = camera
            let fixed = try r.renderOffscreen(width: 128, height: 128)
            let extra = try r.makeScene(indexed(extra: true, animated: animated))
            XCTAssertEqual(extra.framing, clean.framing)
            r.show(extra)
            XCTAssertEqual(try r.renderOffscreen(width: 128, height: 128).bytes, fit.bytes)
            r.camera = camera
            XCTAssertEqual(try r.renderOffscreen(width: 128, height: 128).bytes, fixed.bytes)
        }
    }
    func testUnusedMorphVertexDoesNotExpandAnimatedBounds() throws {
        let r = try renderer()
        var source = try indexed(extra: true, animated: true)
        let mesh = try XCTUnwrap(source.nodes[0].mesh)
        var offsets = [SIMD3<Float>](repeating: .zero, count: source.meshes[mesh].parts[0].positions.count)
        offsets[offsets.count - 1] = SIMD3(10000,10000,10000)
        source.meshes[mesh].parts[0].morphTargets = [.init(positions: offsets)]
        source.clips[0].morphs = [.init(mesh: mesh, targetCount: 1, times: [0,1], values: [0,1])]
        let expected = try r.makeScene(indexed(extra: false, animated: true))
        let actual = try r.makeScene(source)
        XCTAssertEqual(actual.framing, expected.framing)
        r.show(expected); r.camera = camera
        let reference = try r.renderOffscreen(width: 128, height: 128).bytes
        r.show(actual); r.camera = camera; actual.pose(clip: 0, time: 1)
        XCTAssertEqual(try r.renderOffscreen(width: 128, height: 128).bytes, reference)
    }

    private func morph(weight: Float?, authored: Bool) throws -> ModelScene {
        var p = Pack()
        let base: [Float] = [-1,-1,0, 1,-1,0, 0,1,0], c = sqrt(Float(0.5))
        let final: [Float] = [-c,-1,c, c,-1,-c, 0,1,0]
        let delta = zip(final, base).map(-)
        let shape = weight.map { w in zip(base, delta).map { $0 + $1 * w } } ?? base
        let position = p.add(shape, "VEC3")
        var attributes = ["POSITION": position]
        if authored { attributes["NORMAL"] = p.add([0,0,1, 0,0,1, 0,0,1], "VEC3") }
        var primitive: [String: Any] = ["attributes": attributes, "material": 0]
        var body: [String: Any] = ["nodes": [["mesh": 0]], "materials": [["doubleSided": true]]]
        if weight == nil {
            primitive["targets"] = [["POSITION": p.add(delta, "VEC3")]]
            let t = p.add([0,1], "SCALAR"), v = p.add([0,1], "SCALAR")
            body["animations"] = [["samplers": [["input": t, "output": v]], "channels": [["sampler": 0, "target": ["node": 0, "path": "weights"]]]]]
        }
        body["meshes"] = [["primitives": [primitive]]]
        return try p.scene(body)
    }
    func testMorphNormalsMatchStaticShapeWithoutReplacingAuthoredNormals() throws {
        let r = try renderer(); r.look = .init(view: .normal)
        for onGPU in [false, true] { for authored in [false, true] { for weight: Float in [0,0.5,1] {
            r.skinsOnGPU = onGPU
            let moving = try r.makeScene(morph(weight: nil, authored: authored))
            r.show(moving); r.camera = camera; moving.pose(clip: 0, time: weight)
            let actual = try r.renderOffscreen(width: 128, height: 128).pixel(64,64)
            r.show(try r.makeScene(morph(weight: weight, authored: authored))); r.camera = camera
            let expected = try r.renderOffscreen(width: 128, height: 128).pixel(64,64)
            XCTAssertEqual(Int(actual.r), Int(expected.r), accuracy: 1)
            XCTAssertEqual(Int(actual.g), Int(expected.g), accuracy: 1)
            XCTAssertEqual(Int(actual.b), Int(expected.b), accuracy: 1)
        } } }
    }
    private func point(alphaMode: String, alpha: Float, color: [Float]?, factor: [Float] = [1,0,0]) throws -> ModelScene {
        var p = Pack(); let position = p.add([0,0,0], "VEC3")
        var attributes = ["POSITION": position]
        if let color { attributes["COLOR_0"] = p.add(color, "VEC4") }
        return try p.scene(["nodes": [["mesh": 0]], "meshes": [["primitives": [["mode": 0, "attributes": attributes, "material": 0]]]],
                           "materials": [["alphaMode": alphaMode, "alphaCutoff": 0.5, "pbrMetallicRoughness": ["baseColorFactor": factor + [alpha]]]]])
    }
    private func pointPixel(_ scene: ModelScene, _ r: MetalRenderer) throws -> [Int] {
        r.show(try r.makeScene(scene)); r.camera = camera
        let p = try r.renderOffscreen(width: 128, height: 128).pixel(64,64)
        return [Int(p.r), Int(p.g), Int(p.b), Int(p.a)]
    }
    func testPointAlphaModesAndMaterialTint() throws {
        let r = try renderer()
        XCTAssertEqual(try pointPixel(point(alphaMode: "BLEND", alpha: 0, color: nil), r), [0,0,0,0])
        XCTAssertEqual(try pointPixel(point(alphaMode: "MASK", alpha: 1, color: [1,0,0,0]), r), [0,0,0,0])
        XCTAssertEqual(try pointPixel(point(alphaMode: "OPAQUE", alpha: 0, color: [1,0,0,0]), r), [255,0,0,255])
        XCTAssertEqual(try pointPixel(point(alphaMode: "OPAQUE", alpha: 1, color: [1,0,0,1], factor: [0,1,0]), r), [0,0,0,255])
        let half = try pointPixel(point(alphaMode: "BLEND", alpha: 0.5, color: [1,1,1,0.5]), r)
        XCTAssertEqual(half[0], 64, accuracy: 1); XCTAssertEqual(half[3], 64, accuracy: 1)
    }

    private func png(_ rgba: [UInt8]) throws -> String {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: rgba.count / 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: rgba.count, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    private func texturedPoint(_ image: String, mode: String = "OPAQUE", uv: [Float] = [0.5,0.5], uv1: [Float]? = nil,
                               info: [String: Any] = ["index": 0], sampling: [String: Any] = ["magFilter": 9728],
                               indices: [UInt32]? = nil, positions: [Float]? = nil,
                               color: [Float]? = nil, factor: [Float] = [1,1,1,1]) throws -> ModelScene {
        var p = Pack()
        let position = p.add(positions ?? Array(repeating: 0, count: uv.count / 2 * 3), "VEC3")
        var attributes = ["POSITION": position, "TEXCOORD_0": p.add(uv, "VEC2")]
        if let uv1 { attributes["TEXCOORD_1"] = p.add(uv1, "VEC2") }
        if let color { attributes["COLOR_0"] = p.add(color, "VEC4") }
        var primitive: [String: Any] = ["mode": 0, "attributes": attributes, "material": 0]
        if let indices { primitive["indices"] = p.indices(indices) }
        return try p.scene([
            "nodes": [["mesh": 0]], "meshes": [["primitives": [primitive]]],
            "materials": [["alphaMode": mode, "alphaCutoff": 0.5, "extensions": ["KHR_materials_unlit": [:]],
                           "pbrMetallicRoughness": ["baseColorFactor": factor, "baseColorTexture": info]]],
            "samplers": [sampling], "textures": [["source": 0, "sampler": 0]], "images": [["uri": image]],
            "extensionsUsed": ["KHR_materials_unlit", "KHR_texture_transform"]])
    }

    func testTexturedPointAlphaModes() throws {
        let r = try renderer()
        for (mode, alpha, expected): (String, UInt8, [Int]) in [
            ("OPAQUE", 255, [0,255,0,255]), ("OPAQUE", 0, [0,255,0,255]),
            ("MASK", 0, [0,0,0,0]), ("MASK", 128, [0,255,0,255]),
            ("BLEND", 128, [0,128,0,128])
        ] {
            let source = try texturedPoint(png([0,255,0,alpha]), mode: mode)
            let actual = try pointPixel(source, r)
            for i in 0..<4 { XCTAssertEqual(actual[i], expected[i], accuracy: 1, "\(mode), alpha \(alpha)") }
        }
    }

    func testPointTextureMultipliesMaterialAndVertexColorAndAlpha() throws {
        let source = try texturedPoint(png([255,255,255,128]), mode: "BLEND",
                                       color: [1,0.25,1,0.5], factor: [0.25,1,1,0.5])
        let actual = try pointPixel(source, renderer())
        // RGB is multiplied in linear light, then encoded and premultiplied by coverage.
        for (a, e) in zip(actual, [17,17,32,32]) { XCTAssertEqual(a, e, accuracy: 1) }
    }

    func testPointTexturesUseUVSelectionTransformSamplerAndIndices() throws {
        let image = try png([255,0,0,255, 0,255,0,255]), r = try renderer()
        let green = [0,255,0,255], red = [255,0,0,255]
        let selected = try texturedPoint(image, uv: [0.25,0.5], uv1: [0.75,0.5], info: ["index": 0, "texCoord": 1])
        XCTAssertEqual(try pointPixel(selected, r), green)
        let transformed = try texturedPoint(image, uv: [0.25,0.5], info: ["index": 0, "extensions": ["KHR_texture_transform": ["offset": [0.5,0.0]]]])
        XCTAssertEqual(try pointPixel(transformed, r), green)
        let indexed = try texturedPoint(image, uv: [0.25,0.5, 0.75,0.5], indices: [1])
        XCTAssertEqual(try pointPixel(indexed, r), green)
        for (wrap, expected) in [(10497, red), (33071, green), (33648, green)] {
            let source = try texturedPoint(image, uv: [1.25,0.5], sampling: ["magFilter": 9728, "wrapS": wrap])
            XCTAssertEqual(try pointPixel(source, r), expected)
        }
        let smooth = try texturedPoint(image, sampling: ["magFilter": 9729])
        let blended = try pointPixel(smooth, r)
        for (a, e) in zip(blended, [188,188,0,255]) { XCTAssertEqual(a, e, accuracy: 1) }
    }

    func testPointTextureMotionUsesItsMask() throws {
        let image = try png([255,0,0,255, 0,255,0,255]), r = try renderer()
        for share: UInt8 in [0,255] {
            var source = try texturedPoint(image, uv: [0.25,0.5])
            var toon = ModelScene.Toon()
            toon.uvScroll = SIMD2(0.5,0); toon.uvMaskTexture = 1
            source.materials[0].unlit = false; source.materials[0].toon = toon
            source.textures.append(.pixels(width: 1, height: 1, rgba: [0,0,share,255]))
            r.show(try r.makeScene(source)); r.camera = camera
            r.materialSeconds = 0
            let before = try r.renderOffscreen(width: 128, height: 128).pixel(64,64)
            XCTAssertEqual([Int(before.r),Int(before.g),Int(before.b)], [255,0,0])
            r.materialSeconds = 1
            let after = try r.renderOffscreen(width: 128, height: 128).pixel(64,64)
            XCTAssertEqual([Int(after.r),Int(after.g),Int(after.b)], share == 0 ? [255,0,0] : [0,255,0])
        }
    }

    func testTranslucentPointTexturesFollowSortedVertexIndices() throws {
        let source = try texturedPoint(png([255,0,0,128, 0,255,0,128]), mode: "BLEND",
                                       uv: [0.25,0.5, 0.75,0.5], indices: [1,0], positions: [0,0,0, 0,0,1])
        let actual = try pointPixel(source, renderer())
        for (a, e) in zip(actual, [64,128,0,192]) { XCTAssertEqual(a, e, accuracy: 1) }
    }
}
