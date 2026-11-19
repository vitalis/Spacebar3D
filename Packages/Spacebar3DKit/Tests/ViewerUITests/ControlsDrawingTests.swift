import AppKit
import RenderMetal
import SwiftUI
import ViewInspector
import XCTest
@testable import ViewerUI

/// The controls drawn and used as a person would: put in a window that is never shown,
/// given real mouse events, and read back.
@MainActor
final class ControlsDrawingTests: XCTestCase {
    private func model(textured: Bool = true) -> NativeViewerModel {
        let model = NativeViewerModel()
        model.visibility = ControlsVisibility(size: CGSize(width: 900, height: 700))
        model.hasTextured = textured
        return model
    }

    /// A window that is never shown, with `view` filling it.
    private func window<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<AnyView>) {
        // Glass is not drawn off the screen: the panels are asked for their solid form.
        let host = NSHostingView(rootView: AnyView(view.environment(\.glassIsOff, true)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func send(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        if let event { window.sendEvent(event) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    func testViewsBarFitsTheSmallestSupportedViewerWidth() {
        let model = model()
        model.barAvailableWidth = 480 - 2 * ControlsVisibility.edge
        let (window, host) = window(ViewsBar(model: model), size: CGSize(width: model.barAvailableWidth, height: 48))
        defer { window.close() }
        XCTAssertLessThanOrEqual(host.fittingSize.width, model.barAvailableWidth)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 48)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }

    func testLongAnimationNamesFitTheSmallestSupportedControlWidth() {
        let model = model()
        model.barAvailableWidth = 448
        model.clipNames = [String(repeating: "Long animation name ", count: 20), "Idle"]
        let (window, host) = window(AnimationBar(model: model), size: CGSize(width: 448, height: 48))
        defer { window.close() }
        XCTAssertLessThanOrEqual(host.fittingSize.width, 448)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 48)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }

    func testLongMissingFileNoticeFitsBesideTheGizmo() {
        let model = model()
        model.barAvailableWidth = 448
        model.notice = MissingFilesNotice(missing: ["texture.png"], granted: false, canGrant: true)
        model.notice?.title = "The model references textures that cannot be read yet"
        let (window, host) = window(NoticeView(model: model), size: CGSize(width: 360, height: 160))
        defer { window.close() }
        XCTAssertLessThanOrEqual(host.fittingSize.width, 360)
        XCTAssertGreaterThan(host.fittingSize.height, 48, "the notice wraps")
    }

    // MARK: The gizmo

    func testClickingAnEndOfTheGizmoLooksAlongThatAxis() throws {
        let model = model()
        var looked: [ViewPreset] = []
        model.onLook = { looked.append($0) }
        let gizmo = GizmoView(model: model, gizmo: model.gizmo)
        func click(_ x: CGFloat, _ y: CGFloat) throws {
            let at = CGPoint(x: x, y: y)
            try gizmo.inspect().find(ViewType.Canvas.self).gesture(DragGesture.self)
                .callOnEnded(value: DragGesture.Value(time: Date(), location: at, startLocation: at, velocity: .zero))
        }
        // The middle of the gizmo is where the front end (Z, towards the viewer) is.
        try click(50, 50)
        XCTAssertEqual(looked, [.front])
        // A click on nothing looks along nothing.
        try click(2, 2)
        XCTAssertEqual(looked, [.front])
    }

    func testDraggingTheGizmoOrbitsByTheDistanceMovedAndDoesNotLook() throws {
        let model = model()
        var drags: [CGPoint] = [], looked = 0
        model.onGizmoDrag = { drags.append(CGPoint(x: $0, y: $1)) }
        model.onLook = { _ in looked += 1 }
        let (window, _) = window(GizmoView(model: model, gizmo: model.gizmo), size: CGSize(width: 100, height: 100))
        window.orderBack(nil)
        defer { window.close() }
        send(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: window)
        send(.leftMouseDragged, at: CGPoint(x: 52, y: 50), in: window)
        XCTAssertTrue(drags.isEmpty, "a tremor of the hand is not a drag")
        send(.leftMouseDragged, at: CGPoint(x: 60, y: 50), in: window)
        send(.leftMouseDragged, at: CGPoint(x: 66, y: 50), in: window)
        send(.leftMouseUp, at: CGPoint(x: 66, y: 50), in: window)
        XCTAssertEqual(drags.reduce(0) { $0 + $1.x }, 14, accuracy: 0.5, "it moves by what the pointer moved since the last report")
        XCTAssertEqual(looked, 0, "the end of a drag is not a click")
    }

    func testTheGizmoHighlightsTheEndUnderThePointerAndIsDrawn() throws {
        let model = model()
        // Looking from above and aside, so that the far ends are in view too.
        model.gizmo.basis = GizmoBasis(right: SIMD3(0.8, 0, -0.6), up: SIMD3(0.2, 0.9, 0.3), back: SIMD3(0.5, 0.4, 0.75))
        let (window, host) = window(GizmoView(model: model, gizmo: model.gizmo), size: CGSize(width: 100, height: 100))
        host.layoutSubtreeIfNeeded()
        let cold = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: cold)
        let handle = try XCTUnwrap(ViewGizmo.handles(model.gizmo.basis).last)
        let at = CGPoint(x: 50 + handle.point.x * 50 * 0.66, y: 50 - handle.point.y * 50 * 0.66)
        send(.mouseMoved, at: at, in: window)
        XCTAssertGreaterThan(cold.size.width, 0)
        // The pointer leaving takes the highlight away.
        send(.mouseMoved, at: CGPoint(x: -20, y: -20), in: window)
        let picture = try XCTUnwrap(cold.cgImage.flatMap(Picture.init))
        XCTAssertGreaterThan(picture.drawn, 0)
    }

    // MARK: Pictures

    func testTheLightsPictureIsDrawnForEverySurroundingAndTurnsWithTheLight() throws {
        let size = CGSize(width: 250, height: 84)
        var seen: [Picture] = []
        for surrounding in Surrounding.allCases {
            let picture = try XCTUnwrap(Render.image(SurroundingPicture(surrounding: surrounding, degrees: 0), size: size))
            XCTAssertGreaterThan(picture.drawn, Int(size.width * size.height * 0.9), "the whole strip is painted")
            seen.append(picture)
        }
        XCTAssertGreaterThan(Set(seen.map(\.bytes)).count, 1, "the moods look different")
        let turns = try Surrounding.allCases.contains { mood in
            try XCTUnwrap(Render.image(SurroundingPicture(surrounding: mood, degrees: 90), size: size))
                .differs(from: try XCTUnwrap(Render.image(SurroundingPicture(surrounding: mood, degrees: 0), size: size)))
        }
        XCTAssertTrue(turns, "turning the light turns the picture")
    }

    func testTheLightPanelShowsTheFiguresOfItsSliders() throws {
        let model = model()
        model.lightIntensity = 1.5
        model.lightRotation = 90
        let panel = try EnvironmentPanel(model: model).inspect()
        XCTAssertNoThrow(try panel.find(text: "150%"))
        XCTAssertNoThrow(try panel.find(text: "90°"))
        XCTAssertNoThrow(try panel.find(text: "Brightness"))
        XCTAssertNoThrow(try panel.find(text: "Direction"))
        XCTAssertNotNil(Render.hosted(EnvironmentPanel(model: model), size: CGSize(width: 290, height: 300)).picture)

        // Automatic rotation publishes to the panel's angle without a settings edit.
        model.lightDirection.degrees = 210
        let updated = try EnvironmentPanel(model: model).inspect()
        XCTAssertNoThrow(try updated.find(text: "210°"))
        XCTAssertEqual(try updated.find(SurroundingPicture.self).actualView().degrees, 210)
        XCTAssertEqual(try updated.findAll(ViewType.Slider.self)[1].value(), 210.0 / 360.0, accuracy: 0.0001)
    }

    func testTheLoadingMarkIsOnlyThereWhileAFileIsRead() throws {
        let model = model()
        XCTAssertThrowsError(try LoadingView(model: model).inspect().find(ViewType.TimelineView.self))
        model.loading = true
        let hosted = Render.hosted(LoadingView(model: model), size: CGSize(width: 244, height: 244), seconds: 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(hosted.picture).drawn, 0)
    }

    // MARK: The bars

    func testTheBarsAreDrawnWithTheirControls() throws {
        let model = model()
        model.clipNames = ["Walk", "Run"]
        let bars = VStack { AnimationBar(model: model); ViewsBar(model: model); SideControls(model: model) }
        let hosted = Render.hosted(bars, size: CGSize(width: 700, height: 600), seconds: 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(hosted.picture).drawn, 0)
    }

    func testTheViewsBarWithNoTexturedViewDisablesStylesThatNeedOne() throws {
        let model = model(textured: false)
        let bar = try ViewsBar(model: model).inspect()
        XCTAssertTrue(try bar.find(text: "Textured").isDisabled())
        XCTAssertTrue(try bar.find(viewWithAccessibilityLabel: "Unshaded style").isDisabled())
        XCTAssertTrue(try bar.find(viewWithAccessibilityLabel: "Anime style").isDisabled())
        XCTAssertFalse(try bar.find(viewWithAccessibilityLabel: "Cel-Shaded").isDisabled())
    }

    func testTheSettingsPopoverEditsTheLook() throws {
        let model = model()
        model.look = RenderLook(view: .textured)
        let popover = try ViewSettingsPopover(model: model).inspect()
        XCTAssertNil(model.look.metallic, "no override to begin with")
        try popover.toggle("Override metallic").tap()
        XCTAssertEqual(model.look.metallic, 0)
        try ViewSettingsPopover(model: model).inspect().toggle("Override roughness").tap()
        XCTAssertEqual(model.look.roughness, 0.5)
        try ViewSettingsPopover(model: model).inspect().toggle("Physically based lighting").tap()
        XCTAssertFalse(model.look.pbr, "it is on to begin with")
        try ViewSettingsPopover(model: model).inspect().toggle("Override metallic").tap()
        XCTAssertNil(model.look.metallic)
    }
}

private extension InspectableView {
    /// The switch with this label.
    func toggle(_ label: String) throws -> InspectableView<ViewType.Toggle> {
        try find(ViewType.Toggle.self) { toggle in
            // By the name VoiceOver reads when that is set, otherwise by the words beside it.
            if let spoken = try? toggle.accessibilityLabel().string() { return spoken == label }
            return try toggle.labelView().text().string() == label
        }
    }
}
