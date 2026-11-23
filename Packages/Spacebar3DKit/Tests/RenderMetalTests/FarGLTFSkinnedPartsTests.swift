import Foundation
import ImportGLTF
import Metal
import ModelCore
import RenderMetal
import simd
import XCTest

/// Far glTF models whose parts are skinned or animated, brought near the origin as the app does
/// (`GLTFReader.scene`, then `movedNearTheOrigin()`), then posed on the CPU path and read back as
/// the renderer places them: each part's `model` times its posed vertices, in Double.
///
/// glTF makes its skeleton with `node: nil`, and the renderer places a skinned part by identity
/// then, but `movedNearTheOrigin()` rebases only skeletons that have a node. Source: the
/// `Skeleton.node` handling in `ModelScene.movedNearTheOrigin` / `rebaseSkeletons` and GPUScene.
final class FarGLTFSkinnedPartsTests: XCTestCase {
    // MARK: fixtures

    private func json(_ number: Float) -> String { "\(number)" }

    /// Two quads (each 1 by 1, in the xy plane) side by side, their corners `far` out in every axis
    /// (the nodes sit at the origin): the first is still, the second, four units to the right, is
    /// animated (its node lifts it by 1 over a second). All values are exact Floats for `far` a
    /// multiple of 2^20 below 2^22 (offsets are multiples of 0.5).
    private func mixed(far: Float) throws -> Data {
        let still: [Float] = [-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0, -0.5, 0.5, 0].enumerated().map { $0.element + far }
        let moving: [Float] = still.enumerated().map { $0.offset % 3 == 0 ? $0.element + 4 : $0.element }
        for (k, value) in still.enumerated() { precondition(Double(value) == Double([-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0, -0.5, 0.5, 0][k]) + Double(far), "fixture is not exact at \(far)") }
        for (k, value) in moving.enumerated() { precondition(Double(value) == Double(still[k]) + (k % 3 == 0 ? 4 : 0), "fixture is not exact at \(far)") }
        var bytes = Data()
        bytes.append(still.withUnsafeBytes { Data($0) })                                           // 0..48
        bytes.append(moving.withUnsafeBytes { Data($0) })                                          // 48..96
        bytes.append([UInt16(0), 1, 2, 0, 2, 3].withUnsafeBytes { Data($0) })                      // 96..108
        bytes.append([Float(0), 1].withUnsafeBytes { Data($0) })                                   // 108..116
        bytes.append([Float(0), 0, 0, 0, 1, 0].withUnsafeBytes { Data($0) })                       // 116..140
        let text = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],
         "nodes":[{"mesh":0},{"mesh":1}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":2}]},{"primitives":[{"attributes":{"POSITION":1},"indices":2}]}],
         "animations":[{"samplers":[{"input":3,"output":4,"interpolation":"LINEAR"}],"channels":[{"sampler":0,"target":{"node":1,"path":"translation"}}]}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[\(still[0]),\(still[1]),\(still[2])],"max":[\(still[3]),\(still[7]),\(still[8])]},
                      {"bufferView":1,"componentType":5126,"count":4,"type":"VEC3","min":[\(moving[0]),\(moving[1]),\(moving[2])],"max":[\(moving[3]),\(moving[7]),\(moving[8])]},
                      {"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"},
                      {"bufferView":3,"componentType":5126,"count":2,"type":"SCALAR","min":[0],"max":[1]},
                      {"bufferView":4,"componentType":5126,"count":2,"type":"VEC3"}],
         "bufferViews":[{"buffer":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":48},{"buffer":0,"byteOffset":96,"byteLength":12},
                        {"buffer":0,"byteOffset":108,"byteLength":8},{"buffer":0,"byteOffset":116,"byteLength":24}],
         "buffers":[{"byteLength":\(bytes.count),"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}]}
        """
        return Data(text.utf8)
    }

    /// A flat strip up the y axis (0 to 2, 0.5 wide) skinned to two joints (lower half joint a,
    /// upper half joint b), the rig `far` out in every axis; a clip turns b a quarter turn about z.
    /// Offsets are multiples of 0.25 and `far` a multiple of 2^20 below 2^22, so each is an exact Float.
    private func rig(far: Float) throws -> Data {
        let t = SIMD3<Float>(repeating: far)
        let offsets: [SIMD3<Float>] = [SIMD3(-0.25, 0, 0), SIMD3(0.25, 0, 0), SIMD3(-0.25, 1, 0), SIMD3(0.25, 1, 0), SIMD3(-0.25, 2, 0), SIMD3(0.25, 2, 0)]
        let positions = offsets.map { $0 + t }
        for (near, placed) in zip(offsets, positions) { for k in 0..<3 { precondition(Double(placed[k]) == Double(near[k]) + Double(far), "fixture is not exact at \(far)") } }
        func move(_ x: SIMD3<Float>) -> [Float] { [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x.x, x.y, x.z, 1] }
        var bytes = Data()
        bytes.append(positions.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBytes { Data($0) })                      // 0..72
        bytes.append(Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] as [UInt8]))            // 72..96 joints (uint8 x4)
        bytes.append(Data(count: 8))                                                                             // 96..104 padding
        bytes.append(Array(repeating: [Float(1), 0, 0, 0], count: 6).joined().map { $0 }.withUnsafeBytes { Data($0) })                  // 104..200 weights
        bytes.append([UInt16(0), 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4].withUnsafeBytes { Data($0) })                  // 200..224 indices
        bytes.append((move(-t) + move(-t - SIMD3(0, 1, 0))).withUnsafeBytes { Data($0) })                        // 224..352 inverse binds
        bytes.append([Float(0), 1].withUnsafeBytes { Data($0) })                                                // 352..360 times
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        bytes.append([Float(0), 0, 0, 1, quarter.imag.x, quarter.imag.y, quarter.imag.z, quarter.real].withUnsafeBytes { Data($0) }) // 360..392
        func v(_ s: SIMD3<Float>) -> String { "[\(json(s.x)),\(json(s.y)),\(json(s.z))]" }
        let text = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,2]}],
         "nodes":[{"name":"a","translation":\(v(t)),"children":[1]},{"name":"b","translation":[0,1,0]},{"mesh":0,"skin":0}],
         "skins":[{"joints":[0,1],"inverseBindMatrices":4,"skeleton":0}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2},"indices":3}]}],
         "animations":[{"samplers":[{"input":5,"output":6,"interpolation":"LINEAR"}],"channels":[{"sampler":0,"target":{"node":1,"path":"rotation"}}]}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":6,"type":"VEC3","min":[\(json(t.x - 0.25)),\(json(t.y)),\(json(t.z))],"max":[\(json(t.x + 0.25)),\(json(t.y + 2)),\(json(t.z))]},
                      {"bufferView":1,"componentType":5121,"count":6,"type":"VEC4"},
                      {"bufferView":2,"componentType":5126,"count":6,"type":"VEC4"},
                      {"bufferView":3,"componentType":5123,"count":12,"type":"SCALAR"},
                      {"bufferView":4,"componentType":5126,"count":2,"type":"MAT4"},
                      {"bufferView":5,"componentType":5126,"count":2,"type":"SCALAR","min":[0],"max":[1]},
                      {"bufferView":6,"componentType":5126,"count":2,"type":"VEC4"}],
         "bufferViews":[{"buffer":0,"byteLength":72},{"buffer":0,"byteOffset":72,"byteLength":24},{"buffer":0,"byteOffset":104,"byteLength":96},
                        {"buffer":0,"byteOffset":200,"byteLength":24},{"buffer":0,"byteOffset":224,"byteLength":128},
                        {"buffer":0,"byteOffset":352,"byteLength":8},{"buffer":0,"byteOffset":360,"byteLength":32}],
         "buffers":[{"byteLength":\(bytes.count),"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}]}
        """
        return Data(text.utf8)
    }

    // MARK: measuring

    /// Every part's posed vertices in the scene's own frame, in Double, as the renderer holds them.
    private func placed(_ scene: ModelScene, counts: [Int], time: Float) throws -> [[SIMD3<Double>]] {
        let renderer = try MetalRenderer()
        renderer.skinsOnGPU = false
        renderer.showGrid = false
        let gpu = try renderer.makeScene(scene)
        renderer.show(gpu)
        gpu.pose(clip: 0, time: time)
        _ = try renderer.renderOffscreen(width: 32, height: 32)
        let parts = try XCTUnwrap(Mirror(reflecting: gpu).children.first { $0.label == "parts" }?.value as? [AnyObject])
        XCTAssertEqual(parts.count, counts.count, "parts drawn")
        return try zip(parts, counts).map { part, count in
            let fields = Mirror(reflecting: part).children
            let buffer = try XCTUnwrap(fields.first { $0.label == "vertexBuffer" }?.value as? MTLBuffer)
            let model = try XCTUnwrap(fields.first { $0.label == "model" }?.value as? simd_float4x4, "Part has no model: simd_float4x4")
            let floats = buffer.contents().assumingMemoryBound(to: Float.self)
            return (0..<count).map { i in
                let p = SIMD3<Double>(Double(floats[i * 6]), Double(floats[i * 6 + 1]), Double(floats[i * 6 + 2]))
                func col(_ c: SIMD4<Float>) -> SIMD3<Double> { SIMD3(Double(c.x), Double(c.y), Double(c.z)) }
                return col(model.columns.0) * p.x + col(model.columns.1) * p.y + col(model.columns.2) * p.z + col(model.columns.3)
            }
        }
    }

    private func centre(_ points: [SIMD3<Double>]) -> SIMD3<Double> { points.reduce(SIMD3<Double>.zero, +) / Double(points.count) }

    // MARK: finding 1

    /// A far glTF with one still mesh and one animated mesh side by side: after the app's move to
    /// the origin the animated mesh must still stand its authored four units from the still one.
    /// The still mesh moved by the far middle but the animated one (a skinned part of the
    /// node-less skeleton) stayed out where it was, millions of units from its neighbour.
    func testAnAnimatedMeshBesideAStillOneOnAFarGLTFKeepsItsPlace() throws {
        let far = Float(3_145_728)
        let scene = try GLTFReader.scene(from: try mixed(far: far)).movedNearTheOrigin()
        for (time, expected) in [(Float(0), SIMD3<Double>(4, 0, 0)), (1, SIMD3(4, 1, 0))] {
            let parts = try placed(scene, counts: [4, 4], time: time)
            let a = centre(parts[0]), b = centre(parts[1])
            // The parts come in node order: the still mesh first, the animated one second.
            let gap = b - a
            print("P3D-FARGLTF mixed time \(time): gap \(gap) expected \(expected); still at \(a), animated at \(b)")
            XCTAssertEqual(simd_distance(gap, expected), 0, accuracy: 1e-2, "time \(time): the animated mesh is \(gap) from the still one, authored \(expected)")
        }
    }

    /// The same file near the origin keeps the gap (so the test measures the move, not the reader).
    func testTheSameGLTFNearTheOriginKeepsTheGapBetweenAnAnimatedAndAStillMesh() throws {
        let scene = try GLTFReader.scene(from: try mixed(far: 0)).movedNearTheOrigin()
        let parts = try placed(scene, counts: [4, 4], time: 1)
        XCTAssertEqual(simd_distance(centre(parts[1]) - centre(parts[0]), SIMD3(4, 1, 0)), 0, accuracy: 1e-4)
    }

    /// A wholly skinned glTF rig three million units out, bent a quarter turn at its joint, must
    /// come out the shape the same rig has at the origin. glTF's node-less skeleton gets no
    /// rebasing, so the strip was posed by joint matrices whose far translations cancel in Float
    /// (steps of a quarter unit there).
    func testAWhollySkinnedFarGLTFPosesLikeOneAtTheOrigin() throws {
        let far = Float(3_145_728)
        for time in [Float(0), 0.5, 1] {
            let near = try placed(try GLTFReader.scene(from: try rig(far: 0)).movedNearTheOrigin(), counts: [6], time: time)[0]
            let moved = try placed(try GLTFReader.scene(from: try rig(far: far)).movedNearTheOrigin(), counts: [6], time: time)[0]
            var worst = 0.0
            for i in 1..<6 { worst = max(worst, simd_distance(moved[i] - moved[0], near[i] - near[0])) }
            print("P3D-FARGLTF rig time \(time): worst shape error \(worst); near first \(near[0]) far first \(moved[0])")
            XCTAssertLessThan(worst, 1e-3, "time \(time)")
        }
    }

    /// Two 1 by 1 quads whose mesh positions sit at plus or minus 0.5 (near zero) and whose NODES are
    /// far out: "Still" at (far, far, far) and "Rising" at (far + 4, far, far), the second lifted 1 and
    /// back by a LINEAR translation clip over 2 s. With `withStill` false only "Rising" is in the file.
    /// Every value is a multiple of 0.25 below 2^22, so exact in Float (checked as a precondition).
    private func farNodes(far: Float, withStill: Bool) throws -> Data {
        let corners: [Float] = [-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0, -0.5, 0.5, 0]
        let rest = SIMD3<Float>(far + 4, far, far), lifted = SIMD3<Float>(far + 4, far + 1, far)
        for (placed, near) in [(rest.x, far + 4), (lifted.y, far + 1)] { precondition(Double(placed) == Double(near), "fixture is not exact at \(far)") }
        precondition(Double(far + 4) - 4 == Double(far) && Double(far + 1) - 1 == Double(far), "fixture is not exact at \(far)")
        var bytes = Data()
        bytes.append(corners.withUnsafeBytes { Data($0) })                                                      // 0..48
        bytes.append([UInt16(0), 1, 2, 0, 2, 3].withUnsafeBytes { Data($0) })                                   // 48..60
        bytes.append([Float(0), 1, 2].withUnsafeBytes { Data($0) })                                             // 60..72
        bytes.append([rest.x, rest.y, rest.z, lifted.x, lifted.y, lifted.z, rest.x, rest.y, rest.z].withUnsafeBytes { Data($0) }) // 72..108
        let nodes = (withStill ? "{\"name\":\"Still\",\"mesh\":0,\"translation\":[\(far),\(far),\(far)]}," : "")
            + "{\"name\":\"Rising\",\"mesh\":0,\"translation\":[\(rest.x),\(rest.y),\(rest.z)]}"
        let rising = withStill ? 1 : 0
        let text = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[\(withStill ? "0,1" : "0")]}],
         "nodes":[\(nodes)],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
         "animations":[{"samplers":[{"input":2,"output":3,"interpolation":"LINEAR"}],"channels":[{"sampler":0,"target":{"node":\(rising),"path":"translation"}}]}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-0.5,-0.5,0],"max":[0.5,0.5,0]},
                      {"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"},
                      {"bufferView":2,"componentType":5126,"count":3,"type":"SCALAR","min":[0],"max":[2]},
                      {"bufferView":3,"componentType":5126,"count":3,"type":"VEC3"}],
         "bufferViews":[{"buffer":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":12},
                        {"buffer":0,"byteOffset":60,"byteLength":12},{"buffer":0,"byteOffset":72,"byteLength":36}],
         "buffers":[{"byteLength":\(bytes.count),"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}]}
        """
        return Data(text.utf8)
    }

    /// The worst deviation of a quad's four edges (corner order 0-1-2-3) from length 1.
    private func edgeError(_ q: [SIMD3<Double>]) -> Double {
        (0..<4).map { abs(simd_distance(q[$0], q[($0 + 1) % 4]) - 1) }.max() ?? 0
    }

    private func farthest(_ points: [SIMD3<Double>]) -> Double { points.map { simd_length($0) }.max() ?? 0 }

    /// A still and an animated quad with mesh at the origin but nodes 3 million out: loaded and moved
    /// near the origin as the app does, both must be drawn within a few units of it, keep their
    /// authored gap (4, 0, 0) at time 0 and (4, 1, 0) at time 1, and stay exact squares of edge 1.
    /// The animated node became a skinned part counted near zero, so the span looked small, nothing
    /// was moved and the scene was drawn at 3 million in Float.
    func testFarNodesWithNearMeshesAreDrawnNearTheOriginAsExactSquares() throws {
        let far = Float(3_145_728)
        let scene = try GLTFReader.scene(from: try farNodes(far: far, withStill: true)).movedNearTheOrigin()
        for (time, expected) in [(Float(0), SIMD3<Double>(4, 0, 0)), (1, SIMD3(4, 1, 0))] {
            let parts = try placed(scene, counts: [4, 4], time: time)
            let gap = centre(parts[1]) - centre(parts[0])
            let reach = max(farthest(parts[0]), farthest(parts[1]))
            let shape = max(edgeError(parts[0]), edgeError(parts[1]))
            print("P3D-FARGLTF farnodes time \(time): still at \(centre(parts[0])), rising at \(centre(parts[1])), gap \(gap), farthest corner \(reach), shape error \(shape)")
            XCTAssertLessThan(reach, 10, "time \(time): the quads are drawn \(reach) units from the origin")
            XCTAssertEqual(simd_distance(gap, expected), 0, accuracy: 1e-3, "time \(time): gap \(gap), authored \(expected)")
            XCTAssertLessThan(shape, 1e-3, "time \(time): the quads are not exact squares, edge error \(shape)")
        }
    }

    /// Only the animated quad, wholly skinned through its node's translation: after the move it must
    /// sit near the origin and be an exact square of edge 1 at the start, mid-rise and the top.
    func testAWhollyAnimatedFarNodeSitsNearTheOriginAsAnExactSquare() throws {
        let far = Float(3_145_728)
        let scene = try GLTFReader.scene(from: try farNodes(far: far, withStill: false)).movedNearTheOrigin()
        for time in [Float(0), 0.5, 1] {
            let quad = try placed(scene, counts: [4], time: time)[0]
            let reach = farthest(quad), shape = edgeError(quad)
            print("P3D-FARGLTF animated-only time \(time): at \(centre(quad)), farthest corner \(reach), shape error \(shape)")
            XCTAssertLessThan(reach, 10, "time \(time): the quad is drawn \(reach) units from the origin")
            XCTAssertLessThan(shape, 1e-3, "time \(time): not an exact square, edge error \(shape)")
        }
    }

    /// Guard: the existing far-vertex case (nodes at the origin) must keep its gap and shape.
    func testFarVerticesWithNodesAtTheOriginStillKeepTheirGapAndShape() throws {
        let scene = try GLTFReader.scene(from: try mixed(far: Float(3_145_728))).movedNearTheOrigin()
        let parts = try placed(scene, counts: [4, 4], time: 1)
        XCTAssertEqual(simd_distance(centre(parts[1]) - centre(parts[0]), SIMD3(4, 1, 0)), 0, accuracy: 1e-2)
        XCTAssertLessThan(max(edgeError(parts[0]), edgeError(parts[1])), 1e-3)
        XCTAssertLessThan(max(farthest(parts[0]), farthest(parts[1])), 10)
    }
}
