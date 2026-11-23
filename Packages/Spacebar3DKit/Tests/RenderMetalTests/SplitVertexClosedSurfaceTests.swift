import ModelCore
import RenderMetal
import simd
import XCTest

/// Closed-surface culling for meshes whose corners are split (a hard edge, a UV seam, or
/// normals made by the renderer), so that the same place has more than one vertex.
final class SplitVertexClosedSurfaceTests: XCTestCase {
    private let corners: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
    /// Counter-clockwise seen from outside, with the outward normal of each.
    private let faces: [(quad: [Int], normal: SIMD3<Float>)] = [
        ([0, 3, 2, 1], SIMD3(0, 0, -1)), ([4, 5, 6, 7], SIMD3(0, 0, 1)), ([0, 1, 5, 4], SIMD3(0, -1, 0)),
        ([2, 3, 7, 6], SIMD3(0, 1, 0)), ([1, 2, 6, 5], SIMD3(1, 0, 0)), ([0, 4, 7, 3], SIMD3(-1, 0, 0))]

    /// A cube as a glTF exporter writes it: four vertices of its own for each face (24),
    /// each with the face's normal and a texture coordinate. `skipping` leaves a face out,
    /// `inward` turns every face the other way, `offset` moves it.
    private func cube(skipping skipped: Int? = nil, inward: Bool = false, offset: SIMD3<Float> = .zero, scale: Float = 1,
                      normals withNormals: Bool = true, uvs withUVs: Bool = true) -> ModelScene.MeshPart {
        var part = ModelScene.MeshPart()
        for (f, face) in faces.enumerated() where f != skipped {
            let base = UInt32(part.positions.count)
            for (k, c) in face.quad.enumerated() {
                part.positions.append(corners[c] * scale + offset)
                part.normals.append(inward ? -face.normal : face.normal)
                part.uv0.append(SIMD2(k == 1 || k == 2 ? 1 : 0, k >= 2 ? 1 : 0))
            }
            part.triangleIndices += inward ? [base, base + 2, base + 1, base, base + 3, base + 2] : [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        if !withNormals { part.normals = [] }
        if !withUVs { part.uv0 = [] }
        return part
    }

    private func scene(_ parts: ModelScene.MeshPart..., transform: simd_float4x4 = matrix_identity_float4x4) -> ModelScene {
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: parts)]
        scene.nodes = [ModelScene.Node(transform: transform, mesh: 0)]
        return scene
    }

    private func closedCount(_ parts: ModelScene.MeshPart...) throws -> Int {
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: parts)]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return try MetalRenderer().makeScene(scene).closedPartCount
    }

    /// A cube whose faces have vertices of their own (24, with normals and UVs) was judged
    /// open because its edges' two ends have different indices, so its back faces were
    /// drawn for nothing: most models with normals never got culled.
    func testACubeWithAVertexPerFaceCornerIsClosed() throws {
        let part = cube()
        XCTAssertEqual(part.positions.count, 24)
        XCTAssertEqual(try closedCount(part), 1)
    }

    /// Same cube without texture coordinates (only a hard edge splits it).
    func testACubeSplitOnlyForHardEdgesIsClosed() throws {
        XCTAssertEqual(try closedCount(cube(uvs: false)), 1)
    }

    /// A part with no normals of its own gets them made, which puts its vertices in
    /// triangle order with no index buffer; it was never tested at all.
    func testACubeWithoutNormalsIsClosed() throws {
        XCTAssertEqual(try closedCount(cube(normals: false, uvs: false)), 1)
        XCTAssertEqual(try closedCount(cube(normals: false, uvs: true)), 1)
    }

    /// A cube with a face missing has a hole: it must keep both sides, split or not.
    func testASplitCubeMissingAFaceIsStillOpen() throws {
        XCTAssertEqual(try closedCount(cube(skipping: 3)), 0)
        XCTAssertEqual(try closedCount(cube(skipping: 3, normals: false, uvs: false)), 0)
    }

    /// A plane is a surface with an edge, not a solid, and shows both sides.
    func testAPlaneIsOpenWithAndWithoutNormals() throws {
        var plane = ModelScene.MeshPart()
        plane.positions = [SIMD3(-1, 0, -1), SIMD3(1, 0, -1), SIMD3(1, 0, 1), SIMD3(-1, 0, 1)]
        plane.triangleIndices = [0, 2, 1, 0, 3, 2]
        plane.normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 4)
        plane.uv0 = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        XCTAssertEqual(try closedCount(plane), 0)
        plane.normals = []
        XCTAssertEqual(try closedCount(plane), 0)
    }

    /// A cube turned inside out must not be culled: from outside it would show its far
    /// inner faces, and culling the back faces would leave it empty.
    func testAnInsideOutSplitCubeIsNotCulled() throws {
        XCTAssertEqual(try closedCount(cube(inward: true)), 0)
        XCTAssertEqual(try closedCount(cube(inward: true, normals: false, uvs: false)), 0)
    }

    /// Pieces are judged each on their own: a good cube beside an inside-out one is not
    /// closed as a whole, though the sum of their volumes is positive.
    func testASplitPieceInsideOutSpoilsThePartEvenBesideAGoodOne() throws {
        var part = cube(scale: 2)
        let other = cube(inward: true, offset: SIMD3(10, 0, 0), scale: 0.5)
        let base = UInt32(part.positions.count)
        part.positions += other.positions; part.normals += other.normals; part.uv0 += other.uv0
        part.triangleIndices += other.triangleIndices.map { $0 + base }
        XCTAssertEqual(try closedCount(part), 0)
    }

    /// Two good cubes in one part are closed.
    func testTwoSplitCubesInOnePartAreClosed() throws {
        var part = cube()
        let other = cube(offset: SIMD3(5, 0, 0))
        let base = UInt32(part.positions.count)
        part.positions += other.positions; part.normals += other.normals; part.uv0 += other.uv0
        part.triangleIndices += other.triangleIndices.map { $0 + base }
        XCTAssertEqual(try closedCount(part), 1)
    }

    /// Leaving the back faces out must not change a pixel of a textured, split cube: seen
    /// from outside, from inside, and at the surface, plain and mirrored.
    func testCullingASplitTexturedCubeChangesNothingOnScreen() throws {
        let renderer = try MetalRenderer()
        let mirror = simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1))
        for (label, transform) in [("plain", matrix_identity_float4x4), ("mirrored", mirror)] {
            let gpu = try renderer.makeScene(scene(cube(), transform: transform))
            // Not skipped: the picture would trivially be the same.
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
}
