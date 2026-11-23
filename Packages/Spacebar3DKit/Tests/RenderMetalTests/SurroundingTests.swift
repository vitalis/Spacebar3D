import ImportRouter
import ModelCore
import simd
import XCTest
@testable import RenderMetal

/// Where the model stands changes its light; turning the light moves it round the model.
final class SurroundingTests: XCTestCase {
    func testTheGlasshouseIsTheLightAModelHasAlwaysHad() {
        let l = Surrounding.glasshouse.light
        XCTAssertEqual(l.sun, simd_normalize(SIMD3<Float>(1, 2, 1.5)))
        XCTAssertEqual(l.sunColor, SIMD3(repeating: 2))
        XCTAssertEqual(l.fillColor, SIMD3(repeating: 0.6))
        XCTAssertEqual(l.glow, 0)
        XCTAssertEqual(Surrounding.allCases.map(\.title), ["Glasshouse", "Dawn", "Noon", "Golden Hour", "Overcast", "Moonlit", "Neon"])
    }

    func testTurningTheLightKeepsItsHeightAndComesRoundAgain() {
        for surrounding in Surrounding.allCases {
            let still = surrounding.light, quarter = surrounding.light(turned: .pi / 2), round = surrounding.light(turned: 2 * .pi)
            XCTAssertEqual(quarter.sun.y, still.sun.y, accuracy: 1e-5)
            XCTAssertEqual(simd_length(quarter.sun), 1, accuracy: 1e-5)
            XCTAssertGreaterThan(simd_distance(quarter.sun, still.sun), 0.2, surrounding.rawValue)
            XCTAssertEqual(simd_distance(round.sun, still.sun), 0, accuracy: 1e-4)
            XCTAssertEqual(quarter.sky, still.sky)
        }
    }

    func testThePanoramaIsAPictureWithinRangeThatTurnsWithTheLight() {
        for surrounding in Surrounding.allCases {
            var differs = false
            for y in 0..<8 { for x in 0..<16 {
                let u = (Float(x) + 0.5) / 16, v = (Float(y) + 0.5) / 8
                let c = surrounding.panorama(u: u, v: v)
                for part in [c.x, c.y, c.z] { XCTAssertTrue((0...1).contains(part), surrounding.rawValue) }
                if simd_distance(c, surrounding.panorama(u: u, v: v, turned: 1.5)) > 0.02 { differs = true }
            } }
            XCTAssertTrue(differs, "\(surrounding.rawValue): the lights are in the picture")
        }
        // Up is lighter than down in daylight.
        XCTAssertGreaterThan(Surrounding.noon.panorama(u: 0.1, v: 0.05).z, Surrounding.noon.panorama(u: 0.1, v: 0.95).z)
    }

    func testAModelLooksDifferentInEverySurroundingAndAsTheLightTurns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cube.obj")
        try """
        v -1 -1 -1\nv 1 -1 -1\nv 1 1 -1\nv -1 1 -1\nv -1 -1 1\nv 1 -1 1\nv 1 1 1\nv -1 1 1
        f 1 2 3 4\nf 5 8 7 6\nf 1 5 6 2\nf 2 6 7 3\nf 3 7 8 4\nf 5 1 4 8
        """.write(to: url, atomically: true, encoding: .utf8)
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.showShadow = false
        renderer.show(try renderer.makeScene(try ImportRouter.load(url, format: .obj)))
        renderer.look = RenderLook(view: .textured)
        renderer.camera.rotate(yaw: 0.6, pitch: 0.4)
        func shot() throws -> [UInt8] { try renderer.renderOffscreen(width: 120, height: 90).bytes }
        var seen: [[UInt8]] = []
        for surrounding in Surrounding.allCases {
            renderer.surrounding = surrounding
            let image = try shot()
            XCTAssertFalse(seen.contains(image), surrounding.rawValue)
            seen.append(image)
        }
        renderer.surrounding = .glasshouse
        renderer.lightRotation = 0
        let front = try shot()
        renderer.lightRotation = 2
        XCTAssertNotEqual(try shot(), front, "the light has moved")
        renderer.lightRotation = 2 * .pi
        let round = try shot()
        let off = zip(round, front).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertEqual(off, 0, "once round, it is where it was")
    }
}
