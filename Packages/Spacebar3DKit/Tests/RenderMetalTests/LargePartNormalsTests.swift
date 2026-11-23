import Metal
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// A part without normals that has more triangles than get a vertex for every corner
/// (`GPUScene.creaseLimit`): its vertices stay shared, and it is lit as a small part is.
final class LargePartNormalsTests: XCTestCase {
    private func scene(_ part: ModelScene.MeshPart) -> ModelScene {
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    private func normals(of part: GPUScene.Part) -> [SIMD3<Float>] {
        let floats = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
        return (0..<part.vertexCount).map { SIMD3(floats[$0 * 6 + 3], floats[$0 * 6 + 4], floats[$0 * 6 + 5]) }
    }

    /// A cube of `across` squares along each edge. The faces that meet share their vertices.
    private func cube(across: Int) -> ModelScene.MeshPart {
        var part = ModelScene.MeshPart()
        var placed: [SIMD3<Int32>: UInt32] = [:]
        func vertex(_ at: SIMD3<Int32>) -> UInt32 {
            if let found = placed[at] { return found }
            placed[at] = UInt32(part.positions.count)
            part.positions.append(SIMD3<Float>(Float(at.x), Float(at.y), Float(at.z)) / Float(across) - 0.5)
            return UInt32(part.positions.count - 1)
        }
        let n = Int32(across)
        // Each face from a corner along two edges, their cross product pointing out.
        let x = SIMD3<Int32>(1, 0, 0), y = SIMD3<Int32>(0, 1, 0), z = SIMD3<Int32>(0, 0, 1)
        let faces: [(SIMD3<Int32>, SIMD3<Int32>, SIMD3<Int32>)] = [(x &* n, y, z), (.zero, z, y), (y &* n, z, x), (.zero, x, z), (z &* n, x, y), (.zero, y, x)]
        for (corner, u, v) in faces {
            for i in 0..<n {
                for j in 0..<n {
                    let a = vertex(corner &+ u &* i &+ v &* j), b = vertex(corner &+ u &* (i + 1) &+ v &* j)
                    let c = vertex(corner &+ u &* (i + 1) &+ v &* (j + 1)), d = vertex(corner &+ u &* i &+ v &* (j + 1))
                    part.triangleIndices += [a, b, c, a, c, d]
                }
            }
        }
        return part
    }

    /// A pipe whose wall goes in and out a little from one strip to the next, wrapped by an
    /// image: the first and the last column of vertices are at the same places, with
    /// the image's left and right edge.
    private func pipe(around: Int, rings: Int) -> ModelScene.MeshPart {
        var part = ModelScene.MeshPart()
        for r in 0...rings {
            for a in 0...around {
                let angle = 2 * Float.pi * Float(a % around) / Float(around), radius: Float = a % 2 == 0 ? 1 : 1.02
                part.positions.append(SIMD3(radius * cos(angle), Float(r) * 0.1, radius * sin(angle)))
                part.uv0.append(SIMD2(Float(a) / Float(around), Float(r) / Float(rings)))
            }
        }
        let row = UInt32(around + 1)
        for r in 0..<UInt32(rings) {
            for a in 0..<UInt32(around) {
                let i = r * row + a
                part.triangleIndices += [i, i + row, i + 1, i + 1, i + row, i + row + 1]
            }
        }
        return part
    }

    /// 307,200 triangles. Averaged over all the faces at a vertex, the normals along a
    /// cube's edges pointed between its faces, and the edges were lit as if rounded.
    func testALargeCubeKeepsItsEdgesSharp() throws {
        let source = cube(across: 160)
        XCTAssertGreaterThan(source.triangleIndices.count / 3, GPUScene.creaseLimit)
        let part = try XCTUnwrap(MetalRenderer().makeScene(scene(source)).parts.first)
        XCTAssertNotNil(part.indexBuffer)
        XCTAssertLessThan(part.vertexCount, part.indexCount / 4, "its vertices are still shared")
        let slanted = normals(of: part).filter { simd_reduce_max(simd_abs($0)) < 0.999 }
        XCTAssertEqual(slanted.count, 0, "every normal is one of a face")
    }

    /// 312,000 triangles. A normal made only from the faces that use its own vertex stops
    /// at the image's seam, and the two sides of the seam were lit differently.
    func testALargePartIsLitAsOneAcrossTheSeamOfItsImage() throws {
        let around = 60, rings = 2600
        let source = pipe(around: around, rings: rings)
        XCTAssertGreaterThan(source.triangleIndices.count / 3, GPUScene.creaseLimit)
        let part = try XCTUnwrap(MetalRenderer().makeScene(scene(source)).parts.first)
        XCTAssertEqual(part.vertexCount, source.positions.count, "nothing is sharp enough to repeat a vertex")
        let made = normals(of: part)
        var apart: Float = 0
        for r in 0...rings { apart = max(apart, simd_distance(made[r * (around + 1)], made[r * (around + 1) + around])) }
        XCTAssertEqual(apart, 0, accuracy: 1e-4)
    }
}
