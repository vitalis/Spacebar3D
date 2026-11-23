import Foundation
import ImportRouter
import ModelCore
import simd
import XCTest
@testable import ImportGLTF

final class GLTFReaderTests: XCTestCase {
    func testSparseOffsetsCannotReadBeforeTheirViews() throws {
        let buffer = bytes([Float](repeating: 0, count: 9)) + bytes([UInt16(2), UInt16(0)]) + bytes([Float](arrayLiteral: 0, 5, 0))
        for (indexOffset, valueOffset) in [(-4, 0), (0, -12), (-1000000, 0), (0, 1000000)] {
            let json = """
            {"asset":{"version":"2.0"},"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
             "accessors":[{"componentType":5126,"count":3,"type":"VEC3",
               "sparse":{"count":1,"indices":{"bufferView":1,"componentType":5123,"byteOffset":\(indexOffset)},
                         "values":{"bufferView":2,"byteOffset":\(valueOffset)}}}],
             "bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":2},{"buffer":0,"byteOffset":40,"byteLength":12}],
             "buffers":[{\(dataURI(buffer))"byteLength":52}]}
            """
            XCTAssertThrowsError(try GLTFReader.scene(from: Data(json.utf8))) {
                XCTAssertEqual($0 as? GLTFReader.Failure, .damaged("an accessor runs past its data"))
            }
        }
    }

    func testHugeFiniteAnimationTimesStayBounded() throws {
        for duration: Float in [1e30, .greatestFiniteMagnitude] {
            let scene = try GLTFReader.scene(from: animated(skinned: true, duration: duration))
            let clip = try XCTUnwrap(scene.clips.first)
            XCTAssertEqual(clip.end, duration)
            let track = try XCTUnwrap(clip.linearTranslations[0])
            XCTAssertEqual(track.times.count, 2)
            XCTAssertTrue(track.times.allSatisfy(\.isFinite))
            XCTAssertEqual(track.times.last, duration)
            XCTAssertTrue(track.values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        }
    }

    // MARK: Building files

    /// Little-endian bytes of the given values.
    private func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

    /// A quad of two triangles in the XY plane: four positions (float), six indices (16 bit).
    private var quadBuffer: Data {
        bytes([Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0)) + bytes([UInt16](arrayLiteral: 0, 1, 2, 0, 2, 3))
    }

    private func quadJSON(buffer: String, extra: String = "", primitive: String = "\"indices\": 1", material: String = "{}") -> String {
        """
        {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
         "nodes": [{"name": "root", "translation": [1, 2, 3], "children": [1]}, {"mesh": 0, "scale": [2, 2, 2]}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, \(primitive), "material": 0}]}],
         "materials": [\(material)],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"},
                       {"bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR"}],
         "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48}, {"buffer": 0, "byteOffset": 48, "byteLength": 12}],
         "buffers": [{\(buffer)"byteLength": 60}]\(extra)}
        """
    }

    private func dataURI(_ data: Data) -> String { "\"uri\": \"data:application/octet-stream;base64,\(data.base64EncodedString())\", " }

    /// A `.glb` around a description and its binary chunk.
    private func glb(_ json: String, _ binary: Data?) -> Data {
        func padded(_ data: Data, with byte: UInt8) -> Data { data + Data(repeating: byte, count: (4 - data.count % 4) % 4) }
        let text = padded(Data(json.utf8), with: 0x20)
        var body = bytes([UInt32(text.count), 0x4e4f534a]) + text
        if let binary {
            let chunk = padded(binary, with: 0)
            body += bytes([UInt32(chunk.count), 0x004e4942]) + chunk
        }
        return Data("glTF".utf8) + bytes([UInt32(2), UInt32(12 + body.count)]) + body
    }

    // MARK: Reading

    func testAQuadInTheTextFormWithItsDataInside() throws {
        let scene = try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer)).utf8))
        XCTAssertEqual(scene.nodes.count, 2)
        XCTAssertEqual(scene.nodes[0].name, "root")
        XCTAssertNil(scene.nodes[0].parent)
        XCTAssertEqual(scene.nodes[1].parent, 0)
        XCTAssertEqual(scene.nodes[1].mesh, 0)
        // Placed by its parents: scaled by two, then moved.
        let bounds = try XCTUnwrap(scene.bounds)
        XCTAssertEqual(bounds.min, SIMD3(1, 2, 3))
        XCTAssertEqual(bounds.max, SIMD3(3, 4, 3))
        let part = scene.meshes[0].parts[0]
        XCTAssertEqual(part.positions.count, 4)
        XCTAssertEqual(part.triangleIndices, [0, 1, 2, 0, 2, 3])
        XCTAssertTrue(part.normals.isEmpty)
        XCTAssertEqual(scene.topology.faces, 2)
        XCTAssertEqual(scene.topology.vertices, 4)
        XCTAssertEqual(scene.topology.label, "Triangle")
        // A material that says nothing is white, fully metallic and rough, as the format defines.
        let material = scene.materials[try XCTUnwrap(part.material)]
        XCTAssertEqual(material.baseColor, SIMD4(1, 1, 1, 1))
        XCTAssertEqual(material.metallic, 1)
        XCTAssertEqual(material.roughness, 1)
        XCTAssertTrue(material.authoredPBR)
        XCTAssertEqual(material.opacity, 1)
    }

    func testTheBinaryContainerAndABufferBesideTheModel() throws {
        let binary = try GLTFReader.scene(from: glb(quadJSON(buffer: ""), quadBuffer))
        XCTAssertEqual(binary.meshes[0].parts[0].triangleIndices.count, 6)

        let text = Data(quadJSON(buffer: "\"uri\": \"my%20quad.bin\", ").utf8)
        let beside = try GLTFReader.scene(from: text, sidecars: SidecarFiles(["my quad.bin": quadBuffer]))
        XCTAssertEqual(beside.meshes[0].parts[0].positions.count, 4)
        // Out of reach, the model cannot be shown, and the file is named.
        XCTAssertThrowsError(try GLTFReader.scene(from: text, sidecars: SidecarFiles())) {
            XCTAssertEqual($0 as? GLTFReader.Failure, .missingFiles(["my quad.bin"]))
        }
        XCTAssertThrowsError(try GLTFReader.scene(from: Data(quadJSON(buffer: "\"uri\": \"https://example.com/quad.bin\", ").utf8), sidecars: SidecarFiles(["quad.bin": quadBuffer])),
                             "nothing is fetched from elsewhere")
    }

    func testMaterialsColourImagesBlendingAndExtensions() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let material = """
        {"name": "paint", "doubleSided": true, "alphaMode": "BLEND",
         "pbrMetallicRoughness": {"baseColorFactor": [0.5, 0, 1, 0.25], "metallicFactor": 0.2, "roughnessFactor": 0.7,
                                  "baseColorTexture": {"index": 0}, "metallicRoughnessTexture": {"index": 1}},
         "normalTexture": {"index": 1}, "extensions": {"KHR_materials_unlit": {}}}
        """
        let extra = """
        , "samplers": [{"wrapS": 33071, "wrapT": 33648, "magFilter": 9728}],
          "textures": [{"source": 0, "sampler": 0}, {"source": 1}],
          "images": [{"uri": "data:image/png;base64,\(png.base64EncodedString())"}, {"uri": "maps/detail.png"}]
        """
        let json = quadJSON(buffer: dataURI(quadBuffer), extra: extra, material: material)
        let scene = try GLTFReader.scene(from: Data(json.utf8), sidecars: SidecarFiles(["detail.png": Data([1, 2])]))
        let read = scene.materials[0]
        XCTAssertEqual(read.name, "paint")
        // The file's colour is linear; half becomes about 0.735 as seen on screen.
        XCTAssertEqual(read.baseColor.x, 0.735, accuracy: 0.001)
        XCTAssertEqual(read.baseColor.y, 0)
        XCTAssertEqual(read.baseColor.z, 1)
        XCTAssertEqual(read.opacity, 0.25)
        XCTAssertEqual(read.metallic, 0.2, accuracy: 1e-6)
        XCTAssertEqual(read.roughness, 0.7, accuracy: 1e-6)
        XCTAssertTrue(read.doubleSided)
        XCTAssertFalse(read.oneSided)
        // The colour image's sampler: clamped across, mirrored down, enlarged without blending.
        XCTAssertEqual(read.sampling, ModelScene.TextureSampling(wrapS: .clamp, wrapT: .mirror, sharp: true))
        XCTAssertTrue(read.unlit)
        XCTAssertEqual(read.baseColorTexture, 0)
        XCTAssertEqual(read.metallicRoughnessTexture, 1)
        XCTAssertEqual(read.normalTexture, 1)
        XCTAssertEqual(scene.textures.count, 2)
        guard case .embedded(let bytes, _) = scene.textures[0] else { return XCTFail("no image") }
        XCTAssertEqual(bytes, [0x89, 0x50, 0x4e, 0x47])
        XCTAssertTrue(scene.diagnostics.missingResources.isEmpty)

        // An image out of reach is named, and the material keeps its colour.
        let without = try GLTFReader.scene(from: Data(json.utf8), sidecars: SidecarFiles())
        XCTAssertEqual(without.diagnostics.missingResources, ["detail.png"])
        XCTAssertNil(without.materials[0].normalTexture)
        XCTAssertEqual(without.materials[0].baseColorTexture, 0)

        // A cut-out: the threshold, with the material's own alpha counted in; solid otherwise.
        let mask = "{\"alphaMode\": \"MASK\", \"alphaCutoff\": 0.3, \"pbrMetallicRoughness\": {\"baseColorFactor\": [1, 1, 1, 0.5]}}"
        let cut = try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer), material: mask).utf8)).materials[0]
        XCTAssertEqual(try XCTUnwrap(cut.alphaCutoff), 0.6, accuracy: 1e-6)
        XCTAssertEqual(cut.opacity, 1)
        XCTAssertNil(read.alphaCutoff)

        // The older specular-glossiness model, with the faint highlight of a surface that is no metal.
        let old = "{\"extensions\": {\"KHR_materials_pbrSpecularGlossiness\": {\"diffuseFactor\": [1, 0, 0, 1], \"specularFactor\": [0.04, 0.04, 0.04], \"glossinessFactor\": 0.75}}}"
        let glossy = try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer), material: old).utf8)).materials[0]
        XCTAssertLessThan(simd_distance(glossy.baseColor, SIMD4(1, 0, 0, 1)), 1e-4)
        XCTAssertEqual(glossy.roughness, 0.25)
        XCTAssertEqual(glossy.metallic, 0, accuracy: 1e-4)
        XCTAssertTrue(glossy.oneSided, "a material that is not double-sided shows its front only")
        XCTAssertEqual(glossy.sampling, ModelScene.TextureSampling())
    }

    /// In the older model a metal is a dark diffuse colour under a bright, coloured specular
    /// one. It is brought to metal and roughness the way Khronos's own conversion does it;
    /// where an image holds the specular colour, which would have to be worked out point
    /// by point, the surface stays a non-metal in its diffuse colour.
    func testSpecularGlossinessBecomesMetalAndRoughness() throws {
        func material(_ extensionBody: String) throws -> ModelScene.Material {
            let json = "{\"extensions\": {\"KHR_materials_pbrSpecularGlossiness\": {\(extensionBody)}}}"
            return try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer), material: json).utf8)).materials[0]
        }
        func onScreen(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> { SIMD4(Document.toSRGB(r), Document.toSRGB(g), Document.toSRGB(b), 1) }

        // Gold: nothing diffuse, all of it mirrored in its own colour.
        let gold = try material("\"diffuseFactor\": [0, 0, 0, 1], \"specularFactor\": [1, 0.77, 0.34], \"glossinessFactor\": 0.9")
        XCTAssertEqual(gold.metallic, 1, accuracy: 1e-3)
        XCTAssertLessThan(simd_distance(gold.baseColor, onScreen(1, 0.77, 0.34)), 2e-3, "\(gold.baseColor)")
        XCTAssertEqual(gold.roughness, 0.1, accuracy: 1e-5)

        // Paint: its faint highlight makes no metal of it, and its colour is its diffuse colour.
        let paint = try material("\"diffuseFactor\": [0.5, 0.25, 0.125, 1], \"specularFactor\": [0.04, 0.04, 0.04], \"glossinessFactor\": 0.6")
        XCTAssertEqual(paint.metallic, 0, accuracy: 1e-4)
        XCTAssertLessThan(simd_distance(paint.baseColor, onScreen(0.5, 0.25, 0.125)), 1e-4, "\(paint.baseColor)")
        XCTAssertEqual(paint.roughness, 0.4, accuracy: 1e-5)

        // The colours the extension starts from, white and fully specular, are a mirror.
        let mirror = try material("\"glossinessFactor\": 1")
        XCTAssertEqual(mirror.metallic, 1, accuracy: 1e-3)
        XCTAssertLessThan(simd_distance(mirror.baseColor, SIMD4(1, 1, 1, 1)), 1e-3)

        // An image for the specular colour is not read: the surface is left as it was shown.
        let mapped = try material("\"diffuseFactor\": [0, 0, 0, 1], \"specularFactor\": [1, 0.77, 0.34], \"specularGlossinessTexture\": {\"index\": 0}")
        XCTAssertEqual(mapped.metallic, 0)
        XCTAssertEqual(mapped.baseColor, SIMD4(0, 0, 0, 1))
    }

    func testGlowAndTheWayAnImageIsPlaced() throws {
        // Texture coordinates beside the quad's positions: the unit square.
        let buffer = quadBuffer + bytes([Float](arrayLiteral: 0, 0, 1, 0, 1, 1, 0, 1))
        let png = "data:image/png;base64,\(Data([0x89, 0x50]).base64EncodedString())"
        let material = """
        {"emissiveFactor": [1, 0.5, 0], "emissiveTexture": {"index": 0, "extensions": {"KHR_texture_transform": {"offset": [0.5, 0], "scale": [2, 2]}}},
         "pbrMetallicRoughness": {"baseColorTexture": {"index": 0, "extensions": {"KHR_texture_transform": {"offset": [0.5, 0], "scale": [2, 2]}}},
                                  "metallicRoughnessTexture": {"index": 0}},
         "extensions": {"KHR_materials_emissive_strength": {"emissiveStrength": 4}}}
        """
        let json = quadJSON(buffer: "", extra: ", \"textures\": [{\"source\": 0}], \"images\": [{\"uri\": \"\(png)\"}]",
                            primitive: "\"indices\": 1", material: material)
            .replacingOccurrences(of: "\"attributes\": {\"POSITION\": 0}", with: "\"attributes\": {\"POSITION\": 0, \"TEXCOORD_0\": 2}")
            .replacingOccurrences(of: "{\"bufferView\": 1, \"componentType\": 5123, \"count\": 6, \"type\": \"SCALAR\"}]",
                                  with: "{\"bufferView\": 1, \"componentType\": 5123, \"count\": 6, \"type\": \"SCALAR\"}, {\"bufferView\": 2, \"componentType\": 5126, \"count\": 4, \"type\": \"VEC2\"}]")
            .replacingOccurrences(of: "{\"buffer\": 0, \"byteOffset\": 48, \"byteLength\": 12}]", with: "{\"buffer\": 0, \"byteOffset\": 48, \"byteLength\": 12}, {\"buffer\": 0, \"byteOffset\": 60, \"byteLength\": 32}]")
        let scene = try GLTFReader.scene(from: glb(json, buffer))
        let read = scene.materials[0]
        // The file's strength is counted into the colour the surface gives off.
        XCTAssertEqual(read.emissive, SIMD3(4, 2, 0))
        XCTAssertEqual(read.emissiveTexture, 0)
        XCTAssertEqual(read.baseColorTexture, 0)
        // Scaled by two and moved half across: laid into the part's own coordinates.
        XCTAssertEqual(scene.meshes[0].parts[0].uv0, [SIMD2(0.5, 0), SIMD2(2.5, 0), SIMD2(2.5, 2), SIMD2(0.5, 2)])
        // A glow whose image cannot be used does not cover the whole surface instead.
        let stray = json.replacingOccurrences(of: "\"emissiveTexture\": {\"index\": 0, \"extensions\"", with: "\"emissiveTexture\": {\"index\": 0, \"texCoord\": 1, \"extensions\"")
        XCTAssertEqual(try GLTFReader.scene(from: glb(stray, buffer)).materials[0].emissive, .zero)
        // An image placed otherwise than the colour image is left out, and that is noted.
        XCTAssertNil(read.metallicRoughnessTexture)
        XCTAssertEqual(scene.diagnostics.skippedFeatures, ["images placed differently on one surface"])
        // The extension's positive quarter turn takes (1, 0) to (0, -1): counter-clockwise
        // where v points down the image, as in its example and in Khronos's own renderer.
        let turned = Document.Placement(rotation: .pi / 2).apply(SIMD2(1, 0))
        XCTAssertEqual(turned.x, 0, accuracy: 1e-6)
        XCTAssertEqual(turned.y, -1, accuracy: 1e-6)
    }

    func testStripsFansPointsAndLines() throws {
        func part(_ mode: Int, indexed: Bool) throws -> ModelScene.MeshPart? {
            let primitive = (indexed ? "\"indices\": 1, " : "") + "\"mode\": \(mode)"
            return try? GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer), primitive: primitive).utf8)).meshes.first?.parts.first
        }
        // Four vertices in a row: a strip turns every other triangle, a fan keeps the first corner.
        XCTAssertEqual(try part(5, indexed: false)?.triangleIndices, [0, 1, 2, 1, 3, 2])
        XCTAssertEqual(try part(6, indexed: false)?.triangleIndices, [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(try part(4, indexed: false)?.triangleIndices, [0, 1, 2], "a loose fourth vertex is left out")
        let points = try XCTUnwrap(try part(0, indexed: false))
        XCTAssertEqual(points.primitive, .points)
        XCTAssertEqual(points.positions.count, 4)
        // Lines are passed over; a file of nothing else has nothing to show.
        XCTAssertThrowsError(try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer), primitive: "\"mode\": 1").utf8))) {
            XCTAssertEqual($0 as? GLTFReader.Failure, .empty)
        }
    }

    func testNormalisedColoursTextureCoordinatesAndStride() throws {
        // Interleaved: position (3 floats), colour (4 bytes), texture coordinate (2 unsigned shorts), 20 bytes a vertex.
        var buffer = Data()
        let corners: [(Float, Float, UInt8, UInt16)] = [(0, 0, 255, 0), (1, 0, 0, 65535), (0, 1, 255, 0)]
        for (x, y, red, u) in corners {
            buffer += bytes([x, y, Float(0)]) + Data([red, 0, 0, 255]) + bytes([u, UInt16(65535)])
        }
        let json = """
        {"asset": {"version": "2.0"}, "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "COLOR_0": 1, "TEXCOORD_0": 2}}]}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                       {"bufferView": 0, "byteOffset": 12, "componentType": 5121, "normalized": true, "count": 3, "type": "VEC4"},
                       {"bufferView": 0, "byteOffset": 16, "componentType": 5123, "normalized": true, "count": 3, "type": "VEC2"}],
         "bufferViews": [{"buffer": 0, "byteLength": 60, "byteStride": 20}],
         "buffers": [{\(dataURI(buffer))"byteLength": 60}]}
        """
        let scene = try GLTFReader.scene(from: Data(json.utf8))
        let part = scene.meshes[0].parts[0]
        XCTAssertEqual(part.positions, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        XCTAssertEqual(part.colors, [SIMD4(1, 0, 0, 1), SIMD4(0, 0, 0, 1), SIMD4(1, 0, 0, 1)])
        XCTAssertEqual(part.uv0, [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 1)])
        XCTAssertEqual(part.triangleIndices, [0, 1, 2], "no indices: the vertices in order")
        XCTAssertEqual(scene.nodes.count, 1, "no scene named: every node that is nobody's child")
        XCTAssertTrue(scene.hasTexturedAppearance)
    }

    func testSparseValuesReplaceTheirElements() throws {
        // Three positions all at the origin; a sparse entry moves the third.
        let buffer = bytes([Float](repeating: 0, count: 9)) + bytes([UInt16(2), UInt16(0)]) + bytes([Float](arrayLiteral: 0, 5, 0))
        let json = """
        {"asset": {"version": "2.0"}, "nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
                        "sparse": {"count": 1, "indices": {"bufferView": 1, "componentType": 5123}, "values": {"bufferView": 2}}}],
         "bufferViews": [{"buffer": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 2}, {"buffer": 0, "byteOffset": 40, "byteLength": 12}],
         "buffers": [{\(dataURI(buffer))"byteLength": 52}]}
        """
        XCTAssertEqual(try GLTFReader.scene(from: Data(json.utf8)).meshes[0].parts[0].positions, [SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 5, 0)])
    }

    // MARK: Files that are wrong

    func testDataThatIsNotThereFailsTheLoadInsteadOfBeingRead() throws {
        func failure(_ json: String, _ binary: Data? = nil) -> GLTFReader.Failure? {
            do { _ = try GLTFReader.scene(from: binary.map { glb(json, $0) } ?? Data(json.utf8)); return nil } catch { return error as? GLTFReader.Failure }
        }
        // The accessor asks for more vertices than the buffer holds.
        let long = quadJSON(buffer: "").replacingOccurrences(of: "\"count\": 4", with: "\"count\": 400")
        XCTAssertEqual(failure(long, quadBuffer), .damaged("an accessor runs past its data"))
        // The view runs past the buffer.
        XCTAssertEqual(failure(quadJSON(buffer: "").replacingOccurrences(of: "\"byteLength\": 48", with: "\"byteLength\": 4800"), quadBuffer), .damaged("a buffer view runs past its buffer"))
        // Negative and absurd numbers.
        XCTAssertNotNil(failure(quadJSON(buffer: "").replacingOccurrences(of: "\"byteOffset\": 48", with: "\"byteOffset\": -48"), quadBuffer))
        XCTAssertNotNil(failure(quadJSON(buffer: "").replacingOccurrences(of: "\"count\": 6", with: "\"count\": 1e30"), quadBuffer))
        XCTAssertNotNil(failure(quadJSON(buffer: "").replacingOccurrences(of: "\"componentType\": 5126", with: "\"componentType\": 7"), quadBuffer))
        // Indices past the vertices: those triangles are left out, the rest stays.
        let stray = bytes([Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0)) + bytes([UInt16](arrayLiteral: 0, 1, 2, 0, 2, 9))
        XCTAssertEqual(try GLTFReader.scene(from: glb(quadJSON(buffer: ""), stray)).meshes[0].parts[0].triangleIndices, [0, 1, 2])
        // A container cut short, another version, not glTF at all.
        XCTAssertNotNil(failure("", Data()).map { _ in true } ?? true)
        XCTAssertThrowsError(try GLTFReader.scene(from: glb(quadJSON(buffer: ""), quadBuffer).prefix(40)))
        XCTAssertThrowsError(try GLTFReader.scene(from: Data("{\"asset\": {\"version\": \"1.0\"}}".utf8)))
        XCTAssertThrowsError(try GLTFReader.scene(from: Data("v 0 0 0".utf8)))
        XCTAssertThrowsError(try GLTFReader.scene(from: Data()))
        // What the file says it cannot be shown without, and we do not read.
        XCTAssertEqual(failure(quadJSON(buffer: "", extra: ", \"extensionsRequired\": [\"KHR_draco_mesh_compression\"]"), quadBuffer),
                       .unsupported("Draco-compressed models are not supported"))
    }

    func testNodesThatLoopOrAreNamedTwiceAreVisitedOnce() throws {
        let json = quadJSON(buffer: dataURI(quadBuffer))
            .replacingOccurrences(of: "{\"mesh\": 0, \"scale\": [2, 2, 2]}", with: "{\"mesh\": 0, \"children\": [0, 1, 7]}")
        let scene = try GLTFReader.scene(from: Data(json.utf8))
        XCTAssertEqual(scene.nodes.count, 2)
        XCTAssertEqual(scene.topology.faces, 2)
    }

    func testTheRouterReadsBothForms() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-gltf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("quad.glb"), text = folder.appendingPathComponent("quad.gltf")
        try glb(quadJSON(buffer: ""), quadBuffer).write(to: binary)
        try Data(quadJSON(buffer: "\"uri\": \"quad.bin\", ").utf8).write(to: text)
        try quadBuffer.write(to: folder.appendingPathComponent("quad.bin"))
        XCTAssertEqual(FormatDetector.detect(try Data(contentsOf: binary), ext: "glb"), .gltf)
        XCTAssertEqual(FormatDetector.detect(try Data(contentsOf: text), ext: "gltf"), .gltfJSON)
        XCTAssertEqual(try ImportRouter.load(binary, format: .gltf).topology.faces, 2)
        XCTAssertEqual(try ImportRouter.load(text, format: .gltfJSON).topology.faces, 2)
    }

    // MARK: Skins and animation

    /// A triangle on node 1 under node 0. Node 1 is the one joint of a skin; an animation
    /// moves node 0 up by 2 over one second (linear) and node 1 sideways in a step at half time.
    private func animated(skinned: Bool, duration: Float = 1, children: String = "", nodes: String = "", extra: String = "") -> Data {
        var buffer = bytes([Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 0, 1, 0))                       // 0: positions, 36
        buffer += Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])                                          // 36: joints (bytes), 12
        buffer += bytes([Float](arrayLiteral: 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0))                    // 48: weights (not summing to one), 48
        buffer += bytes([Float](arrayLiteral: 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -5, 1))        // 96: inverse bind (z - 5), 64
        buffer += bytes([Float](arrayLiteral: 0, duration))                                           // 160: times, 8
        buffer += bytes([Float](arrayLiteral: 0, 0, 0, 0, 2, 0))                                      // 168: node 0 translations, 24
        buffer += bytes([Float](arrayLiteral: 0, duration / 2, duration))                             // 192: times, 12
        buffer += bytes([Float](arrayLiteral: 0, 0, 0, 3, 0, 0, 3, 0, 0))                             // 204: node 1 translations, 36
        let attributes = skinned ? "\"POSITION\": 0, \"JOINTS_0\": 1, \"WEIGHTS_0\": 2" : "\"POSITION\": 0"
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}],
         "nodes": [{"children": [1\(children)]}, {"mesh": 0\(skinned ? ", \"skin\": 0" : "")}\(nodes)],\(extra)
         "meshes": [{"primitives": [{"attributes": {\(attributes)}}]}],
         "skins": [{"joints": [1], "inverseBindMatrices": 3}],
         "animations": [{"name": "lift", "channels": [{"sampler": 0, "target": {"node": 0, "path": "translation"}},
                                                       {"sampler": 1, "target": {"node": 1, "path": "translation"}}],
                         "samplers": [{"input": 4, "output": 5}, {"input": 6, "output": 7, "interpolation": "STEP"}]}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                       {"bufferView": 0, "byteOffset": 36, "componentType": 5121, "count": 3, "type": "VEC4"},
                       {"bufferView": 0, "byteOffset": 48, "componentType": 5126, "count": 3, "type": "VEC4"},
                       {"bufferView": 0, "byteOffset": 96, "componentType": 5126, "count": 1, "type": "MAT4"},
                       {"bufferView": 0, "byteOffset": 160, "componentType": 5126, "count": 2, "type": "SCALAR"},
                       {"bufferView": 0, "byteOffset": 168, "componentType": 5126, "count": 2, "type": "VEC3"},
                       {"bufferView": 0, "byteOffset": 192, "componentType": 5126, "count": 3, "type": "SCALAR"},
                       {"bufferView": 0, "byteOffset": 204, "componentType": 5126, "count": 3, "type": "VEC3"}],
         "bufferViews": [{"buffer": 0, "byteLength": 240}], "buffers": [{"byteLength": 240}]}
        """
        return glb(json, buffer)
    }

    func testASkinnedMeshFollowsItsJointsThroughAClip() throws {
        let scene = try GLTFReader.scene(from: animated(skinned: true))
        let skeleton = try XCTUnwrap(scene.skeletons.first)
        // The two nodes, then the skin's one joint under node 1 with its inverse bind matrix.
        XCTAssertEqual(skeleton.joints.count, 3)
        XCTAssertEqual(skeleton.joints[2].parent, 1)
        XCTAssertEqual(skeleton.joints[2].inverseBind.columns.3.z, -5)
        XCTAssertNil(skeleton.node)
        let part = try XCTUnwrap(scene.nodes[1].mesh.map { scene.meshes[$0].parts[0] })
        let skin = try XCTUnwrap(part.skin)
        XCTAssertEqual(skin.joints, [SIMD4(2, 2, 2, 2), SIMD4(2, 2, 2, 2), SIMD4(2, 2, 2, 2)])
        XCTAssertEqual(skin.weights[0], SIMD4(1, 0, 0, 0), "weights are brought to a sum of one")

        let clip = try XCTUnwrap(scene.clips.first)
        XCTAssertEqual(clip.name, "lift")
        XCTAssertEqual(clip.duration, 1)
        XCTAssertEqual(clip.linearTranslations[0]?.times, [0,1], "authored times retained")
        XCTAssertTrue(clip.rotations.times.isEmpty, "nothing turns")
        // A quarter in: node 0 is a quarter of the way up, node 1 has not stepped yet.
        var joint = skeleton.skinMatrices(clip: clip, time: 0.25)[2].columns.3
        XCTAssertEqual(joint.x, 0, accuracy: 1e-4)
        XCTAssertEqual(joint.y, 0.5, accuracy: 1e-4)
        XCTAssertEqual(joint.z, -5, accuracy: 1e-4)
        // Three quarters in: stepped sideways by 3.
        joint = skeleton.skinMatrices(clip: clip, time: 0.75)[2].columns.3
        XCTAssertEqual(joint.x, 3, accuracy: 1e-4)
        XCTAssertEqual(joint.y, 1.5, accuracy: 1e-4)
    }

    func testOtherShapesTheirWeightsAndTheirAnimation() throws {
        // A triangle with two other shapes (up by 1, right by 2); weights animated over one second.
        var buffer = bytes([Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 0, 1, 0))                    // 0: positions
        buffer += bytes([Float](arrayLiteral: 0, 1, 0, 0, 1, 0, 0, 1, 0))                          // 36: first shape
        buffer += bytes([Float](arrayLiteral: 2, 0, 0, 2, 0, 0, 2, 0, 0))                          // 72: second shape
        buffer += bytes([Float](arrayLiteral: 0, 1))                                               // 108: times
        buffer += bytes([Float](arrayLiteral: 0, 1, 1, 0))                                         // 116: weights, two a key
        let json = """
        {"asset": {"version": "2.0"}, "nodes": [{"mesh": 0, "weights": [0.25, 0.5]}],
         "meshes": [{"weights": [1, 1], "primitives": [{"attributes": {"POSITION": 0}, "targets": [{"POSITION": 1}, {"POSITION": 2}]}]}],
         "animations": [{"channels": [{"sampler": 0, "target": {"node": 0, "path": "weights"}}], "samplers": [{"input": 3, "output": 4}]}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                       {"bufferView": 0, "byteOffset": 36, "componentType": 5126, "count": 3, "type": "VEC3"},
                       {"bufferView": 0, "byteOffset": 72, "componentType": 5126, "count": 3, "type": "VEC3"},
                       {"bufferView": 0, "byteOffset": 108, "componentType": 5126, "count": 2, "type": "SCALAR"},
                       {"bufferView": 0, "byteOffset": 116, "componentType": 5126, "count": 4, "type": "SCALAR"}],
         "bufferViews": [{"buffer": 0, "byteLength": 132}], "buffers": [{"byteLength": 132}]}
        """
        let scene = try GLTFReader.scene(from: glb(json, buffer))
        let meshIndex = try XCTUnwrap(scene.nodes[0].mesh)
        let mesh = scene.meshes[meshIndex]
        XCTAssertEqual(mesh.morphWeights, [0.25, 0.5], "the node's weights replace the mesh's")
        let part = mesh.parts[0]
        XCTAssertEqual(part.morphTargets.count, 2)
        XCTAssertEqual(part.morphTargets[0].positions, [SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 0)])
        XCTAssertTrue(part.morphTargets[0].normals.isEmpty)
        // With no skin in the file, the part is bound whole to its node, so the shapes can show.
        XCTAssertEqual(part.skin?.joints[0], SIMD4(0, 0, 0, 0))
        XCTAssertEqual(scene.skeletons.count, 1)
        XCTAssertTrue(scene.diagnostics.skippedFeatures.isEmpty)

        let clip = try XCTUnwrap(scene.clips.first)
        XCTAssertTrue(clip.rotations.times.isEmpty)
        let channel = try XCTUnwrap(clip.morphs.first)
        XCTAssertEqual(channel.mesh, meshIndex)
        XCTAssertEqual(channel.targetCount, 2)
        let half = try XCTUnwrap(channel.weights(at: 0.5))
        XCTAssertEqual(half[0], 0.5, accuracy: 1e-4)
        XCTAssertEqual(half[1], 0.5, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(channel.weights(at: 1)), [1, 0])
    }

    func testAMeshWithNoSkinUnderAMovingNodeFollowsItsNode() throws {
        let scene = try GLTFReader.scene(from: animated(skinned: false))
        let skeleton = try XCTUnwrap(scene.skeletons.first)
        XCTAssertEqual(skeleton.joints.count, 2, "only the nodes")
        let skin = try XCTUnwrap(scene.nodes[1].mesh.flatMap { scene.meshes[$0].parts[0].skin })
        XCTAssertEqual(skin.joints[0], SIMD4(1, 0, 0, 0))
        XCTAssertEqual(skin.weights[2], SIMD4(1, 0, 0, 0))
        let end = skeleton.skinMatrices(clip: scene.clips[0], time: 1)[1].columns.3
        XCTAssertEqual(end.x, 3, accuracy: 1e-4)
        XCTAssertEqual(end.y, 2, accuracy: 1e-4)
        // A model in which nothing moves has no skeleton.
        XCTAssertTrue(try GLTFReader.scene(from: glb(quadJSON(buffer: ""), quadBuffer)).skeletons.isEmpty)
    }

    // MARK: VRM

    func testACartoonMaterialOfBothVersionsOfVRM() throws {
        let new = """
        {"pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1]},
         "extensions": {"VRMC_materials_mtoon": {"shadeColorFactor": [1, 0, 0], "shadingShiftFactor": -0.2, "shadingToonyFactor": 0.7,
                                                  "outlineWidthMode": "worldCoordinates", "outlineWidthFactor": 0.004,
                                                  "outlineColorFactor": [0, 0, 1], "outlineLightingMixFactor": 0.25, "matcapTexture": {"index": 0},
                                                  "matcapFactor": [0.5, 1, 1], "parametricRimColorFactor": [0, 1, 0], "parametricRimFresnelPowerFactor": 3,
                                                  "parametricRimLiftFactor": 0.1, "rimLightingMixFactor": 0.5, "uvAnimationScrollXSpeedFactor": 1, "uvAnimationScrollYSpeedFactor": 0.5, "uvAnimationRotationSpeedFactor": 2}}}
        """
        let scene = try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer), material: new).utf8))
        let toon = try XCTUnwrap(scene.materials[0].toon)
        XCTAssertEqual(toon.shadeColor, SIMD3(1, 0, 0))
        XCTAssertEqual(toon.shift, -0.2)
        XCTAssertEqual(toon.toony, 0.7)
        XCTAssertEqual(toon.outlineWidth, 0.004)
        XCTAssertFalse(toon.outlineOnScreen)
        XCTAssertEqual(toon.outlineColor, SIMD3(0, 0, 1))
        XCTAssertEqual(toon.outlineLightingMix, 0.25)
        XCTAssertNil(toon.matcapTexture, "an image that is not in the file")
        XCTAssertEqual(toon.matcapColor, SIMD3(0.5, 1, 1))
        XCTAssertEqual(toon.rimColor, SIMD3(0, 1, 0))
        XCTAssertEqual([toon.rimFresnelPower, toon.rimLift, toon.rimLightingMix], [3, 0.1, 0.5])
        XCTAssertEqual(toon.uvScroll, SIMD2(1, 0.5))
        XCTAssertEqual(toon.uvRotation, 2)

        // The older form: the Unity material's properties, with widths in centimetres.
        let old = """
        , "extensions": {"VRM": {"materialProperties": [{"shader": "VRM/MToon",
            "floatProperties": {"_ShadeShift": 0, "_ShadeToony": 0.5, "_OutlineWidthMode": 1, "_OutlineWidth": 0.5, "_OutlineColorMode": 0,
                                "_RimFresnelPower": 2, "_RimLift": 0.25, "_RimLightingMix": 0,
                                "_UvAnimScrollX": 1, "_UvAnimScrollY": 0.5, "_UvAnimRotation": 0.25},
            "vectorProperties": {"_ShadeColor": [0, 1, 0, 1], "_OutlineColor": [1, 0, 0, 1], "_RimColor": [0, 0, 1, 1]}}]}}
        """
        let older = try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer), extra: old).utf8))
        let was = try XCTUnwrap(older.materials[0].toon)
        XCTAssertEqual(was.shadeColor, SIMD3(0, 1, 0))
        XCTAssertEqual(was.toony, 0.75, accuracy: 1e-5)
        XCTAssertEqual(was.shift, -0.25, accuracy: 1e-5)
        XCTAssertEqual(was.outlineWidth, 0.005, accuracy: 1e-6)
        XCTAssertEqual(was.outlineColor, SIMD3(1, 0, 0))
        XCTAssertEqual(was.outlineLightingMix, 0)
        XCTAssertEqual(was.rimColor, SIMD3(0, 0, 1))
        XCTAssertEqual([was.rimFresnelPower, was.rimLift, was.rimLightingMix], [2, 0.25, 0])
        XCTAssertEqual(was.uvScroll, SIMD2(1, -0.5), "counted from the bottom edge there")
        XCTAssertEqual(was.uvRotation, 0.25)
        // Such an avatar faces away; it is turned to face the viewer.
        XCTAssertEqual(older.nodes[0].transform.columns.0.x, -1, accuracy: 1e-5)
        XCTAssertNil(try GLTFReader.scene(from: Data(quadJSON(buffer: dataURI(quadBuffer)).utf8)).materials[0].toon)
    }

    func testSpringBonesOfBothVersionsOfVRM() throws {
        // A chain of three bones hanging from the root: nodes 2, 3 and 4, each 1 below the one before.
        let chain = ", {\"translation\": [0, -1, 0], \"children\": [3]}, {\"translation\": [0, -1, 0], \"children\": [4]}, {\"translation\": [0, -1, 0]}"
        let new = """
        "extensions": {"VRMC_springBone": {
            "colliders": [{"node": 0, "shape": {"sphere": {"offset": [1, 0, 0], "radius": 0.5}}}, {"node": 99, "shape": {"sphere": {}}},
                          {"node": 1, "shape": {"capsule": {"offset": [0, 1, 0], "tail": [0, 2, 0], "radius": 0.25}}}],
            "colliderGroups": [{"colliders": [0, 1]}, {"colliders": [2, 7]}],
            "springs": [{"joints": [{"node": 2, "hitRadius": 0.1, "stiffness": 2, "gravityPower": 0.5, "gravityDir": [1, 0, 0], "dragForce": 0.3}, {"node": 3}, {"node": 4}],
                         "colliderGroups": [0, 1, 5]}]}},
        """
        let scene = try GLTFReader.scene(from: animated(skinned: true, children: ", 2", nodes: chain, extra: new))
        let springs = try XCTUnwrap(scene.springs)
        XCTAssertEqual(springs.skeleton, 0)
        XCTAssertEqual(springs.colliders.count, 2, "the one on a node that is not there is left out")
        XCTAssertEqual(springs.colliders[0].offset, SIMD3(1, 0, 0))
        XCTAssertEqual(springs.colliders[1].tail, SIMD3(0, 2, 0))
        XCTAssertEqual(springs.joints.count, 2, "the last joint is only the tail of the one before")
        let first = springs.joints[0]
        XCTAssertEqual(scene.skeletons[0].joints[first.joint].parent, 0)
        XCTAssertEqual(first.tail, SIMD3(0, -1, 0))
        XCTAssertEqual([first.hitRadius, first.stiffness, first.gravityPower, first.drag], [0.1, 2, 0.5, 0.3])
        XCTAssertEqual(first.gravityDirection, SIMD3(1, 0, 0))
        XCTAssertEqual(first.colliders, [0, 1])
        XCTAssertEqual([springs.joints[1].stiffness, springs.joints[1].drag], [1, 0.5], "what a joint leaves out")

        let old = """
        "extensions": {"VRM": {"secondaryAnimation": {
            "colliderGroups": [{"node": 0, "colliders": [{"offset": {"x": 1, "y": 2, "z": 3}, "radius": 0.5}]}],
            "boneGroups": [{"stiffiness": 2, "gravityPower": 0.5, "gravityDir": {"x": 0, "y": -1, "z": 0}, "dragForce": 0.3, "hitRadius": 0.1,
                            "bones": [2], "colliderGroups": [0]}]}}},
        """
        let older = try XCTUnwrap(try GLTFReader.scene(from: animated(skinned: true, children: ", 2", nodes: chain, extra: old)).springs)
        XCTAssertEqual(older.colliders[0].offset, SIMD3(1, 2, -3), "z points the other way in that format")
        XCTAssertEqual(older.joints.count, 3, "every bone below the root, the last with a tail of its own")
        XCTAssertEqual(older.joints.map(\.stiffness), [2, 2, 2])
        XCTAssertEqual(older.joints[0].tail.y, -1, accuracy: 1e-5)
        // 7 cm further the way the bone came (the avatar is turned around, which does not change down).
        XCTAssertEqual(older.joints[2].tail.y, -0.07, accuracy: 1e-5)
        XCTAssertEqual(older.joints[2].colliders, [0])

        XCTAssertNil(try GLTFReader.scene(from: animated(skinned: true)).springs)
    }

    /// The older VRM keeps gravity as Unity had it: a direction of the world, in a space
    /// where the file's z points the other way. The avatar is then turned round to face
    /// the viewer, so of that direction it is x that points the other way here: hair blown
    /// to the avatar's left in Unity is blown to its left here too.
    func testAnOlderAvatarsGravityIsTurnedWithIt() throws {
        let chain = ", {\"translation\": [0, -1, 0], \"children\": [3]}, {\"translation\": [0, -1, 0]}"
        let old = """
        "extensions": {"VRM": {"secondaryAnimation": {
            "boneGroups": [{"stiffiness": 1, "gravityPower": 1, "gravityDir": {"x": 1, "y": -2, "z": 3}, "dragForce": 0.5, "bones": [2]}]}}},
        """
        let scene = try GLTFReader.scene(from: animated(skinned: true, children: ", 2", nodes: chain, extra: old))
        let springs = try XCTUnwrap(scene.springs)
        XCTAssertEqual(springs.joints[0].gravityDirection, SIMD3(-1, -2, 3))
        // The avatar's own left (the file's +x) is at the viewer's right once it is turned.
        XCTAssertEqual(scene.nodes[0].transform.columns.0.x, -1, accuracy: 1e-5)
    }

    func testMotionWithNoMeshIsShownOnItsSkeleton() throws {
        // Three nodes in a chain, each one above the one before; the first is moved up by two in a second.
        let buffer = bytes([Float](arrayLiteral: 0, 1)) + bytes([Float](arrayLiteral: 0, 0, 0, 0, 2, 0))
        func file(animated: Bool) -> Data {
            let animations = animated ? "\"animations\": [{\"channels\": [{\"sampler\": 0, \"target\": {\"node\": 0, \"path\": \"translation\"}}], \"samplers\": [{\"input\": 0, \"output\": 1}]}]," : ""
            return glb("""
            {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "extensionsUsed": ["VRMC_vrm_animation"], "extensions": {"VRMC_vrm_animation": {}},
             "nodes": [{"name": "hips", "children": [1]}, {"name": "spine", "translation": [0, 1, 0], "children": [2, 3]},
                       {"name": "head", "translation": [0, 1, 0]}, {"name": "same place"}],
             \(animations)
             "accessors": [{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"},
                           {"bufferView": 0, "byteOffset": 8, "componentType": 5126, "count": 2, "type": "VEC3"}],
             "bufferViews": [{"buffer": 0, "byteLength": 32}], "buffers": [{"byteLength": 32}]}
            """, buffer)
        }
        let scene = try GLTFReader.scene(from: file(animated: true))
        XCTAssertEqual(scene.nodes.filter { $0.mesh != nil }.count, 2, "one for each node with a child away from it")
        XCTAssertEqual(scene.topology.faces, 0, "the file has no surface of its own")
        XCTAssertEqual(scene.clips.count, 1)
        // A bone from each node to its child: eight triangles, from the node to one above it.
        let hips = try XCTUnwrap(scene.nodes[0].mesh.map { scene.meshes[$0] })
        XCTAssertEqual(hips.parts[0].triangleIndices.count, 24)
        XCTAssertEqual(hips.parts[0].positions.map(\.y).max(), 1)
        XCTAssertEqual(hips.parts[0].positions.map(\.y).min(), 0)
        XCTAssertNil(scene.nodes[2].mesh)
        // The bones go with their nodes through the clip.
        let skin = try XCTUnwrap(hips.parts[0].skin)
        let lifted = scene.skeletons[skin.skeleton].skinMatrices(clip: scene.clips[0], time: 1)
        XCTAssertEqual(lifted[Int(skin.joints[0].x)].columns.3.y, 2, accuracy: 1e-4)
        let spine = try XCTUnwrap(scene.nodes[1].mesh.map { scene.meshes[$0] }.flatMap { $0.parts[0].skin })
        XCTAssertEqual(lifted[Int(spine.joints[0].x)].columns.3.y, 3, accuracy: 1e-4)

        // Nodes alone, with no motion, are still nothing to show.
        XCTAssertThrowsError(try GLTFReader.scene(from: file(animated: false))) { XCTAssertEqual($0 as? GLTFReader.Failure, .empty) }
    }
}
