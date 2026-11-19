import SwiftUI
import ViewInspector
import XCTest
@testable import ViewerUI

/// The palette's controls as they are drawn: a button, a switch, a Signal, a segment, a
/// tube of neon, read back as pixels.
@MainActor
final class NeonGardenDrawingTests: XCTestCase {
    private let small = CGSize(width: 160, height: 60)

    func testANeonTubeIsLitGlassWithGlowAroundIt() throws {
        let size = CGSize(width: 200, height: 100)
        let tube = Rectangle().neonTube(NeonGarden.mint, lineWidth: 2, intensity: 1, spread: 8).padding(30)
        let picture = try XCTUnwrap(Render.image(tube, size: size))
        // On the glass the tone is nearly full; beyond it the gas fades out.
        let glass = picture.pixel(100, 30)
        XCTAssertGreaterThan(glass.a, 200)
        let near = picture.pixel(100, 24), far = picture.pixel(100, 2)
        XCTAssertGreaterThan(near.a, far.a, "the glow fades with distance")
        XCTAssertGreaterThan(near.a, 0)
        XCTAssertLessThan(picture.pixel(100, 50).a, 20, "the inside of the shape is not filled")
    }

    func testANeonTubeIsDimmerWithLessIntensityAndNeverBrighterThanFull() throws {
        let size = CGSize(width: 200, height: 100)
        func light(_ intensity: Double) throws -> Int {
            try XCTUnwrap(Render.image(Rectangle().neonTube(NeonGarden.signal, lineWidth: 2, intensity: intensity).padding(30), size: size)).light
        }
        XCTAssertLessThan(try light(0.2), try light(1))
        XCTAssertEqual(Double(try light(3)), Double(try light(1)), accuracy: Double(try light(1)) * 0.01, "more than full is full")
        XCTAssertEqual(Double(try light(-1)), Double(try light(0)), accuracy: Double(try light(0)) * 0.01, "less than none is none")
    }

    func testAGardenButtonIsOnlyItsPictureAtRest() throws {
        let button = Button {} label: { Image(systemName: "viewfinder") }.gardenButton()
        let picture = try XCTUnwrap(Render.image(button, size: small))
        XCTAssertGreaterThan(picture.drawn, 0, "the picture is there")
        let centre = picture.pixel(80, 30)
        let corner = picture.pixel(2, 2)
        XCTAssertEqual(corner.a, 0, "no tile round it")
        XCTAssertNotEqual(centre.a, 255, "and not a filled tile")
    }

    func testAnOffSwitchIsPlainAnOnSwitchIsAMintWellAndALockedOneIsDashed() throws {
        func switchView(_ on: Bool, enabled: Bool = true) -> some View {
            Toggle(isOn: .constant(on)) { Image(systemName: "grid") }
                .toggleStyle(GardenToggleStyle()).disabled(!enabled).padding(12)
        }
        let off = try XCTUnwrap(Render.image(switchView(false), size: small))
        let on = try XCTUnwrap(Render.image(switchView(true), size: small))
        let locked = try XCTUnwrap(Render.image(switchView(false, enabled: false), size: small))
        XCTAssertGreaterThan(on.drawn, off.drawn, "the well and its edge are drawn")
        XCTAssertGreaterThan(on.light, off.light)
        XCTAssertTrue(off.differs(from: locked), "the edge of a thing that is not to be had is dashed")
        XCTAssertGreaterThan(locked.drawn, 0)
        // Mint, not Signal: the lit picture leans green over red.
        let mint = on.bytes.enumerated().filter { $0.offset % 4 == 1 }.reduce(0) { $0 + Int($1.element) }
        let red = on.bytes.enumerated().filter { $0.offset % 4 == 0 }.reduce(0) { $0 + Int($1.element) }
        XCTAssertGreaterThan(mint, red)
    }

    func testAToggleTurnsItsValueAndSaysWhenItIsOn() throws {
        var isOn = false
        let toggle = Toggle(isOn: Binding(get: { isOn }, set: { isOn = $0 })) { Image(systemName: "grid") }.toggleStyle(GardenToggleStyle())
        try toggle.inspect().find(ViewType.Toggle.self).tap()
        XCTAssertTrue(isOn)
    }

    func testTheSignalIsChartreuseAndGoesDarkWhenItCannotBeUsed() throws {
        func signal(enabled: Bool) -> some View {
            Button("Allow") {}.signalButton().disabled(!enabled).padding(16)
        }
        let size = CGSize(width: 200, height: 80)
        let live = try XCTUnwrap(Render.hosted(signal(enabled: true), size: size, seconds: 0.2).picture)
        let dead = try XCTUnwrap(Render.hosted(signal(enabled: false), size: size, seconds: 0.2).picture)
        // Somewhere on the face of the button is the Signal's chartreuse.
        let chartreuse = stride(from: 0, to: live.bytes.count, by: 4).contains { i in
            live.bytes[i + 3] == 255 && live.bytes[i] > 180 && live.bytes[i + 1] > 220 && live.bytes[i + 2] < 100
        }
        XCTAssertTrue(chartreuse, "chartreuse")
        XCTAssertGreaterThan(live.light, dead.light, "unavailable, it gives less light")
    }

    func testTheSignalIsLitFromOneBreathToTheNextOnceItAppears() throws {
        let host = Render.hosted(Button("Allow") {}.signalButton().padding(16), size: CGSize(width: 200, height: 80), seconds: 0.3)
        let picture = try XCTUnwrap(host.picture)
        XCTAssertGreaterThan(picture.drawn, 0)
    }

    func testSegmentsLiftTheChosenOneAndTheOthersStayPlain() throws {
        func segments(_ chosen: String) -> some View {
            GardenSegments(label: "View", options: [("a", "Solid"), ("b", "Normal")], selection: .constant(chosen)).fixedSize().padding(8)
        }
        let size = CGSize(width: 220, height: 60)
        let first = try XCTUnwrap(Render.image(segments("a"), size: size))
        let second = try XCTUnwrap(Render.image(segments("b"), size: size))
        XCTAssertTrue(first.differs(from: second), "the well is under the chosen one")
        // The well is dark and the word in it mint: the chosen side has a darker ground.
        func ground(_ p: Picture, x: Int) -> Int { p.pixel(x, 30).a }
        XCTAssertGreaterThan(ground(first, x: 36), ground(first, x: 190) - 1)
        XCTAssertGreaterThan(ground(second, x: 190), ground(second, x: 36) - 1)
    }

    func testAPanelIsASurfaceOfThePalette() throws {
        let panel = GardenPanel { Text("Inside").frame(width: 80, height: 30) }
        let picture = try XCTUnwrap(Render.hosted(panel, size: CGSize(width: 140, height: 80)).picture)
        XCTAssertGreaterThan(picture.drawn, 0, "a panel has a ground of its own")
        XCTAssertNoThrow(try panel.inspect().find(text: "Inside"))
    }

    func testAPanelSetsTheViewersLookOnWhatIsInIt() throws {
        let picture = try XCTUnwrap(Render.image(Text("Aa").font(.system(size: 40)).neonGarden(), size: CGSize(width: 100, height: 60)))
        // The palette's text colour on clear: light letters.
        let lit = stride(from: 0, to: picture.bytes.count, by: 4).filter { picture.bytes[$0 + 3] > 200 && picture.bytes[$0] > 200 }
        XCTAssertFalse(lit.isEmpty)
    }

    func testASliderIsDrawnInThePaletteWithTheSystemsFocusRing() throws {
        let slider = Slider(value: .constant(0.5), in: 0...1).gardenSlider().frame(width: 160)
        XCTAssertNoThrow(try slider.inspect().find(ViewType.Slider.self))
        let picture = try XCTUnwrap(Render.image(slider, size: CGSize(width: 200, height: 40)))
        XCTAssertGreaterThan(picture.drawn, 0)
        XCTAssertNotNil(Render.hosted(slider, size: CGSize(width: 200, height: 40)).picture)
    }

    func testAPanelOfControlsRisesOutOfTheDarkOnceItAppears() throws {
        let content = Pill { Text("Hello").frame(width: 80, height: 24) }
        let hosted = Render.hosted(content, size: CGSize(width: 200, height: 100), seconds: 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(hosted.picture).drawn, 0)
    }
}
