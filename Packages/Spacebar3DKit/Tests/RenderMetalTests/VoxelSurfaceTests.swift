import Metal
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// The cubes the Voxel Art style makes of a model's surface.
final class VoxelSurfaceTests: XCTestCase {
    /// A cube one unit wide about the origin, as the Voxel Art style shows it.
    private func voxels() throws -> [GPUScene.Part] {
        let corners: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
        let quads: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
        var part = ModelScene.MeshPart()
        part.positions = corners.map { $0 / 2 }
        part.triangleIndices = quads.flatMap { [$0[0], $0[1], $0[2], $0[0], $0[2], $0[3]] }
        part.faceted = true
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return try MetalRenderer().makeScene(scene).partsForVoxels()
    }

    private func positions(of part: GPUScene.Part) -> [SIMD3<Float>] {
        let floats = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
        return (0..<part.vertexCount).map { SIMD3(floats[$0 * 6], floats[$0 * 6 + 1], floats[$0 * 6 + 2]) }
    }

    /// The grid of cubes is laid about the model's middle: it reaches as far past the model
    /// on one side as on the other, not a whole cube further towards +x, +y and +z.
    func testTheCubesReachAsFarPastTheModelOnEverySide() throws {
        let all = try voxels().flatMap(positions(of:))
        XCTAssertFalse(all.isEmpty)
        let low = all.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = all.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        for axis in 0..<3 {
            XCTAssertEqual(low[axis] + high[axis], 0, accuracy: 1e-4, "axis \(axis): \(low[axis]) ... \(high[axis])")
            // Forty cubes to the model's width, and half a cube beyond it at each end.
            XCTAssertEqual(high[axis] - low[axis], 41.0 / 40, accuracy: 1e-4)
        }
    }

    /// The cubes' lines are those of a sheet of squares one cube wide: half a cube apart.
    func testTheCubesLinesAreHalfACubeApart() throws {
        for part in try voxels() {
            let buffer = try XCTUnwrap(part.wireSpacing)
            XCTAssertEqual(buffer.length, part.vertexCount * 4)
            let apart = buffer.contents().assumingMemoryBound(to: Float.self)
            XCTAssertTrue((0..<part.vertexCount).allSatisfy { abs(apart[$0] - 1.0 / 80) < 1e-6 })
        }
    }

    /// Two faces meet at every edge of the cubes' surface. The line along it is drawn once:
    /// drawn for both, it would be darker than a line of any other style.
    func testEachEdgeOfTheCubesIsOneLine() throws {
        var seen = Set<[UInt32]>(), lines = 0
        for part in try voxels() {
            let at = positions(of: part)
            let buffer = try XCTUnwrap(part.wireIndexBuffer)
            let indices = buffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in stride(from: 0, to: part.wireIndexCount, by: 2) {
                let a = at[Int(indices[i])], b = at[Int(indices[i + 1])]
                let ends = [a, b].map { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }.sorted { $0.lexicographicallyPrecedes($1) }
                seen.insert(ends[0] + ends[1])
                lines += 1
            }
        }
        XCTAssertGreaterThan(lines, 0)
        XCTAssertEqual(lines, seen.count, "\(lines) lines for \(seen.count) edges")
    }
}
