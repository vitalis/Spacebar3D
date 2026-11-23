import ModelCore
import RenderMetal
import simd
import XCTest

final class TransparencyTests: XCTestCase {
    /// A red square in front (z = 1) of a larger blue one (z = 0), both facing the camera.
    private func scene(frontOpacity: Float, frontFirst: Bool) -> ModelScene {
        func square(_ half: Float, z: Float, material: Int) -> ModelScene.MeshPart {
            var part = ModelScene.MeshPart()
            part.positions = [SIMD3(-half, -half, z), SIMD3(half, -half, z), SIMD3(half, half, z), SIMD3(-half, half, z)]
            part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
            part.triangleIndices = [0, 1, 2, 0, 2, 3]
            part.material = material
            return part
        }
        var red = ModelScene.Material(), blue = ModelScene.Material()
        red.baseColor = SIMD4(1, 0, 0, 1); red.opacity = frontOpacity; red.doubleSided = true
        blue.baseColor = SIMD4(0, 0, 1, 1)
        var scene = ModelScene()
        scene.materials = [red, blue]
        let front = square(0.5, z: 1, material: 0), back = square(2, z: 0, material: 1)
        scene.meshes = [ModelScene.Mesh(parts: frontFirst ? [front, back] : [back, front])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    /// Red and blue (0...255) of the pixel in the middle of the picture.
    private func middle(_ renderer: MetalRenderer, _ scene: ModelScene, look: RenderLook) throws -> (red: Int, blue: Int) {
        renderer.show(try renderer.makeScene(scene))
        renderer.look = look
        let image = try renderer.renderOffscreen(width: 120, height: 120)
        let i = (60 * image.width + 60) * 4
        return (Int(image.bytes[i + 2]), Int(image.bytes[i]))
    }

    func testASeeThroughSurfaceShowsWhatIsBehindIt() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        let unlit = RenderLook(view: .textured, style: .unlit)
        let opaque = try middle(renderer, scene(frontOpacity: 1, frontFirst: false), look: unlit)
        XCTAssertGreaterThan(opaque.red, 200)
        XCTAssertLessThan(opaque.blue, 30)
        // Half see-through: both colours show, whichever part comes first in the file
        // (see-through parts are drawn after the opaque ones).
        for frontFirst in [false, true] {
            let half = try middle(renderer, scene(frontOpacity: 0.5, frontFirst: frontFirst), look: unlit)
            XCTAssertGreaterThan(half.red, 90, "front first \(frontFirst): \(half)")
            XCTAssertLessThan(half.red, 200)
            XCTAssertGreaterThan(half.blue, 90, "front first \(frontFirst): \(half)")
        }
        // Fully see-through: only what is behind.
        let clear = try middle(renderer, scene(frontOpacity: 0, frontFirst: true), look: unlit)
        XCTAssertLessThan(clear.red, 30)
        XCTAssertGreaterThan(clear.blue, 200)
        // Lit Textured is see-through as well; Solid is not (no red and no blue there, and
        // the same picture whatever the opacity).
        let lit = try middle(renderer, scene(frontOpacity: 0.5, frontFirst: true), look: RenderLook(view: .textured))
        XCTAssertGreaterThan(lit.blue, 40, "\(lit)")
        renderer.show(try renderer.makeScene(scene(frontOpacity: 0.5, frontFirst: true)))
        renderer.look = RenderLook(view: .solid)
        let solidHalf = try renderer.renderOffscreen(width: 120, height: 120).bytes
        renderer.show(try renderer.makeScene(scene(frontOpacity: 1, frontFirst: true)))
        XCTAssertEqual(try renderer.renderOffscreen(width: 120, height: 120).bytes, solidHalf)
    }

    /// A see-through part with two sides (a bottle, a bubble) shows its own far wall through
    /// its near one, whichever of them the file lists first.
    func testASeeThroughPartShowsItsOwnFarSideThroughItsNearSide() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        for nearFirst in [false, true] {
            var part = ModelScene.MeshPart()
            // The near wall faces the camera; the far wall faces away from it, as the far side of a closed shape does.
            let near: [SIMD3<Float>] = [SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
            let far: [SIMD3<Float>] = [SIMD3(-1, -1, 0), SIMD3(-1, 1, 0), SIMD3(1, 1, 0), SIMD3(1, -1, 0)]
            part.positions = nearFirst ? near + far : far + near
            part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, nearFirst ? 1 : -1), count: 4) + [SIMD3<Float>](repeating: SIMD3(0, 0, nearFirst ? -1 : 1), count: 4)
            part.triangleIndices = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
            part.material = 0
            var glass = ModelScene.Material()
            glass.baseColor = SIMD4(1, 0, 0, 1); glass.opacity = 0.5; glass.doubleSided = true
            var scene = ModelScene()
            scene.materials = [glass]
            scene.meshes = [ModelScene.Mesh(parts: [part])]
            scene.nodes = [ModelScene.Node(mesh: 0)]
            renderer.show(try renderer.makeScene(scene))
            renderer.look = RenderLook(view: .textured, style: .unlit)
            let middle = try renderer.renderOffscreen(width: 120, height: 120).pixel(60, 60)
            // Half through each of two walls leaves a quarter of what is behind them.
            XCTAssertEqual(Int(middle.a), 191, accuracy: 3, "near wall first \(nearFirst)")
        }
    }

    /// Two see-through squares one behind the other come out the same in either file order.
    func testSeeThroughPartsAreDrawnFarthestFirst() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        func shot(_ swap: Bool) throws -> [UInt8] {
            var s = scene(frontOpacity: 0.5, frontFirst: swap)
            s.materials[1].opacity = 0.5
            s.materials[1].doubleSided = true
            renderer.show(try renderer.makeScene(s))
            renderer.look = RenderLook(view: .textured, style: .unlit)
            return try renderer.renderOffscreen(width: 120, height: 120).bytes
        }
        XCTAssertEqual(try shot(false), try shot(true))
    }
}
