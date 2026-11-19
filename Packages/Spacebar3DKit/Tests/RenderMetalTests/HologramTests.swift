import Foundation
import ImportSTL
import ModelCore
@testable import RenderMetal
import simd
import XCTest

final class HologramTests: XCTestCase {
    func testTheTimelineBuildsFromTheMiddleSettlesAndKeepsScanning() {
        let intro = HologramTimeline.introSeconds, delay = HologramTimeline.introDelay
        let start = HologramTimeline(seconds: 0)
        XCTAssertEqual(start.built, 0)
        XCTAssertEqual(start.swirl, 0)
        XCTAssertEqual(start.settled, 0)
        XCTAssertTrue(start.showsExtras)
        XCTAssertLessThan(start.beam, 0, "no scan line during the arrival")

        // Half way the two fronts are about half way to the top and the bottom.
        let half = HologramTimeline(seconds: delay + intro * 0.5)
        XCTAssertEqual(half.built, HologramTimeline.builtWhole * 0.51, accuracy: 0.01)
        XCTAssertEqual(half.swirl, 1)

        // At the end the model stands whole (the fronts are past its top and bottom, which
        // are half a height from the middle) and the swirls are out.
        let end = HologramTimeline(seconds: delay + intro)
        XCTAssertEqual(end.built, HologramTimeline.builtWhole)
        XCTAssertGreaterThan(HologramTimeline.builtWhole, 0.5)
        XCTAssertEqual(end.swirl, 0)

        // The fronts climb steadily and nothing jumps.
        var last = start
        for i in 1...500 {
            let now = HologramTimeline(seconds: Double(i) * 0.01)
            XCTAssertGreaterThanOrEqual(now.built, last.built)
            XCTAssertLessThan(now.built - last.built, 0.004)
            XCTAssertLessThan(abs(now.swirl - last.swirl), 0.08)
            XCTAssertLessThan(abs(now.settled - last.settled), 0.08)
            last = now
        }

        let settled = HologramTimeline(seconds: delay + intro + 3)
        XCTAssertEqual(settled.settled, 1)
        XCTAssertFalse(settled.showsExtras)
        // Three seconds into the outward half of the 20-second cycle.
        XCTAssertEqual(settled.beam, 3.0 / 20, accuracy: 1e-4)

        XCTAssertGreaterThan(HologramTimeline.still.built, 0.5)
        XCTAssertEqual(HologramTimeline.still.settled, 1)
        XCTAssertFalse(HologramTimeline.still.showsExtras)
    }

    func testScanLinesMeetAtMiddleReachOppositeEdgesAndReturnContinuously() {
        let start = HologramTimeline.introDelay + HologramTimeline.introSeconds
        let cycle = HologramTimeline.scanSeconds
        for (fraction, offset) in [(0.0, 0.0), (0.25, 0.25), (0.5, 0.5), (0.75, 0.25), (1.0, 0.0), (1.25, 0.25)] {
            let beam = HologramTimeline(seconds: start + fraction * cycle).beam
            XCTAssertEqual(beam, Float(offset), accuracy: 1e-6)
            XCTAssertEqual((0.5 - beam) + (0.5 + beam), 1, accuracy: 1e-6)
        }
        for turn in [0.5, 1.0] {
            let before = HologramTimeline(seconds: start + turn * cycle - 0.001).beam
            let after = HologramTimeline(seconds: start + turn * cycle + 0.001).beam
            XCTAssertEqual(before, after, accuracy: 1e-6)
        }
        XCTAssertEqual(HologramTimeline.still.beam, 0)
    }

    private func covered(_ image: OffscreenImage) -> Int {
        var n = 0
        for i in stride(from: 3, to: image.bytes.count, by: 4) where image.bytes[i] > 8 { n += 1 }
        return n
    }

    func testTheSwirlsFollowTheModelsWidthAtEachHeight() {
        // A tack on its head: a wide disc at the bottom, a thin pin leaning off to one side above.
        var grains: [SIMD4<Float>] = []
        func point(_ x: Float, _ y: Float, _ z: Float) { grains += [SIMD4(x, y, z, y / 10), SIMD4(0, 0, 0, 0)] }
        for a in 0..<32 { let t = Float(a) / 32 * 2 * .pi; point(cos(t) * 5, 0, sin(t) * 3) }
        point(1.9, 10, 0); point(2.1, 10, 0)
        let framing = Framing(center: SIMD3(0, 5, 0), size: SIMD3(10, 10, 6), distance: 30)
        let bands = Hologram.outline(of: grains, framing: framing)
        XCTAssertEqual(bands.count, Hologram.swirlBands)
        // At the bottom the disc, centred, as wide as it is.
        XCTAssertEqual(bands[0].x, 0, accuracy: 0.05)
        XCTAssertEqual(bands[0].z, 5, accuracy: 0.05)
        XCTAssertEqual(bands[0].w, 3, accuracy: 0.05)
        // At the top the pin: where it is, and no thinner than a ribbon can wind around.
        let top = bands[Hologram.swirlBands - 1]
        XCTAssertEqual(top.x, 2, accuracy: 0.01)
        XCTAssertEqual(top.z, 0.4, accuracy: 0.01)
        XCTAssertEqual(top.w, 0.4, accuracy: 0.01)
        // Between them, where no point was sampled, a steady narrowing.
        for i in 1..<Hologram.swirlBands - 1 {
            XCTAssertLessThan(bands[i].z, bands[i - 1].z + 1e-4)
            XCTAssertGreaterThan(bands[i].z, top.z - 1e-4)
        }
        // With nothing sampled, the whole box.
        XCTAssertEqual(Hologram.outline(of: [], framing: framing)[3], SIMD4(0, 0, 5, 3))
    }

    func testTheShellIsMintSeeThroughAndArrivesOverTime() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(STLReader.scene(from: torusSTL(segments: 48, sides: 24))))
        let w = 320, h = 240

        renderer.look = RenderLook(view: .textured)
        let plain = try renderer.renderOffscreen(width: w, height: h)

        renderer.look = RenderLook(view: .textured, style: .hologram)
        renderer.hologramStill = true
        let still = try renderer.renderOffscreen(width: w, height: h)
        XCTAssertTrue(still.bytes != plain.bytes)
        // Summed over the picture the shell is green before blue before red.
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: still.bytes.count, by: 4) { b += Int(still.bytes[i]); g += Int(still.bytes[i + 1]); r += Int(still.bytes[i + 2]) }
        XCTAssertGreaterThan(g, b)
        XCTAssertGreaterThan(b, r)
        XCTAssertGreaterThan(r, 0)
        // See-through: the glow spreads past the model, but the corners stay clear.
        XCTAssertGreaterThanOrEqual(covered(still), covered(plain))
        XCTAssertLessThan(still.pixel(1, 1).a, 16)
        // Colour never exceeds its coverage, so the picture can be laid over anything.
        for i in stride(from: 0, to: still.bytes.count, by: 4) {
            XCTAssertLessThanOrEqual(max(still.bytes[i], still.bytes[i + 1], still.bytes[i + 2]), still.bytes[i + 3] &+ 1 == 0 ? 255 : still.bytes[i + 3] + 1)
        }

        // The intro is a different picture at every moment.
        renderer.hologramStill = false
        renderer.hologramSeconds = 0.4
        let early = try renderer.renderOffscreen(width: w, height: h)
        renderer.hologramSeconds = 2.2
        let late = try renderer.renderOffscreen(width: w, height: h)
        XCTAssertTrue(early.bytes != still.bytes)
        XCTAssertTrue(late.bytes != early.bytes)

        // Another size, and back: the layer follows, and at rest nothing has moved.
        _ = try renderer.renderOffscreen(width: 200, height: 300)
        renderer.hologramStill = true
        XCTAssertTrue(try renderer.renderOffscreen(width: w, height: h).bytes == still.bytes)
    }

    func testWithNoModelOnlyTheBackgroundIsDrawn() throws {
        let renderer = try MetalRenderer()
        renderer.showGrid = false
        let empty = try renderer.renderOffscreen(width: 64, height: 48)
        renderer.look = RenderLook(style: .hologram)
        XCTAssertTrue(try renderer.renderOffscreen(width: 64, height: 48).bytes == empty.bytes)
    }
}
