import Foundation
import ImportSTL
import ModelCore
import simd
import XCTest

/// A binary STL holds Float32, so its own precision is the limit: a corner four million units
/// out can only be on a half-unit step in the file. What the file does hold exactly (here,
/// corners half a unit apart that sit on those steps) must survive being turned upright by
/// the node and moved to the origin.
final class FarBinarySTLTests: XCTestCase {
    private func binarySTL(_ triangles: [[SIMD3<Float>]]) -> Data {
        var data = Data(count: 80)
        withUnsafeBytes(of: UInt32(triangles.count).littleEndian) { data.append(contentsOf: $0) }
        for t in triangles {
            let n = simd_normalize(simd_cross(t[1] - t[0], t[2] - t[0]))
            for v in [n] + t { for c in [v.x, v.y, v.z] { withUnsafeBytes(of: c.bitPattern.littleEndian) { data.append(contentsOf: $0) } } }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    /// The first three corners, where the scene puts them, in Float as `ModelScene.bounds` and
    /// the renderer's matrices work it out.
    private func worldCorners(_ scene: ModelScene) -> [SIMD3<Double>] {
        let m = scene.worldTransform(of: 0)
        return scene.meshes[0].parts[0].positions.prefix(3).map { p in
            let w = m * SIMD4(p, 1)
            return SIMD3(Double(w.x), Double(w.y), Double(w.z))
        }
    }

    /// A part saved from a survey, a half unit across, four million units out, came out with
    /// edges of 0.5 that were 0.4 to 0.6 long once it was turned upright: the node's turn
    /// (a Float matrix) was applied to corners millions out before the middle was taken off.
    func testABinarySTLFarFromTheOriginKeepsEdgesTheFileHoldsExactly() throws {
        let a = SIMD3<Float>(4_194_304, 2_097_152, 1_048_576)
        let data = binarySTL([[a, a + SIMD3(0.5, 0, 0), a + SIMD3(0, 0.5, 0)]])
        let scene = try STLReader.scene(from: data).movedNearTheOrigin()
        let w = worldCorners(scene)
        print("P3D-FARSTL edges \(simd_distance(w[0], w[1])) \(simd_distance(w[0], w[2])) \(simd_distance(w[1], w[2])) first corner \(w[0])")
        XCTAssertEqual(simd_distance(w[0], w[1]), 0.5, accuracy: 1e-3)
        XCTAssertEqual(simd_distance(w[0], w[2]), 0.5, accuracy: 1e-3)
        XCTAssertEqual(simd_distance(w[1], w[2]), 0.5 * 2.0.squareRoot(), accuracy: 1e-3)
        XCTAssertLessThan(w.map { simd_reduce_max(simd_abs($0)) }.max()!, 1, "the model is at its own middle")
    }
}
