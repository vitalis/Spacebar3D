import Foundation
import ModelCore
import ImportGLTF
import simd
import XCTest

final class TangentReadingTests: XCTestCase {
    /// A file's own tangents (xyz the tangent, w the handedness) were dropped on import, and
    /// a normal map baked against them was laid on by a frame guessed from the texture
    /// coordinates instead. Expects `ModelScene.MeshPart.tangents: [SIMD4<Float>]`.
    func testAFilesTangentsAreKeptWithTheirHandedness() throws {
        let positions: [Float] = [0,0,0, 1,0,0, 0,1,0]
        let normals: [Float] = [0,0,1, 0,0,1, 0,0,1]
        let tangents: [Float] = [1,0,0,1, 0,1,0,-1, 0,0,1,1]
        var bytes = Data()
        for values in [positions, normals, tangents] { bytes.append(values.withUnsafeBytes { Data($0) }) }
        let json = """
        {"asset":{"version":"2.0"},"nodes":[{"mesh":0}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TANGENT":2}}]}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
                      {"bufferView":2,"componentType":5126,"count":3,"type":"VEC4"}],
         "bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36},{"buffer":0,"byteOffset":72,"byteLength":48}],
         "buffers":[{"byteLength":120,"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}]}
        """
        let scene = try GLTFReader.scene(from: Data(json.utf8))
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        // Read by name so this file compiles before the field exists, and fails instead.
        let field = Mirror(reflecting: part).children.first { $0.label == "tangents" }
        let read = try XCTUnwrap(field?.value as? [SIMD4<Float>], "MeshPart has no tangents: [SIMD4<Float>]")
        XCTAssertEqual(read, [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, -1), SIMD4(0, 0, 1, 1)])
    }
}
