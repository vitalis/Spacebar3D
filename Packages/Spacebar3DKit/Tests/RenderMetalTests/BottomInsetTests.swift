import Foundation
import ModelCore
import RenderMetal
import simd
import XCTest

final class BottomInsetTests: XCTestCase {
    /// A square facing the camera.
    private var square: ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        return scene
    }

    /// The rows and columns the square covers, and the colour in its middle.
    private func extent(inset: Float, flat: Bool = false) throws -> (top: Int, bottom: Int, left: Int, right: Int, middle: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(square))
        renderer.look = RenderLook(view: .solid, flat: flat)
        renderer.bottomInset = inset
        let image = try renderer.renderOffscreen(width: 200, height: 200)
        var top = 200, bottom = -1, left = 200, right = -1
        for y in 0..<200 { for x in 0..<200 where image.pixel(x, y).a == 255 { top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x) } }
        return (top, bottom, left, right, image.pixel((left + right) / 2, (top + bottom) / 2))
    }

    func testThePictureIsMadeSmallerAndMovedUpClearOfTheControls() throws {
        let whole = try extent(inset: 0)
        XCTAssertEqual((whole.top + whole.bottom) / 2, 100, accuracy: 1)
        let clear = try extent(inset: 0.25)
        // In the middle of the three quarters above the controls, three quarters the size.
        XCTAssertEqual((clear.top + clear.bottom) / 2, 75, accuracy: 1)
        XCTAssertEqual((clear.left + clear.right) / 2, 100, accuracy: 1)
        XCTAssertEqual(Double(clear.bottom - clear.top) / Double(whole.bottom - whole.top), 0.75, accuracy: 0.02)
        XCTAssertEqual(Double(clear.right - clear.left) / Double(whole.right - whole.left), 0.75, accuracy: 0.02)
        XCTAssertLessThan(clear.bottom, 150, "nothing of it under the controls")
        // More than the view could give is not taken, and nonsense is nothing.
        XCTAssertGreaterThan(try extent(inset: 5).bottom, 0)
        XCTAssertEqual(try extent(inset: .nan).top, whole.top)
    }

    func testTheSurfaceIsLitTheSameWhereverThePictureIs() throws {
        // Flat shading finds the surface's direction from the picture itself.
        let whole = try extent(inset: 0, flat: true), clear = try extent(inset: 0.25, flat: true)
        XCTAssertEqual(Int(whole.middle.r), Int(clear.middle.r), accuracy: 2)
        XCTAssertEqual(Int(whole.middle.g), Int(clear.middle.g), accuracy: 2)
        XCTAssertEqual(Int(whole.middle.b), Int(clear.middle.b), accuracy: 2)
    }

    /// The Hologram style draws with shaders of its own; it keeps clear of the controls too.
    func testTheHologramIsMovedUpClearOfTheControlsToo() throws {
        func rows(inset: Float) throws -> (top: Int, bottom: Int, left: Int, right: Int) {
            let renderer = try MetalRenderer()
            renderer.showGrid = false
            renderer.show(try renderer.makeScene(square))
            renderer.look = RenderLook(view: .solid, style: .hologram)
            // Whole and at rest, so the two pictures differ only by where they are.
            renderer.hologramStill = true
            renderer.bottomInset = inset
            let image = try renderer.renderOffscreen(width: 200, height: 200)
            // The shell is mint: far greener than the dark background is anywhere.
            var top = 200, bottom = -1, left = 200, right = -1
            for y in 0..<200 { for x in 0..<200 where Int(image.pixel(x, y).g) > Int(image.pixel(x, y).r) + 40 { top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x) } }
            return (top, bottom, left, right)
        }
        let whole = try rows(inset: 0), clear = try rows(inset: 0.25)
        XCTAssertGreaterThan(whole.bottom, whole.top, "the shell is drawn")
        XCTAssertEqual((whole.top + whole.bottom) / 2, 100, accuracy: 3)
        XCTAssertEqual((clear.top + clear.bottom) / 2, 75, accuracy: 3)
        XCTAssertEqual((clear.left + clear.right) / 2, 100, accuracy: 3)
        XCTAssertEqual(Double(clear.bottom - clear.top) / Double(whole.bottom - whole.top), 0.75, accuracy: 0.05)
        XCTAssertLessThan(clear.bottom, 150, "nothing of it under the controls")
    }
}
