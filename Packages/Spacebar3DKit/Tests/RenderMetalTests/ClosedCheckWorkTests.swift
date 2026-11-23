import Metal
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// `GPUScene` judges whether a part is a closed, outward surface (`Part.checkClosed`: welding
/// positions, a corner array, `ClosedSurface.isClosedAndOutward`) so `MetalRenderer.hidesBackFaces`
/// can leave out its back faces. That answer is used only for an opaque, not cut-out, not
/// one-sided part; for any other the work is thrown away.
final class ClosedCheckWorkTests: XCTestCase {
    private let corners: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
    private let quads: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]

    private func cube(material: Int) -> ModelScene.MeshPart {
        var part = ModelScene.MeshPart()
        part.positions = corners
        part.triangleIndices = quads.flatMap { [$0[0], $0[1], $0[2], $0[0], $0[2], $0[3]] }
        part.faceted = true
        part.material = material
        return part
    }

    /// A load of a large model takes longer than it needs to: on a UV sphere of 2,000,000
    /// triangles (1,000 by 1,000 grid, indexed, Debug build, Apple Silicon) `makeScene` took
    /// 5.4 s with normals and 15.9 s without, and `checkClosed` alone took 3.7 s and 4.0 s
    /// of that (68% and 25%), well over a tenth of the upload. Every part pays it, though a
    /// cut-out, a one-sided and a point part never use it (`hidesBackFaces` returns false for a
    /// cut-out before it reads `closed`; a one-sided part is culled by its material first;
    /// points have no faces). Source: commit f473924's `checkClosed` on every part, and
    /// `MetalRenderer.hidesBackFaces` / the opaque-pass cull choice in `MetalRenderer`.
    ///
    /// Needs `closedChecks: Int` on `GPUScene` (internal is enough, read through Mirror): the
    /// number of parts `checkClosed` really examined, that is, passed its size guard and
    /// welded the positions. Only the plain opaque cube should count; a blended part is left
    /// out of this test because the solid and wire views, which do not show colours, draw it
    /// through the opaque path where `closed` is still read.
    func testPartsThatNeverUseTheClosedAnswerAreNotChecked() throws {
        var scene = ModelScene()
        var plain = ModelScene.Material()
        plain.name = "plain"
        var cutOut = ModelScene.Material()
        cutOut.alphaCutoff = 0.5
        var oneSided = ModelScene.Material()
        oneSided.oneSided = true
        scene.materials = [plain, cutOut, oneSided]
        var points = ModelScene.MeshPart()
        points.positions = corners
        points.primitive = .points
        var tiny = cube(material: 0)
        tiny.triangleIndices = Array(tiny.triangleIndices.prefix(9)) // too small to be closed
        scene.meshes = [ModelScene.Mesh(parts: [cube(material: 0), cube(material: 1), cube(material: 2), points, tiny])]
        scene.nodes = [ModelScene.Node(transform: matrix_identity_float4x4, mesh: 0)]

        let gpu = try MetalRenderer().makeScene(scene)
        let counted = Mirror(reflecting: gpu).descendant("closedChecks") as? Int
        XCTAssertNotNil(counted, "GPUScene needs `closedChecks: Int`, the parts checkClosed examined")
        XCTAssertEqual(counted, 1, "only the plain opaque cube needs its closed answer")
        XCTAssertEqual(gpu.closedPartCount, 1, "and it is still found closed (3 now: the cut-out and one-sided cubes are checked too)")
    }
}
