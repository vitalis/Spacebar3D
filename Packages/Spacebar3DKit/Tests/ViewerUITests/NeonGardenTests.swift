import SwiftUI
import ViewInspector
import XCTest
@testable import ViewerUI

/// The viewer's palette: the colours are the design system's, and they can be read.
@MainActor
final class NeonGardenTests: XCTestCase {
    func testTheColoursAreTheDesignSystems() {
        XCTAssertEqual(NeonGarden.background.hex, "#07110c")
        XCTAssertEqual(NeonGarden.surface.hex, "#0e1c14")
        XCTAssertEqual(NeonGarden.text.hex, "#f1f4f0")
        XCTAssertEqual(NeonGarden.signal.hex, "#cfff2e")
        XCTAssertEqual(NeonGarden.mint.hex, "#a6e3a7")
        XCTAssertEqual(NeonGarden.info.hex, "#b8d3ff")
        XCTAssertEqual(NativeViewerSettings.defaultBackground, NeonGarden.background.hex, "a model stands in the palette's darkest green")
    }

    func testTextAndStatesCanBeReadOnEverySurface() {
        let surfaces = [NeonGarden.background, NeonGarden.surface, NeonGarden.surface2, NeonGarden.surface3]
        for surface in surfaces {
            for ink in [NeonGarden.text, NeonGarden.text2, NeonGarden.mint, NeonGarden.info] {
                XCTAssertGreaterThanOrEqual(ink.contrast(with: surface), 4.5, "\(ink.hex) on \(surface.hex)")
            }
            // Edges of controls and the gizmo's axes are shapes, which need 3:1.
            for mark in [NeonGarden.borderStrong, NeonGarden.warm, NeonGarden.success, NeonGarden.info] {
                XCTAssertGreaterThanOrEqual(mark.contrast(with: surface), 3, "\(mark.hex) on \(surface.hex)")
            }
        }
        XCTAssertGreaterThanOrEqual(NeonGarden.background.contrast(with: NeonGarden.signal), 7, "the Signal's label")
        XCTAssertGreaterThanOrEqual(NeonGarden.background.contrast(with: NeonGarden.signalPressed), 7)
    }

    func testTheGizmosAxesHaveThreeColoursOfThePalette() {
        XCTAssertEqual(GizmoView.tone("X"), NeonGarden.warm)
        XCTAssertEqual(GizmoView.tone("Y"), NeonGarden.success)
        XCTAssertEqual(GizmoView.tone("Z"), NeonGarden.info)
    }

    func testSegmentsChooseAndSayWhichIsChosen() throws {
        var chosen = "b"
        let binding = Binding(get: { chosen }, set: { chosen = $0 })
        let segments = GardenSegments(label: "Pick", options: [("a", "First"), ("b", "Second")], selection: binding)
        // The buttons are drawn; assistive technology is given one segmented control.
        XCTAssertEqual(try segments.inspect().findAll(ViewType.Button.self).count, 2)
        try segments.inspect().find(button: "First").tap()
        XCTAssertEqual(chosen, "a")
    }

    func testTheAppsMarkComesForwardAndABeadRunsItsRails() {
        // The picture is in the package, for the app and for the preview alike.
        XCTAssertNotNil(Bundle.module.url(forResource: "Mark", withExtension: "png"), "tests have their own bundle")
        XCTAssertNotNil(NSImage(contentsOf: try XCTUnwrap(Bundle(for: NativeViewerModel.self).url(forResource: "Mark", withExtension: "png") ?? markURL())))
        // It comes forward once, quickly, and then is there.
        XCTAssertEqual(NeonMark.arrived(at: 0), 0)
        XCTAssertGreaterThan(NeonMark.arrived(at: 0.2), 0.5, "most of the way early: it eases out")
        XCTAssertEqual(NeonMark.arrived(at: NeonMark.arrival), 1)
        XCTAssertEqual(NeonMark.arrived(at: 9), 1)
        XCTAssertLessThan(NeonMark.arrival, 0.6, "a loader must not make the wait longer")
        // The bead keeps to the rails, all within the picture, and comes back to where it began.
        XCTAssertEqual(NeonMark.onRail(0), NeonMark.rail[0])
        XCTAssertEqual(NeonMark.onRail(1).x, NeonMark.rail[0].x, accuracy: 0.0001)
        XCTAssertEqual(NeonMark.onRail(2.25).x, NeonMark.onRail(0.25).x, accuracy: 0.0001)
        for step in 0..<100 {
            let p = NeonMark.onRail(Double(step) / 100)
            XCTAssertTrue((0.1...0.9).contains(p.x) && (0.1...1).contains(p.y), "\(p)")
        }
        // Along the top it runs level, from left to right.
        XCTAssertEqual(NeonMark.onRail(0.05).y, NeonMark.rail[0].y, accuracy: 0.0001)
        XCTAssertGreaterThan(NeonMark.onRail(0.05).x, NeonMark.rail[0].x)
    }

    /// Where the package keeps the mark, whichever bundle the build put it in.
    private func markURL() -> URL? {
        Bundle.allBundles.compactMap { $0.url(forResource: "Mark", withExtension: "png") }.first
            ?? Bundle.allBundles.flatMap { ($0.urls(forResourcesWithExtension: "bundle", subdirectory: nil) ?? []) }
                .compactMap { Bundle(url: $0)?.url(forResource: "Mark", withExtension: "png") }.first
    }

    func testTheStatisticsStandOnTheBarsLineAndTheBarMakesRoom() {
        typealias Row = ControlsVisibility.BottomRow
        let bar = CGSize(width: 480, height: 48), edge = ControlsVisibility.edge
        func row(_ width: CGFloat, _ bar: CGSize = CGSize(width: 480, height: 48)) -> Row { ControlsVisibility.bottomRow(width: width, bar: bar, statistics: 170) }
        XCTAssertEqual(row(1280), Row(statisticsFoot: edge, barShift: 0, animationFoot: edge + 56))
        XCTAssertEqual(row(868), Row(statisticsFoot: edge, barShift: 0, animationFoot: edge + 56), "just room: 868 = 480 + 2 * (170 + 16 + 8)")
        // Quick Look's usual width: the bar moves left by what is missing.
        XCTAssertEqual(row(810), Row(statisticsFoot: edge, barShift: 29, animationFoot: edge + 56))
        // Both just fit side by side at 16 + 480 + 8 + 170 + 16 = 690; below that, above the row.
        XCTAssertEqual(row(690), Row(statisticsFoot: edge, barShift: 89, animationFoot: edge + 56))
        XCTAssertEqual(row(689), Row(statisticsFoot: edge + bar.height + 8, barShift: 0, animationFoot: edge + 56))
        XCTAssertEqual(row(600, .zero), Row(statisticsFoot: edge, barShift: 0, animationFoot: edge), "no bar, no question")
    }

    func testStatisticsClearBothBottomBarsAtNarrowWidths() {
        let bar = CGSize(width: 630, height: 52)
        let animation = CGSize(width: 450, height: 48)
        let row = ControlsVisibility.bottomRow(width: 810, bar: bar, animation: animation, statistics: 180)
        XCTAssertEqual(row.animationFoot, 76)
        XCTAssertEqual(row.statisticsFoot, 132)
        XCTAssertEqual(row.barShift, 0)

        let widerAnimation = ControlsVisibility.bottomRow(width: 810, bar: CGSize(width: 400, height: 52),
                                                         animation: CGSize(width: 500, height: 48), statistics: 180)
        XCTAssertGreaterThan(widerAnimation.barShift, 0)
        let barRight = (810 + 500) / 2 - widerAnimation.barShift
        XCTAssertLessThanOrEqual(barRight + 8, 810 - ControlsVisibility.edge - 180)
    }

    func testTheCordFrameWandersButStaysByItsRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 260)
        let frame = WavyFrame(radius: 18, amplitude: 2, wavelength: 46, phase: 0.3)
        let bounds = frame.path(in: rect).boundingRect
        XCTAssertTrue(rect.insetBy(dx: -2.01, dy: -2.01).contains(bounds), "\(bounds)")
        XCTAssertGreaterThan(bounds.width, rect.width, "it does wander")
        let inner = frame.inset(by: 5).path(in: rect).boundingRect
        XCTAssertTrue(bounds.contains(inner))
        XCTAssertTrue(frame.path(in: CGRect(x: 0, y: 0, width: 3, height: 3)).isEmpty, "nothing to draw in no room")
    }

    func testThePaperIsTheSameEveryTime() {
        let size = CGSize(width: 500, height: 900)
        let once = GraphPaper.strokes(size: size, spacing: 44), again = GraphPaper.strokes(size: size, spacing: 44)
        XCTAssertEqual(once.map(\.0), again.map(\.0))
        XCTAssertEqual(once.map(\.1), again.map(\.1))
        XCTAssertEqual(once.count, 11 + 20, "one piece of each line")
        for (from, to) in once { XCTAssertTrue(from.x == to.x || from.y == to.y, "lines run straight") }
        XCTAssertTrue(GraphPaper.strokes(size: size, spacing: 0).isEmpty)
        var a = Seeded(1), b = Seeded(1), c = Seeded(2)
        let first = a.next()
        XCTAssertEqual(first, b.next())
        XCTAssertNotEqual(first, c.next())
        XCTAssertTrue((0..<1).contains(first))
    }

    func testTheGizmosEndsAreLargerTheNearerTheyAre() {
        func handle(_ positive: Bool, _ depth: Float) -> GizmoHandle {
            GizmoHandle(preset: .front, axis: "Z", positive: positive, point: .zero, depth: depth)
        }
        XCTAssertGreaterThan(GizmoView.radius(handle(true, 1)), GizmoView.radius(handle(true, -1)))
        XCTAssertGreaterThan(GizmoView.radius(handle(true, -1)), GizmoView.radius(handle(false, 1)), "a letter is always larger than a far end")
        XCTAssertEqual(GizmoView.radius(handle(true, 9)), GizmoView.radius(handle(true, 1)))
    }

    func testThreeIconsSayWhatTheyDo() {
        XCTAssertEqual(ViewsBar.wireframeIcon, "cube.transparent", "a wire cube, not the floor's grid")
        let icons = Dictionary(uniqueKeysWithValues: StyleButton.all.map { ($0.label, $0.icon) })
        XCTAssertEqual(icons["Unshaded style"], "circle.lefthalf.filled")
        XCTAssertEqual(icons["Hologram style"], "sparkles")
        XCTAssertEqual(Set(icons.values).count, StyleButton.all.count, "no two styles share a picture")
        XCTAssertFalse(icons.values.contains(ViewsBar.wireframeIcon))
    }
}

extension NeonGardenTests {
    /// The panels are Liquid Glass, and the palette's own solid surface when the system
    /// is asked for less transparency.
    func testThePanelsAreSolidOnlyWhenTransparencyIsReduced() {
        XCTAssertTrue(LiquidGlass<Circle>.isSolid(reduceTransparency: true))
        XCTAssertFalse(LiquidGlass<Circle>.isSolid(reduceTransparency: false))
    }
}

extension NeonGardenTests {
    func testThePanelsAreSolidWhereGlassCannotBeDrawn() {
        XCTAssertTrue(LiquidGlass<Circle>.isSolid(reduceTransparency: false, glassOff: true))
    }
}
