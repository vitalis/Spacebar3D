import SwiftUI
import XCTest
@testable import ViewerUI

/// The mark as it is drawn: the canvas is rendered into pixels and read back.
@MainActor
final class NeonMarkDrawingTests: XCTestCase {
    private let size = CGSize(width: 300, height: 300)

    private func mark(at time: Double, still: Bool = false) throws -> Picture {
        let view = Canvas { context, size in NeonMark.draw(&context, size: size, time: time, still: still) }
        return try XCTUnwrap(Render.image(view, size: size))
    }

    func testNothingIsDrawnBeforeTheMarkHasStartedToComeForward() throws {
        XCTAssertEqual(try mark(at: 0).drawn, 0, "it comes out of the dark")
    }

    func testTheMarkGrowsIntoViewAndThenStays() throws {
        let early = try mark(at: 0.1, still: true), arrived = try mark(at: NeonMark.arrival, still: true)
        XCTAssertGreaterThan(early.drawn, 0)
        XCTAssertGreaterThan(arrived.light, early.light, "it is brighter the further it has come")
        // With motion reduced it is a still picture: any later moment is the same one.
        XCTAssertFalse(arrived.differs(from: try mark(at: 7, still: true)))
        // And it stands in the middle of its picture, its light spilling into the margin.
        let box = try XCTUnwrap(arrived.extent)
        XCTAssertLessThan(abs((box.minX + box.maxX) - Int(size.width)), 40)
        XCTAssertLessThan(abs((box.minY + box.maxY) - Int(size.height)), 60)
    }

    func testABeadOfLightRunsTheRailsOnceTheMarkIsThere() throws {
        let still = try mark(at: 1.0, still: true), moving = try mark(at: 1.0)
        XCTAssertGreaterThan(moving.light, still.light, "the bead and its tail add light")
        let later = try mark(at: 1.0 + NeonMark.lap / 3)
        XCTAssertTrue(moving.differs(from: later), "and it moves")
        // Still arriving: no bead yet, so with or without motion it is the same except for its breath.
        XCTAssertGreaterThan(try mark(at: 0.2).drawn, 0)
    }

    func testTheMarkIsOnlyAsLargeAsItsSpaceAllows() throws {
        // Smaller than its own margin there is no room: it is still drawn, and does not fail.
        let view = Canvas { context, size in NeonMark.draw(&context, size: size, time: 1, still: true) }
        XCTAssertNotNil(Render.image(view, size: CGSize(width: 40, height: 40)))
    }

    func testTheMarkViewIsAHiddenPictureThatFillsItsMarginToo() throws {
        let hosted = Render.hosted(NeonMark().frame(width: 132, height: 132).padding(NeonMark.margin), size: CGSize(width: 244, height: 244), seconds: 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(hosted.picture).drawn, 0)
        XCTAssertTrue(try NeonMark().inspect().timelineView().accessibilityHidden(), "a picture, not a control")
    }
}
