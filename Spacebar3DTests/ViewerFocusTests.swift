import Combine
import SwiftUI
import ViewInspector
import ViewerUI
import XCTest

/// Which viewer the menus speak to, and the menu items that speak to it.
@MainActor
final class ViewerFocusTests: TempDirTestCase {
    // Set up and torn down outside the main actor, used by the tests on it; never by both at once.
    nonisolated(unsafe) private var store: UserDefaults!
    nonisolated(unsafe) private var suite = ""
    nonisolated(unsafe) private var watching: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        (store, suite) = try isolatedDefaults()
    }

    override func tearDownWithError() throws {
        watching = []
        forget(suite)
        store = nil
        try super.tearDownWithError()
    }

    /// Counts how often the menus are told to draw themselves again.
    private func redraws(of focus: ViewerFocus) -> () -> Int {
        var count = 0
        focus.objectWillChange.sink { count += 1 }.store(in: &watching)
        return { count }
    }

    // MARK: The viewer in front

    func testWithNoViewerInFrontNothingCanBeChosen() {
        let focus = ViewerFocus(defaults: store)
        XCTAssertNil(focus.viewer)
        for command in ViewerCommand.allCases {
            XCTAssertEqual(focus.status(command), ViewerCommandStatus(enabled: false), command.rawValue)
        }
    }

    func testTheMenusAskTheViewerInFront() {
        let focus = ViewerFocus(defaults: store), viewer = FakeViewer()
        viewer.statuses = [.grid: ViewerCommandStatus(enabled: true, on: true), .fit: ViewerCommandStatus(enabled: true)]
        focus.focus(viewer)
        XCTAssertTrue(focus.viewer === viewer)
        XCTAssertEqual(focus.status(.grid), ViewerCommandStatus(enabled: true, on: true))
        XCTAssertEqual(focus.status(.fit), ViewerCommandStatus(enabled: true, on: false))
        XCTAssertFalse(focus.status(.celShaded).enabled)
    }

    func testTheMenusAreRedrawnWhenTheViewerChangesOrItsStateDoes() {
        let focus = ViewerFocus(defaults: store), viewer = FakeViewer()
        let redraws = redraws(of: focus)
        focus.focus(viewer)
        XCTAssertEqual(redraws(), 1)
        viewer.onCommandStateChange?()
        viewer.onCommandStateChange?()
        XCTAssertEqual(redraws(), 3)
    }

    /// A viewer no longer in front stops being listened to, so a window behind does not
    /// redraw the menus.
    func testTheViewerLeftBehindIsNoLongerListenedTo() {
        let focus = ViewerFocus(defaults: store), first = FakeViewer(), second = FakeViewer()
        focus.focus(first)
        focus.focus(second)
        XCTAssertNil(first.onCommandStateChange)
        XCTAssertNotNil(second.onCommandStateChange)
        XCTAssertTrue(focus.viewer === second)
        focus.focus(nil)
        XCTAssertNil(second.onCommandStateChange)
        XCTAssertNil(focus.viewer)
    }

    func testAClosingWindowTakesOnlyItsOwnViewerFromTheMenus() {
        let focus = ViewerFocus(defaults: store), front = FakeViewer(), behind = FakeViewer()
        focus.focus(front)
        focus.drop(behind)
        XCTAssertTrue(focus.viewer === front, "another window closing changes nothing")
        XCTAssertNotNil(front.onCommandStateChange)
        focus.drop(front)
        XCTAssertNil(focus.viewer)
        XCTAssertNil(front.onCommandStateChange)
    }

    func testTheViewerDoesNotKeepTheFocusAlive() {
        let viewer = FakeViewer()
        weak var gone: ViewerFocus?
        do {
            let focus = ViewerFocus(defaults: store)
            focus.focus(viewer)
            gone = focus
        }
        XCTAssertNil(gone)
        viewer.onCommandStateChange?()  // speaks to nobody, and does no harm
    }

    // MARK: The files opened lately

    func testTheRecentFilesAreReadFromTheStoreAtTheStart() throws {
        RecentModels.note(try put("a.stl"), in: store)
        RecentModels.note(try put("b.stl"), in: store)
        XCTAssertEqual(ViewerFocus(defaults: store).recent.map(\.lastPathComponent), ["b.stl", "a.stl"])
    }

    func testAnOpenedFileIsKeptAndShownAtOnce() throws {
        let focus = ViewerFocus(defaults: store)
        XCTAssertEqual(focus.recent, [])
        let redraws = redraws(of: focus)
        focus.noteOpened(try put("a.stl"))
        focus.noteOpened(try put("b.stl"))
        XCTAssertEqual(focus.recent.map(\.lastPathComponent), ["b.stl", "a.stl"])
        XCTAssertEqual(redraws(), 2)
        // Kept in the store it was given, for the next launch.
        XCTAssertEqual(RecentModels.urls(in: store).map(\.lastPathComponent), ["b.stl", "a.stl"])
    }

    func testClearingTheMenuForgetsTheFiles() throws {
        var systemRecent: [URL] = []
        var clears = 0
        let focus = ViewerFocus(defaults: store, noteDocument: { systemRecent.append($0) }, clearDocuments: {
            systemRecent.removeAll()
            clears += 1
        })
        focus.noteOpened(try put("a.stl"))
        XCTAssertEqual(systemRecent.count, 1)
        focus.clearRecent()
        XCTAssertTrue(systemRecent.isEmpty)
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(focus.recent, [])
        XCTAssertEqual(RecentModels.urls(in: store), [])
        XCTAssertEqual(ViewerFocus(defaults: store).recent, [])
    }

    // MARK: A command as a menu item

    private func item(_ command: ViewerCommand, _ status: ViewerCommandStatus?) -> (ViewerCommandItem, FakeViewer) {
        let focus = ViewerFocus(defaults: store), viewer = FakeViewer()
        if let status { viewer.statuses[command] = status }
        focus.focus(viewer)
        return (ViewerCommandItem(focus: focus, command: command), viewer)
    }

    func testAStateIsAnItemWithATickThatTellsTheViewerWhenChosen() throws {
        let (off, viewer) = item(.grid, ViewerCommandStatus(enabled: true, on: false))
        let toggle = try off.inspect().find(ViewType.Toggle.self)
        XCTAssertEqual(try toggle.labelView().text().string(), "Floor Grid")
        XCTAssertFalse(try toggle.isOn())
        XCTAssertFalse(toggle.isDisabled())
        XCTAssertThrowsError(try off.inspect().find(ViewType.Button.self), "a state is not a plain item")
        try toggle.tap()
        XCTAssertEqual(viewer.performed, [.grid])

        let (on, _) = item(.grid, ViewerCommandStatus(enabled: true, on: true))
        XCTAssertTrue(try on.inspect().find(ViewType.Toggle.self).isOn())
    }

    func testAnActIsAPlainItemThatTellsTheViewerWhenChosen() throws {
        let (fit, viewer) = item(.fit, ViewerCommandStatus(enabled: true))
        let button = try fit.inspect().find(button: "Zoom to Fit")
        XCTAssertFalse(button.isDisabled())
        XCTAssertThrowsError(try fit.inspect().find(ViewType.Toggle.self), "an act has no tick")
        try button.tap()
        try button.tap()
        XCTAssertEqual(viewer.performed, [.fit, .fit])
    }

    func testEveryCommandIsATickOrAPlainItemUnderItsTitle() throws {
        for command in ViewerCommand.allCases {
            let (view, _) = item(command, ViewerCommandStatus(enabled: true))
            if command.isState {
                XCTAssertEqual(try view.inspect().find(ViewType.Toggle.self).labelView().text().string(), command.title)
            } else {
                XCTAssertNoThrow(try view.inspect().find(button: command.title), command.rawValue)
            }
        }
    }

    func testAnItemThatCannotBeChosenIsDimmed() throws {
        let (act, viewer) = item(.zoomIn, ViewerCommandStatus(enabled: false))
        let button = try act.inspect().find(button: "Zoom In")
        XCTAssertTrue(button.isDisabled())
        XCTAssertThrowsError(try button.tap())
        XCTAssertEqual(viewer.performed, [])
        let (state, _) = item(.celShaded, nil)
        XCTAssertTrue(try state.inspect().find(ViewType.Toggle.self).isDisabled())
    }

    func testWithNoViewerInFrontEveryItemIsDimmed() throws {
        let focus = ViewerFocus(defaults: store)
        for command in ViewerCommand.allCases {
            let view = ViewerCommandItem(focus: focus, command: command)
            if command.isState {
                let toggle = try view.inspect().find(ViewType.Toggle.self)
                XCTAssertTrue(toggle.isDisabled(), command.rawValue)
                XCTAssertFalse(try toggle.isOn(), command.rawValue)
            } else {
                XCTAssertTrue(try view.inspect().find(button: command.title).isDisabled(), command.rawValue)
            }
        }
    }
}
