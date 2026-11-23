import Foundation
import ImportRouter
import ModelCore
@testable import RenderMetal
import simd
import XCTest

/// How a part's placement (its node's matrix) carries over to what is drawn.
final class PlacementTests: XCTestCase {
    /// An octahedron. Mirrored in x it is the same surface, triangle for triangle, and it
    /// stays so when it is moved, so two ways of placing it can be compared pixel by pixel.
    private func scene(transform: simd_float4x4 = matrix_identity_float4x4, movedInVertices offset: SIMD3<Float> = .zero, faceted: Bool = false) -> ModelScene {
        let corners: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        var part = ModelScene.MeshPart()
        part.positions = corners.map { $0 + offset }
        // Counter-clockwise seen from outside.
        part.triangleIndices = [0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0, 4, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3, 5]
        if faceted { part.faceted = true } else { part.normals = corners }
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(transform: transform, mesh: 0)]
        return scene
    }

    /// The share of pixels that differ by more than rounding in any channel.
    private func difference(_ a: OffscreenImage, _ b: OffscreenImage) -> Double {
        var differing = 0
        for pixel in 0..<(a.bytes.count / 4) where (0..<4).contains(where: { abs(Int(a.bytes[pixel * 4 + $0]) - Int(b.bytes[pixel * 4 + $0])) > 6 }) { differing += 1 }
        return Double(differing) / Double(a.bytes.count / 4)
    }

    private let looks = [RenderLook(view: .solid), RenderLook(view: .normal), RenderLook(view: .textured), RenderLook(view: .solid, style: .celShaded)]

    private func pictures(of scene: ModelScene, with renderer: MetalRenderer) throws -> [OffscreenImage] {
        renderer.show(try renderer.makeScene(scene))
        return try looks.map { renderer.look = $0; return try renderer.renderOffscreen(width: 200, height: 160) }
    }

    /// A placement that mirrors turns every triangle the other way round on the screen.
    /// The part is still seen from outside: it is lit, outlined and culled as its mirror image.
    func testAMirroredPartLooksLikeItsMirrorImage() throws {
        let renderer = try MetalRenderer()
        let mirror = simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1))
        for faceted in [false, true] {
            let plain = try pictures(of: scene(faceted: faceted), with: renderer)
            let mirrored = try pictures(of: scene(transform: mirror, faceted: faceted), with: renderer)
            for (i, look) in looks.enumerated() {
                XCTAssertLessThan(difference(plain[i], mirrored[i]), 0.005, "\(look.view) \(look.style), faceted \(faceted)")
            }
        }
    }

    /// A normal is turned and scaled by its part's placement, never moved by it.
    func testAPartsPositionDoesNotMoveItsNormals() throws {
        let renderer = try MetalRenderer()
        var placement = simd_float4x4(diagonal: SIMD4(2, 1, 1, 1))
        placement.columns.3 = SIMD4(3, 5, -2, 1)
        let part = try XCTUnwrap(renderer.makeScene(scene(transform: placement)).parts.first)
        XCTAssertEqual(part.normalMatrix * SIMD4<Float>(0, 1, 0, 0), SIMD4(0, 1, 0, 0))
        // Stretched twofold along x, a normal along x is half as long (and is normalised later).
        XCTAssertEqual(part.normalMatrix * SIMD4<Float>(1, 0, 0, 0), SIMD4(0.5, 0, 0, 0))
    }

    /// Where a model is put by its node or by its own coordinates is the same model: the
    /// outline, the reflection in the floor and the shading must not tell the two apart.
    func testMovingAPartByItsNodeOrByItsVerticesLooksTheSame() throws {
        let renderer = try MetalRenderer()
        let offset = SIMD3<Float>(0, 4, 0)
        var move = matrix_identity_float4x4
        move.columns.3 = SIMD4(offset, 1)
        let byVertices = try pictures(of: scene(movedInVertices: offset), with: renderer)
        let byNode = try pictures(of: scene(transform: move), with: renderer)
        for (i, look) in looks.enumerated() {
            XCTAssertLessThan(difference(byVertices[i], byNode[i]), 0.005, "\(look.view) \(look.style)")
        }
    }

    /// A file may put its model millions of units from the origin: a survey, a building on
    /// its site. It is the same model there. Drawn where numbers that large are half a
    /// unit apart, its corners landed beside their places and moved as the view turned.
    func testAModelFarFromTheOriginLooksLikeTheSameModelNearIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("far-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        /// The octahedron as a file would hold it, every corner a whole number.
        func loaded(at offset: SIMD3<Int>, named name: String) throws -> ModelScene {
            let corners: [SIMD3<Int>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
            let faces = [[0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4], [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5]]
            let text = corners.map { c in "v \(c.x + offset.x) \(c.y + offset.y) \(c.z + offset.z)" } + faces.map { f in "f \(f[0] + 1) \(f[1] + 1) \(f[2] + 1)" }
            let url = folder.appendingPathComponent(name)
            try Data(text.joined(separator: "\n").utf8).write(to: url)
            return try ImportRouter.load(url, format: .obj)
        }
        let renderer = try MetalRenderer()
        let near = try pictures(of: loaded(at: SIMD3(0, 0, 0), named: "near.obj"), with: renderer)
        let far = try pictures(of: loaded(at: SIMD3(4_194_304, -2_097_152, 1_048_576), named: "far.obj"), with: renderer)
        for (i, look) in looks.enumerated() {
            XCTAssertLessThan(difference(near[i], far[i]), 0.005, "\(look.view) \(look.style)")
        }
    }
}
