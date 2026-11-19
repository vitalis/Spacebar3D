import SwiftUI
import ViewInspector
import XCTest
@testable import ViewerUI

/// The hand in the look, drawn: cord, tape, squared paper, and the light a model opens in.
@MainActor
final class ScrapbookTests: XCTestCase {
    func testTheCordIsLitInItsToneAndAlongItsEdge() throws {
        let size = CGSize(width: 240, height: 160)
        let picture = try XCTUnwrap(Render.image(NeonCordFrame().padding(14), size: size))
        // On the cord (the middle of the top side, within the wander) the warm tone shows; the middle is bare.
        let onCord = (8...20).map { picture.pixel(120, $0) }
        XCTAssertTrue(onCord.contains { $0.r > 200 && $0.r > $0.b }, "warm: red leads")
        XCTAssertEqual(picture.pixel(120, 80).a, 0, "nothing inside the frame")
    }

    func testTheCordDrawsItselfAndTheToneCanBeChosen() throws {
        let size = CGSize(width: 240, height: 160)
        let empty = try XCTUnwrap(Render.image(NeonCordFrame(drawn: 0).padding(14), size: size))
        let half = try XCTUnwrap(Render.image(NeonCordFrame(drawn: 0.5).padding(14), size: size))
        let whole = try XCTUnwrap(Render.image(NeonCordFrame(drawn: 1).padding(14), size: size))
        XCTAssertLessThan(empty.light, half.light)
        XCTAssertLessThan(half.light, whole.light)
        let mint = try XCTUnwrap(Render.image(NeonCordFrame(tone: NeonGarden.mint, gauge: 2, gap: 8, radius: 10, intensity: 0.5).padding(14), size: size))
        XCTAssertTrue(whole.differs(from: mint))
        XCTAssertTrue((8...20).map { mint.pixel(120, $0) }.contains { $0.g > $0.r }, "mint: green leads")
    }

    func testTapeIsTornAtItsEndsAndTakesItsTone() throws {
        let picture = try XCTUnwrap(Render.image(TapeStrip(tone: NeonGarden.warm2, angle: 0).padding(6), size: CGSize(width: 120, height: 40)))
        XCTAssertGreaterThan(picture.drawn, 120 * 28 / 2, "a strip of tape")
        let middle = picture.pixel(60, 20)
        XCTAssertTrue(middle.r > middle.g && middle.b > middle.g, "pink: red and blue over green \(middle)")
        // The outline keeps to the rect, with teeth at both ends.
        let rect = CGRect(x: 0, y: 0, width: 100, height: 30)
        let path = TapeStrip.Torn().path(in: rect)
        XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.maxX, 100, accuracy: 0.01)
        // A tall strip has more teeth than a short one.
        func points(_ height: CGFloat) -> Int {
            var count = 0
            TapeStrip.Torn().path(in: CGRect(x: 0, y: 0, width: 100, height: height)).forEach { _ in count += 1 }
            return count
        }
        XCTAssertGreaterThan(points(90), points(30))
    }

    func testTheTapeIsTurnedByItsAngle() throws {
        let flat = try XCTUnwrap(Render.image(TapeStrip(angle: 0).padding(20), size: CGSize(width: 140, height: 60)))
        let askew = try XCTUnwrap(Render.image(TapeStrip(angle: -12).padding(20), size: CGSize(width: 140, height: 60)))
        XCTAssertTrue(flat.differs(from: askew))
    }

    func testTheLabelIsAHeadingInCapitalsOnTape() throws {
        let label = TapeLabel("Shapes")
        let view = try label.inspect()
        XCTAssertEqual(try view.find(ViewType.Text.self).string(), "Shapes")
        let picture = try XCTUnwrap(Render.image(TapeLabel("Shapes", tone: NeonGarden.warm2, angle: 0), size: CGSize(width: 140, height: 40)))
        XCTAssertGreaterThan(picture.drawn, 0)
    }

    func testThePaperIsFaintMintLinesThatKeepToTheSheet() throws {
        let size = CGSize(width: 200, height: 200)
        let picture = try XCTUnwrap(Render.image(GraphPaper(spacing: 40), size: size))
        XCTAssertGreaterThan(picture.drawn, 0)
        // Each line is a piece of a line on a grid, and its colour is faint mint.
        let strokes = GraphPaper.strokes(size: size, spacing: 40)
        let (from, to) = strokes[0]
        XCTAssertEqual(from.x, 20)
        let mid = picture.pixel(Int(from.x), Int((from.y + to.y) / 2))
        XCTAssertGreaterThan(mid.a, 0)
        XCTAssertLessThan(mid.a, 64, "faint: nine in a hundred")
        XCTAssertTrue(mid.g >= mid.r, "mint")
        XCTAssertEqual(try XCTUnwrap(Render.image(GraphPaper(spacing: 2), size: size)).drawn, 0, "too close for lines")
    }

    // MARK: The light a model opens in

    func testTheLightOpensWhenThereIsAModelAndFadesAgain() throws {
        let model = NativeViewerModel()
        model.visibility = ControlsVisibility(size: CGSize(width: 900, height: 700))
        let before = Render.hosted(OpeningLight(model: model), size: CGSize(width: 500, height: 500), seconds: 0.05).picture
        XCTAssertEqual(try XCTUnwrap(before).drawn, 0, "nothing before there is a model to open on")
        // The model arrives: a breath of light opens, mid-way in the first moments.
        model.message = "nothing to see"
        let during = Render.hosted(OpeningLight(model: model), size: CGSize(width: 500, height: 500), seconds: 0.05).picture
        XCTAssertNotNil(during)
    }

    func testTheLightCanBeHostedBeforeAndAfterAModelIsThere() throws {
        let model = NativeViewerModel()
        model.visibility = ControlsVisibility(size: CGSize(width: 900, height: 700))
        let host = Render.hosted(OpeningLight(model: model), size: CGSize(width: 500, height: 500), seconds: 0.05).host
        // Becoming ready after it appeared opens it as well.
        model.message = "ready"
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        model.statistics = nil
        // With the controls out of sight (a small preview) nothing is drawn at all.
        model.visibility = ControlsVisibility(size: CGSize(width: 200, height: 150))
        let small = Render.hosted(OpeningLight(model: model), size: CGSize(width: 500, height: 500), seconds: 0.2).picture
        XCTAssertEqual(try XCTUnwrap(small).drawn, 0)
    }
}
