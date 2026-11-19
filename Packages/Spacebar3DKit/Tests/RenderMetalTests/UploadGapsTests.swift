import CoreGraphics
import ImageIO
import Metal
import ModelCore
import simd
import XCTest
@testable import RenderMetal

/// Image decoding and upload, and the corners of making a scene for the GPU.
final class UploadGapsTests: XCTestCase {
    private func device() throws -> MTLDevice { try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device") }

    /// A grey picture, `value` everywhere, in a one-channel colour space.
    private func grey(_ width: Int, _ height: Int, value: UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: value, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func colour(_ width: Int, _ height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4] = 200; pixels[i * 4 + 1] = 100; pixels[i * 4 + 2] = 50; pixels[i * 4 + 3] = 255 }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func bytes(of texture: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&out, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }

    // MARK: Pixels

    func testAGreyImageUsedAsDataKeepsItsNumbersInThreeChannels() throws {
        let pixels = try XCTUnwrap(TextureUpload.pixels(of: grey(4, 2, value: 90), colour: false, maxSide: 64))
        XCTAssertEqual([pixels.width, pixels.height], [4, 2])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels.rgba.bytes, count: 8)), [90, 90, 90, 255, 90, 90, 90, 255])
        // As a colour it is drawn through sRGB instead, and is still grey.
        let shown = try XCTUnwrap(TextureUpload.pixels(of: grey(4, 2, value: 90), colour: true, maxSide: 64))
        XCTAssertEqual(shown.rgba.bytes[0], shown.rgba.bytes[1])
    }

    func testBigImagesAreScaledToTheLimit() throws {
        let small = try XCTUnwrap(TextureUpload.pixels(of: colour(32, 16), colour: true, maxSide: 8))
        XCTAssertEqual([small.width, small.height], [8, 4])
        // Decoded pixels of a model, over the limit, are scaled the same way; under it, copied.
        let rgba = [UInt8](repeating: 128, count: 16 * 16 * 4)
        let scaled = try XCTUnwrap(TextureUpload.pixels(of: .pixels(width: 16, height: 16, rgba: rgba), colour: true, maxSide: 4))
        XCTAssertEqual([scaled.width, scaled.height], [4, 4])
        let copied = try XCTUnwrap(TextureUpload.pixels(of: .pixels(width: 16, height: 16, rgba: rgba), colour: true, maxSide: 64))
        XCTAssertEqual([copied.width, copied.height], [16, 16])
        XCTAssertEqual(Int(copied.rgba.bytes[0]), 93, accuracy: 1, "alpha multiplies linear light, then RGB is sRGB encoded")
    }

    func testRawColourAlphaSurvivesResizeAndUpload() throws {
        let device = try device()
        for alpha: UInt8 in [0, 128, 255] {
            let rgba = Array(repeating: [UInt8](arrayLiteral: 255, 0, 0, alpha), count: 4).flatMap { $0 }
            let image = ModelScene.TextureRef.pixels(width: 2, height: 2, rgba: rgba)
            for limit in [1, 2] {
                let pixels = try XCTUnwrap(TextureUpload.pixels(of: image, colour: true, maxSide: limit))
                XCTAssertEqual(Int(pixels.rgba.bytes[0]), alpha == 128 ? 188 : Int(alpha), accuracy: 1)
                XCTAssertEqual(pixels.rgba.bytes[3], alpha)
                let texture = try XCTUnwrap(TextureUpload.make(image, device: device, maxSide: limit))
                let uploaded = bytes(of: texture)
                XCTAssertEqual(Int(uploaded[0]), alpha == 128 ? 188 : Int(alpha), accuracy: 1)
                XCTAssertEqual(uploaded[3], alpha)
                // Alpha must never scale normal/roughness/metallic channel values.
                let data = try XCTUnwrap(TextureUpload.pixels(of: image, colour: false, maxSide: limit))
                XCTAssertEqual(data.rgba.bytes[0], 255)
            }
        }
    }

    func testImagesThatCannotBeReadGiveNothing() throws {
        XCTAssertNil(TextureUpload.pixels(of: .pixels(width: 0, height: 4, rgba: []), colour: true, maxSide: 64))
        XCTAssertNil(TextureUpload.pixels(of: .pixels(width: 4, height: 4, rgba: [1, 2, 3]), colour: true, maxSide: 64), "fewer bytes than the size says")
        XCTAssertNil(TextureUpload.pixels(of: .sidecar(name: "a.png"), colour: true, maxSide: 64))
        XCTAssertNil(TextureUpload.pixels(of: .missing(name: "a.png"), colour: true, maxSide: 64))
        XCTAssertNil(TextureUpload.pixels(of: .embedded(bytes: [1, 2, 3, 4], mime: ""), colour: true, maxSide: 64))
        XCTAssertNil(TextureUpload.pixels(of: .embedded(bytes: [], mime: ""), colour: true, maxSide: 64))
        XCTAssertNil(TextureUpload.make(.missing(name: "x"), device: try device()))
    }

    func testALargeJPEGIsDecodedAtAReducedSize() throws {
        let image = try colour(256, 256)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pixels = try XCTUnwrap(TextureUpload.pixels(of: .embedded(bytes: [UInt8](data as Data), mime: "image/jpeg"), colour: true, maxSide: 32))
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 32)
        XCTAssertGreaterThan(pixels.width, 0)
    }

    // MARK: Upload

    func testAnImageGoesUpWithItsSmallerVersions() throws {
        let texture = try XCTUnwrap(TextureUpload.make(try colour(8, 8), device: try device()))
        XCTAssertEqual([texture.width, texture.height], [8, 8])
        XCTAssertEqual(texture.mipmapLevelCount, 4)
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm_srgb)
        let data = try XCTUnwrap(TextureUpload.make(try colour(8, 8), device: try device(), srgb: false, maxSide: 4))
        XCTAssertEqual([data.width, data.height], [4, 4])
        XCTAssertEqual(data.pixelFormat, .rgba8Unorm)
    }

    func testRoughnessAndMetallicFromTwoGreyImagesShareOneTexture() throws {
        let rough = ModelScene.TextureRef.pixels(width: 2, height: 2, rgba: [UInt8](repeating: 100, count: 16))
        // Metallic is bigger: it is sampled down to the first one's size.
        let metal = ModelScene.TextureRef.pixels(width: 4, height: 4, rgba: [UInt8](repeating: 50, count: 64))
        let both = try XCTUnwrap(TextureUpload.makePacked(roughness: rough, metallic: metal, device: device(), maxSide: 64))
        XCTAssertEqual([both.width, both.height], [2, 2])
        var texel = bytes(of: both)
        XCTAssertEqual(Array(texel[0..<4]), [255, 100, 50, 255], "red untouched, green roughness, blue metallic")
        // The same size, and one side missing: that side stays at full.
        let same = try XCTUnwrap(TextureUpload.makePacked(roughness: rough, metallic: rough, device: device(), maxSide: 64))
        texel = bytes(of: same)
        XCTAssertEqual(Array(texel[0..<4]), [255, 100, 100, 255])
        let only = try XCTUnwrap(TextureUpload.makePacked(roughness: nil, metallic: metal, device: device(), maxSide: 64))
        XCTAssertEqual(Array(bytes(of: only)[0..<4]), [255, 255, 50, 255])
        XCTAssertNil(TextureUpload.makePacked(roughness: nil, metallic: nil, device: try device(), maxSide: 64))
        XCTAssertNil(TextureUpload.makePacked(roughness: .missing(name: "a"), metallic: nil, device: try device(), maxSide: 64))
    }

    // MARK: Scenes

    func testRenderErrorsHaveMessages() {
        let all: [RenderError] = [.noDevice, .shaders("oops"), .tooLarge, .badIndices]
        XCTAssertEqual(Set(all.compactMap(\.errorDescription)).count, 4)
        XCTAssertTrue(all[1].errorDescription?.contains("oops") == true)
    }

    /// A quad with texture coordinates whose material uses images of every kind.
    private func texturedScene() -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        part.uv0 = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.material = 0
        var material = ModelScene.Material()
        material.roughnessTexture = 0
        material.metallicTexture = 1
        material.emissiveTexture = 2
        var toon = ModelScene.Toon()
        toon.shadeTexture = 2
        material.toon = toon
        var scene = ModelScene()
        scene.textures = (0..<3).map { _ in .pixels(width: 2, height: 2, rgba: [UInt8](repeating: 120, count: 16)) }
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    func testSeparateRoughnessMetallicEmissiveAndShadeImagesAllGoUp() throws {
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(texturedScene())
        XCTAssertEqual(gpu.triangleCount, 2)
        XCTAssertGreaterThan(gpu.gpuBytes, 0)
    }

    func testTheWireOfAPartWithNoIndicesAndAnAsynchronousPreparation() throws {
        // Three loose corners, no index list: they are taken in order, as one triangle.
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        let gpu = try MetalRenderer().makeScene(scene)
        let done = expectation(description: "wire ready")
        XCTAssertFalse(gpu.isWireReady)
        gpu.prepareWireAsync { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(gpu.isWireReady)
        // Asked again when it is ready, it answers at once.
        let again = expectation(description: "answered")
        gpu.prepareWireAsync { again.fulfill() }
        wait(for: [again], timeout: 1)
    }

    func testAShapeThatTurnsNormalsToo() throws {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 3)
        part.triangleIndices = [0, 1, 2]
        part.skin = ModelScene.Skin(skeleton: 0, joints: [SIMD4<UInt16>](repeating: .zero, count: 3), weights: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 3))
        part.morphTargets = [ModelScene.MorphTarget(positions: [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 3), normals: [SIMD3<Float>](repeating: SIMD3(1, 0, 0), count: 3))]
        var mesh = ModelScene.Mesh(parts: [part])
        mesh.morphWeights = [0.5]
        var scene = ModelScene()
        scene.skeletons = [ModelScene.Skeleton(joints: [.init(name: "a")], node: 0)]
        scene.meshes = [mesh]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        let gpu = try MetalRenderer().makeScene(scene)
        XCTAssertTrue(gpu.isSkinned)
        _ = gpu.pose(time: 0)
    }

    func testMorphUpdatesDoNotOverwriteQueuedFrames() throws {
        let device = try device()
        let library = try device.makeLibrary(source: Shaders.source + HologramShaders.source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "skinVertices")))
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        part.normals = Array(repeating: SIMD3<Float>(0, 0, 1), count: 3)
        part.triangleIndices = [0, 1, 2]
        part.skin = .init(skeleton: 0, joints: Array(repeating: .zero, count: 3), weights: Array(repeating: SIMD4(1, 0, 0, 0), count: 3))
        part.morphTargets = [.init(positions: Array(repeating: SIMD3(10, 0, 0), count: 3))]
        var scene = ModelScene()
        scene.meshes = [.init(parts: [part])]; scene.nodes = [.init(mesh: 0)]; scene.skeletons = [.init(joints: [.init()])]
        var clip = ModelScene.AnimationClip(skeleton: 0, start: 0, end: 1)
        clip.morphs = [.init(mesh: 0, targetCount: 1, times: [0, 1], values: [0, 1])]
        scene.clips = [clip]
        let gpu = try GPUScene(device: device, scene: scene)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for onGPU in [true, false] {
            let chosen = onGPU ? pipeline : nil
            gpu.pose(clip: 0, time: 0)
            let gate = try XCTUnwrap(device.makeSharedEvent())
            let first = try XCTUnwrap(queue.makeCommandBuffer())
            let second = try XCTUnwrap(queue.makeCommandBuffer())
            let saved = try XCTUnwrap(device.makeBuffer(length: 4, options: .storageModeShared))
            first.encodeWaitForEvent(gate, value: 1)
            gpu.encodePose(into: first, pipeline: chosen)
            let blit = try XCTUnwrap(first.makeBlitCommandEncoder())
            blit.copy(from: gpu.parts[0].vertexBuffer, sourceOffset: 0, to: saved, destinationOffset: 0, size: 4)
            blit.endEncoding()
            first.commit()
            gpu.pose(clip: 0, time: 1)
            gpu.encodePose(into: second, pipeline: chosen)
            second.commit()
            gate.signaledValue = 1
            second.waitUntilCompleted()
            XCTAssertEqual(first.status, .completed)
            XCTAssertEqual(second.status, .completed)
            XCTAssertEqual(saved.contents().load(as: Float.self), 0, accuracy: 1e-5)
            XCTAssertEqual(gpu.parts[0].vertexBuffer.contents().load(as: Float.self), 10, accuracy: 1e-5)
        }
    }

    func testSkinNormalsAndOutlinesUnderNonuniformScale() throws {
        let device = try device()
        let library = try device.makeLibrary(source: Shaders.source + HologramShaders.source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "skinVertices")))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let restNormal = simd_normalize(SIMD3<Float>(-1, 0, 1))
        for x: Float in [2, -2, 0] {
            var part = ModelScene.MeshPart()
            part.positions = [SIMD3(0,0,0), SIMD3(1,0,1), SIMD3(0,1,0)]
            part.normals = Array(repeating: restNormal, count: 3); part.triangleIndices = [0,1,2]
            part.skin = .init(skeleton: 0, joints: Array(repeating: .zero, count: 3), weights: Array(repeating: SIMD4(1,0,0,0), count: 3))
            var scene = ModelScene()
            scene.meshes = [.init(parts: [part])]; scene.nodes = [.init(mesh: 0)]
            scene.skeletons = [.init(joints: [.init(rest: simd_float4x4(diagonal: SIMD4(x,1,1,1)))])]
            let gpu = try GPUScene(device: device, scene: scene)
            gpu.prepareOutline()
            let expected = x == 0 ? restNormal : simd_normalize(SIMD3(-1 / x, 0, 1))
            for onGPU in [false, true] {
                gpu.pose()
                let commands = try XCTUnwrap(queue.makeCommandBuffer())
                gpu.encodePose(into: commands, pipeline: onGPU ? pipeline : nil)
                commands.commit(); commands.waitUntilCompleted()
                XCTAssertEqual(commands.status, .completed)
                let values = gpu.parts[0].vertexBuffer.contents().assumingMemoryBound(to: Float.self)
                let actual = simd_normalize(SIMD3(values[3], values[4], values[5]))
                XCTAssertLessThan(simd_distance(actual, expected), 1e-5)
                let outline = try XCTUnwrap(gpu.parts[0].outlineNormals).contents().assumingMemoryBound(to: Float.self)
                XCTAssertLessThan(simd_distance(simd_normalize(SIMD3(outline[0], outline[1], outline[2])), expected), 1e-5)
                if x != 0 { XCTAssertEqual(simd_dot(actual, simd_normalize(SIMD3(x,0,1))), 0, accuracy: 1e-5) }
            }
        }
    }

    func testColorMipmapsAndResizeFilterPremultipliedLinearLight() throws {
        let device = try device()
        // An opaque red texel beside a fully transparent green texel.
        let source = ModelScene.TextureRef.pixels(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 255, 0, 0])
        for limit in [1, 2] {
            let texture = try XCTUnwrap(TextureUpload.make(source, device: device, maxSide: limit))
            var pixel = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: limit == 1 ? 0 : 1)
            XCTAssertEqual(Int(pixel[0]), 188, accuracy: 2)
            XCTAssertEqual(pixel[1], 0)
            XCTAssertEqual(pixel[2], 0)
            XCTAssertEqual(Int(pixel[3]), 128, accuracy: 1)
        }
    }
}
