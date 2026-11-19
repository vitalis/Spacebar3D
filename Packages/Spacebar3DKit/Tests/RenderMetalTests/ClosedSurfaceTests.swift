import ImportSTL
import ModelCore
import RenderMetal
import simd
import XCTest

final class ClosedSurfaceTests: XCTestCase {
    private let corners: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
    /// Counter-clockwise seen from outside.
    private let quads: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
    private var cubeIndices: [UInt32] { quads.flatMap { [$0[0], $0[1], $0[2], $0[0], $0[2], $0[3]] } }

    private func closed(_ indices: [UInt32], _ positions: [SIMD3<Float>]) -> Bool {
        let floats = positions.flatMap { [$0.x, $0.y, $0.z] }
        return ClosedSurface.isClosedAndOutward(indices: indices, indexCount: indices.count, floats: floats, stride: 3, vertexCount: positions.count)
    }

    func testACubeIsClosed() {
        XCTAssertTrue(closed(cubeIndices, corners))
        // A triangle that names a vertex twice draws nothing and does not count.
        XCTAssertTrue(closed(cubeIndices + [0, 0, 1], corners))
    }

    func testWhatIsNotClosedOrNotOutward() {
        var indices = cubeIndices
        XCTAssertFalse(closed(Array(indices.dropLast(3)), corners), "a missing triangle leaves a hole")
        indices.swapAt(0, 1)
        XCTAssertFalse(closed(indices, corners), "one triangle turned the other way")
        let insideOut = stride(from: 0, to: cubeIndices.count, by: 3).flatMap { [cubeIndices[$0], cubeIndices[$0 + 2], cubeIndices[$0 + 1]] }
        XCTAssertFalse(closed(insideOut, corners), "every face turned inward")
        XCTAssertFalse(closed(cubeIndices + Array(cubeIndices.prefix(3)), corners), "a triangle stored twice")
        XCTAssertFalse(closed([0, 1, 2], corners))
    }

    func testSeparatePiecesAreJudgedEachOnItsOwn() {
        let second = corners.map { $0 + SIMD3<Float>(5, 0, 0) }
        let shifted = cubeIndices.map { $0 + 8 }
        XCTAssertTrue(closed(cubeIndices + shifted, corners + second))
        // The second cube inside out: its volume is negative though the total is not.
        let big = second.map { ($0 - SIMD3<Float>(5, 0, 0)) * 0.5 + SIMD3<Float>(5, 0, 0) }
        let insideOut = stride(from: 0, to: shifted.count, by: 3).flatMap { [shifted[$0], shifted[$0 + 2], shifted[$0 + 1]] }
        XCTAssertFalse(closed(cubeIndices + insideOut, corners + big))
    }

    private func scene(_ indices: [UInt32], transform: simd_float4x4 = matrix_identity_float4x4) -> ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = corners
        part.triangleIndices = indices
        part.faceted = true
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(transform: transform, mesh: 0)]
        return scene
    }

    /// Leaving the back faces out must not change a single pixel: from outside, from
    /// inside (where they are drawn after all), and for a mirrored placement.
    func testLeavingOutBackFacesChangesNothingOnScreen() throws {
        let renderer = try MetalRenderer()
        let mirror = simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1))
        for (label, transform) in [("plain", matrix_identity_float4x4), ("mirrored", mirror)] {
            let gpu = try renderer.makeScene(scene(cubeIndices, transform: transform))
            XCTAssertEqual(gpu.closedPartCount, 1, label)
            renderer.show(gpu)
            let home = renderer.camera
            var inside = home
            inside.distance = 0.05
            var grazing = home
            grazing.target = SIMD3(0, 0, 0); grazing.distance = 1.0 + home.near * 1.2; grazing.yaw = 0; grazing.pitch = 0
            for (place, camera) in [("outside", home), ("inside", inside), ("at the surface", grazing)] {
                renderer.camera = camera
                for look in [RenderLook(view: .solid), RenderLook(view: .textured), RenderLook(view: .solid, style: .celShaded)] {
                    renderer.look = look
                    renderer.cullsHiddenFaces = true
                    let with = try renderer.renderOffscreen(width: 160, height: 120)
                    renderer.cullsHiddenFaces = false
                    let without = try renderer.renderOffscreen(width: 160, height: 120)
                    XCTAssertEqual(with.bytes, without.bytes, "\(label), \(place), \(look.view) \(look.style)")
                }
            }
        }
    }

    func testAnOpenBoxKeepsItsBackFaces() throws {
        let renderer = try MetalRenderer()
        XCTAssertEqual(try renderer.makeScene(scene(Array(cubeIndices.dropLast(6)))).closedPartCount, 0)
    }

    func testATorusReadFromSTLIsClosed() throws {
        let renderer = try MetalRenderer()
        let gpu = try renderer.makeScene(STLReader.scene(from: torusSTL(segments: 24, sides: 12)))
        XCTAssertEqual(gpu.closedPartCount, 1)
    }
}
