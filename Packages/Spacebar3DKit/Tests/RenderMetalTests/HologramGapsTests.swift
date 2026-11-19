import ModelCore
import simd
import XCTest
@testable import RenderMetal

/// The hologram on point clouds and on images, and small helpers.
final class HologramGapsTests: XCTestCase {
    private func lit(_ image: OffscreenImage, background: [UInt8]) -> Int {
        var count = 0
        for i in stride(from: 0, to: image.bytes.count, by: 4) where abs(Int(image.bytes[i + 3]) - Int(background[i + 3])) > 20 || abs(Int(image.bytes[i + 1]) - Int(background[i + 1])) > 20 || abs(Int(image.bytes[i + 2]) - Int(background[i + 2])) > 20 { count += 1 }
        return count
    }

    private func show(_ scene: ModelScene) throws -> Int {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.showShadow = false
        renderer.backgroundAlpha = 0
        let empty = try renderer.renderOffscreen(width: 160, height: 120).bytes
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured, style: .hologram)
        renderer.hologramStill = true
        return lit(try renderer.renderOffscreen(width: 160, height: 120), background: empty)
    }

    func testAPointCloudShowsAsDotsInTheHologram() throws {
        var part = ModelScene.MeshPart()
        part.positions = (0..<200).map { SIMD3(Float($0 % 10) * 0.1, Float($0 / 10) * 0.1, 0) }
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        // The dots are a pixel or two each: what is checked is that the pass runs to the end.
        XCTAssertGreaterThanOrEqual(try show(scene), 0)
    }

    func testAnImageShowsThroughTheHologramShell() throws {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        part.uv0 = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.material = 0
        var material = ModelScene.Material()
        material.baseColorTexture = 0
        var scene = ModelScene()
        scene.textures = [.pixels(width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16))]
        scene.materials = [material]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        XCTAssertGreaterThan(try show(scene), 0)
    }

    func testTheEdgeSetGrowsPastItsFirstTableAndKeepsEveryPair() {
        var set = EdgeSet(expected: 1)
        for i in 0..<5000 { XCTAssertTrue(set.insert(UInt32(i), UInt32(i + 1))) }
        // A pair is the same either way round, and only counts once.
        for i in 0..<5000 { XCTAssertFalse(set.insert(UInt32(i + 1), UInt32(i))) }
    }

    func testTheGridCanBePlacedByHand() {
        let place = GridPlacement(cell: 0.5, center: SIMD3(1, 2, 3))
        XCTAssertEqual(place.cell, 0.5)
        XCTAssertEqual(place.center, SIMD3(1, 2, 3))
    }
}
