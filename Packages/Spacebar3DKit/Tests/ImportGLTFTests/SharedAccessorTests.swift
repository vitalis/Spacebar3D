import Foundation
import ModelCore
import simd
import XCTest
@testable import ImportGLTF

/// Reading a glTF must not repeat work for what the file shares.
///
/// Expects two internal stored properties on `Document` (read through `Mirror`):
/// - `accessorDecodeCount: Int`: how many times an accessor's bytes were really decoded
///   into numbers (floats, wholes, sparse included). An accessor asked for again is
///   answered from what was decoded, and does not count.
/// - `viewBytesCopied: Int`: how many bytes were copied out of a buffer to make a buffer
///   view or accessor readable. A view is a window onto its buffer: this stays near zero.
final class SharedAccessorTests: XCTestCase {
    private let padding = 1_000_000

    /// One buffer, one big buffer view over all of it (a megabyte, mostly padding), with the
    /// vertex lists and the index lists of four triangles inside at offsets.
    /// Accessors: 0 POSITION (4 x vec3), 1 NORMAL (4 x vec3), 2 TEXCOORD_0 (4 x vec2),
    /// 3...6 one triangle each (uint16 x 3).
    private func file(meshes: Int = 1, primitivesPerMesh: Int = 4) -> (data: Data, vertexAccessors: Int) {
        let positions: [Float] = [0,0,0, 1,0,0, 1,1,0, 0,1,0]
        let normals: [Float] = [0,0,1, 0,0,1, 0,0,1, 0,0,1]
        let uvs: [Float] = [0,0, 1,0, 1,1, 0,1]
        let triangles: [[UInt16]] = [[0, 1, 2], [0, 2, 3], [1, 2, 3], [0, 1, 3]]
        var bytes = Data()
        for values in [positions, normals, uvs] { bytes.append(values.withUnsafeBytes { Data($0) }) }   // 48 + 48 + 32
        for t in triangles { bytes.append(t.withUnsafeBytes { Data($0) }) }                            // 4 x 6, from 128
        bytes.append(Data(count: padding - bytes.count))
        let accessors = """
        {"bufferView":0,"byteOffset":0,"componentType":5126,"count":4,"type":"VEC3"},
        {"bufferView":0,"byteOffset":48,"componentType":5126,"count":4,"type":"VEC3"},
        {"bufferView":0,"byteOffset":96,"componentType":5126,"count":4,"type":"VEC2"},
        {"bufferView":0,"byteOffset":128,"componentType":5123,"count":3,"type":"SCALAR"},
        {"bufferView":0,"byteOffset":134,"componentType":5123,"count":3,"type":"SCALAR"},
        {"bufferView":0,"byteOffset":140,"componentType":5123,"count":3,"type":"SCALAR"},
        {"bufferView":0,"byteOffset":146,"componentType":5123,"count":3,"type":"SCALAR"}
        """
        let primitives = (0..<primitivesPerMesh).map { #"{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2},"indices":\#(3 + $0 % 4)}"# }.joined(separator: ",")
        let meshList = (0..<meshes).map { _ in #"{"primitives":[\#(primitives)]}"# }.joined(separator: ",")
        let nodes = (0..<meshes).map { #"{"mesh":\#($0)}"# }.joined(separator: ",")
        let json = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[\((0..<meshes).map(String.init).joined(separator: ","))]}],"nodes":[\(nodes)],
         "meshes":[\(meshList)],"accessors":[\(accessors)],
         "bufferViews":[{"buffer":0,"byteLength":\(padding)}],
         "buffers":[{"byteLength":\(padding),"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}]}
        """
        return (Data(json.utf8), 3)
    }

    private func counter(_ name: String, _ document: Document, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let field = Mirror(reflecting: document).children.first { $0.label == name }
        return try XCTUnwrap(field?.value as? Int, "Document has no \(name): Int", file: file, line: line)
    }

    /// A model of several materials is several primitives over one list of vertices. Each
    /// primitive decoded the shared positions, normals and texture coordinates again, so a
    /// big model took several times as long to open as it needed to.
    func testPrimitivesSharingVertexListsDecodeThemOnce() throws {
        var document = try Document(data: file().data, sidecars: nil)
        let scene = try document.scene()
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 4)
        // Three vertex lists once, four index lists once each.
        XCTAssertEqual(try counter("accessorDecodeCount", document), 7, "one decode for each accessor, not each use")
    }

    /// The same, when the primitives are in different meshes of the file.
    func testMeshesSharingVertexListsDecodeThemOnce() throws {
        var document = try Document(data: file(meshes: 3, primitivesPerMesh: 4).data, sidecars: nil)
        let scene = try document.scene()
        XCTAssertEqual(scene.meshes.count, 3)
        XCTAssertEqual(try counter("accessorDecodeCount", document), 7)
    }

    /// Reading an accessor cut its whole buffer view out of the buffer (a copy as big as the
    /// view, for every accessor read): a file with one big view copied it for every attribute
    /// of every primitive. The view here is a megabyte.
    func testReadingAnAccessorDoesNotCopyItsBufferView() throws {
        var document = try Document(data: file().data, sidecars: nil)
        _ = try document.scene()
        let copied = try counter("viewBytesCopied", document)
        XCTAssertLessThan(copied, padding / 100, "copied \(copied) bytes out of a \(padding)-byte view")
    }

    /// Guard: sharing must not change what is read. Every primitive keeps its own indices and
    /// gets the full vertex lists, and the numbers are the file's.
    func testSharedDecodingGivesEveryPrimitiveItsOwnCorrectData() throws {
        let scene = try GLTFReader.scene(from: file(meshes: 2).data)
        XCTAssertEqual(scene.meshes.count, 2)
        let expected: [[UInt32]] = [[0, 1, 2], [0, 2, 3], [1, 2, 3], [0, 1, 3]]
        for mesh in scene.meshes {
            XCTAssertEqual(mesh.parts.map(\.triangleIndices), expected)
            for part in mesh.parts {
                XCTAssertEqual(part.positions, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)])
                XCTAssertEqual(part.normals, [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4))
                XCTAssertEqual(part.uv0, [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
            }
        }
    }

    /// Guard: changing one primitive's data (a texture placement turning its coordinates)
    /// must not leak into another that shares the list. Two materials, one with a
    /// KHR_texture_transform offset, over the same texture coordinates.
    func testAPrimitiveThatMovesItsTextureCoordinatesDoesNotMoveItsNeighbours() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: file(primitivesPerMesh: 2).data) as? [String: Any])
        var meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        var primitives = try XCTUnwrap(meshes[0]["primitives"] as? [[String: Any]])
        primitives[1]["material"] = 0
        meshes[0]["primitives"] = primitives
        json["meshes"] = meshes
        json["materials"] = [["pbrMetallicRoughness": ["baseColorTexture": ["index": 0, "extensions": ["KHR_texture_transform": ["offset": [0.5, 0.0]]]]]]]
        json["extensionsUsed"] = ["KHR_texture_transform"]
        json["textures"] = [["source": 0]]
        // A 1 x 1 PNG.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        json["images"] = [["uri": "data:image/png;base64,\(png)"]]
        let scene = try GLTFReader.scene(from: JSONSerialization.data(withJSONObject: json))
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].uv0.first, SIMD2(0, 0), "the primitive with no material keeps the file's coordinates")
        XCTAssertEqual(try XCTUnwrap(parts[1].uv0.first).x, 0.5, accuracy: 1e-6, "the transformed one is moved")
    }
}
