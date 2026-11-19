import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ViewInspector
import ViewerUI
import XCTest

/// The app's shell: its first window, its menus and the making of viewer windows. Nothing
/// is shown on screen and no panel or alert is run; the stores are the test's own.
@MainActor
final class AppShellTests: TempDirTestCase {
    private var store: UserDefaults!
    private var suite = ""
    private var focus: ViewerFocus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let made = try isolatedDefaults()
        MainActor.assumeIsolated {
            (store, suite) = made
            focus = ViewerFocus(defaults: made.store)
        }
    }

    override func tearDownWithError() throws {
        let suite = MainActor.assumeIsolated { () -> String in
            ViewerFocus.shared.focus(nil)
            focus = nil
            store = nil
            return self.suite
        }
        forget(suite)
        try super.tearDownWithError()
    }

    // MARK: The first window

    func testTheFirstWindowIsThePageAndAButtonToTheSettings() throws {
        let window = try MainWindow().inspect()
        XCTAssertNoThrow(try window.find(text: "Select a supported 3D file in Finder and press Space."))
        XCTAssertNoThrow(try window.find(ContentView.self))
        // The form is in the Settings window, one link away, and not under the page.
        XCTAssertTrue(String(describing: type(of: MainWindow().body)).contains("SettingsLink"), "a link, not a form")
        XCTAssertThrowsError(try window.find(SettingsView.self))
        XCTAssertThrowsError(try window.find(text: "Brightness:"))
    }

    /// The scenes are put together without anything being opened or written: the windows'
    /// contents are made only when a window is.
    func testTheAppsScenesAreDeclaredWithoutTouchingTheSettingsFile() throws {
        let file = ViewerSettings.fileURL
        func stamp() -> Date? { file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } }
        let before = stamp()
        _ = Spacebar3DApp().body
        XCTAssertEqual(stamp(), before)
        XCTAssertEqual(ModelViewerWindowController.openCount, 0)
    }

    // MARK: File > Open Recent

    func testOpenRecentListsTheFilesNewestFirstAndOpensTheOneChosen() throws {
        focus.noteOpened(try triangle("first.stl"))
        focus.noteOpened(try triangle("second.stl"))
        var opened: [URL] = []
        let menu = try RecentMenu(focus: focus, open: { opened.append($0) }).inspect().find(ViewType.Menu.self)
        XCTAssertEqual(try menu.labelView().text().string(), "Open Recent")
        let titles = try menu.findAll(ViewType.Button.self).map { try $0.labelView().text().string() }
        XCTAssertEqual(titles, ["second.stl", "first.stl", "Clear Menu"])
        XCTAssertNoThrow(try menu.find(ViewType.Divider.self), "the files stand apart from the command")
        try menu.find(button: "first.stl").tap()
        XCTAssertEqual(opened.map(\.lastPathComponent), ["first.stl"])
        XCTAssertFalse(try menu.find(button: "Clear Menu").isDisabled())
        try menu.find(button: "Clear Menu").tap()
        XCTAssertEqual(focus.recent, [])
    }

    func testWithNothingOpenedLatelyThereIsOnlyClearMenuAndItCannotBeChosen() throws {
        let menu = try RecentMenu(focus: focus).inspect().find(ViewType.Menu.self)
        XCTAssertEqual(try menu.findAll(ViewType.Button.self).count, 1)
        XCTAssertTrue(try menu.find(button: "Clear Menu").isDisabled())
        XCTAssertThrowsError(try menu.find(ViewType.Divider.self))
    }

    func testChoosingARecentFileUsesItsKeyAndShowsIt() throws {
        let file = try triangle()
        var shown: [URL] = []
        RecentModels.open(file) { shown.append($0) }
        XCTAssertEqual(shown, [file])
    }

    // MARK: The View menu

    func testTheViewMenuHasEveryCommandOnceInItsGroups() throws {
        let viewer = FakeViewer()
        viewer.statuses[.solid] = ViewerCommandStatus(enabled: true, on: true)
        viewer.statuses[.fit] = ViewerCommandStatus(enabled: true)
        focus.focus(viewer)
        let menu = try ViewerMenu(focus: focus).inspect()
        let items = menu.findAll(ViewerCommandItem.self)
        let expected = ViewerCommands.groups.flatMap { $0 } + ViewerCommands.directions + ViewerCommands.turns + ViewerCommands.pans
            + ViewerCommands.shadings + ViewerCommands.moods + ViewerCommands.panels
        XCTAssertEqual(try items.map { try $0.actualView().command }, expected)
        XCTAssertEqual(Set(expected).count, expected.count, "none twice")
        let menus = try menu.findAll(ViewType.Menu.self).map { try $0.labelView().text().string() }
        XCTAssertEqual(menus, ["Look From", "Orbit", "Pan", "Mood"])
        XCTAssertEqual(menu.findAll(ViewType.Divider.self).count, ViewerCommands.groups.count + 2)
        // Choosing one tells the viewer in front.
        try menu.find(button: ViewerCommand.fit.title).tap()
        XCTAssertEqual(viewer.performed, [.fit])
    }

    func testTheViewMenuOpensThePanelsAndNamesTheShadingsAndMoods() throws {
        let viewer = FakeViewer()
        viewer.statuses[.showViewSettings] = ViewerCommandStatus(enabled: true)
        viewer.statuses[.flatShading] = ViewerCommandStatus(enabled: true, on: true)
        viewer.statuses[.moodDawn] = ViewerCommandStatus(enabled: true, on: true)
        focus.focus(viewer)
        let menu = try ViewerMenu(focus: focus).inspect()
        let mood = try menu.find(ViewType.Menu.self) { try $0.labelView().text().string() == "Mood" }
        XCTAssertEqual(try mood.findAll(ViewType.Toggle.self).map { try $0.labelView().text().string() },
                       ["Glasshouse", "Dawn", "Noon", "Golden Hour", "Overcast", "Moonlit", "Neon"])
        XCTAssertTrue(try mood.find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Dawn" }.isOn(), "the mood in use is ticked")
        XCTAssertTrue(try menu.find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Flat Shading" }.isOn())
        XCTAssertFalse(try menu.find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Smooth Shading" }.isOn())
        try menu.find(button: "View Settings…").tap()
        XCTAssertEqual(viewer.performed, [.showViewSettings])
        // Light Settings… has nothing to open on this viewer, and is dimmed.
        XCTAssertTrue(try menu.find(button: "Light Settings…").isDisabled())
    }

    // MARK: The Playback menu

    func testThePlaybackMenuIsDimmedForAModelWithNoAnimation() throws {
        focus.focus(FakeViewer())
        let menu = try PlaybackMenu(focus: focus).inspect()
        XCTAssertTrue(try menu.find(button: "Play").isDisabled())
        XCTAssertTrue(try menu.find(ViewType.Toggle.self).isDisabled())
        XCTAssertTrue(try menu.find(ViewType.Menu.self).isDisabled())
        // And with no viewer at all.
        focus.focus(nil)
        XCTAssertTrue(try PlaybackMenu(focus: focus).inspect().find(button: "Play").isDisabled())
    }

    func testThePlaybackMenuPlaysRepeatsAndChoosesTheClip() throws {
        let viewer = FakeViewer()
        viewer.clipNames = ["walk", "run"]
        viewer.currentClip = 1
        viewer.statuses[.playPause] = ViewerCommandStatus(enabled: true, on: false)
        viewer.statuses[.repeatClip] = ViewerCommandStatus(enabled: true, on: true)
        focus.focus(viewer)
        var menu = try PlaybackMenu(focus: focus).inspect()
        try menu.find(button: "Play").tap()
        XCTAssertEqual(viewer.performed, [.playPause])
        let repeats = try menu.find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Repeat" }
        XCTAssertTrue(try repeats.isOn())
        try repeats.tap()
        XCTAssertEqual(viewer.performed, [.playPause, .repeatClip])
        let clips = try menu.find(ViewType.Menu.self)
        XCTAssertFalse(try clips.isDisabled())
        XCTAssertEqual(try clips.labelView().text().string(), "Clip")
        XCTAssertEqual(try clips.findAll(ViewType.Toggle.self).map { try $0.labelView().text().string() }, ["walk", "run"])
        XCTAssertTrue(try clips.find(ViewType.Toggle.self) { try $0.labelView().text().string() == "run" }.isOn())
        try clips.find(ViewType.Toggle.self) { try $0.labelView().text().string() == "walk" }.tap()
        XCTAssertEqual(viewer.currentClip, 0)
        // While it plays the item says Pause.
        viewer.statuses[.playPause] = ViewerCommandStatus(enabled: true, on: true)
        menu = try PlaybackMenu(focus: focus).inspect()
        XCTAssertNoThrow(try menu.find(button: "Pause"))
        XCTAssertThrowsError(try menu.find(button: "Play"))
    }

    func testPlayBecomesPauseWhilePlaying() {
        XCTAssertEqual(ViewerCommand.playPause.title(on: false), "Play")
        XCTAssertEqual(ViewerCommand.playPause.title(on: true), "Pause")
        XCTAssertEqual(ViewerCommand.fit.title(on: true), "Zoom to Fit", "only that item changes")
    }

    /// File > Show Textures… is dimmed unless the viewer offers the folder.
    func testShowTexturesIsDimmedUnlessTheViewerOffersIt() throws {
        let viewer = FakeViewer()
        focus.focus(viewer)
        XCTAssertTrue(try ViewerCommandItem(focus: focus, command: .showTextures).inspect().find(button: "Show Textures…").isDisabled())
        viewer.statuses[.showTextures] = ViewerCommandStatus(enabled: true)
        let item = try ViewerCommandItem(focus: focus, command: .showTextures).inspect().find(button: "Show Textures…")
        XCTAssertFalse(try item.isDisabled())
        try item.tap()
        XCTAssertEqual(viewer.performed, [.showTextures])
    }

    // MARK: Help

    func testTheHelpMenuOffersHelpSupportPrivacyAndAcknowledgements() throws {
        let items = try HelpMenuItems().inspect()
        XCTAssertEqual(try items.findAll(ViewType.Button.self).map { try $0.labelView().text().string() }, ["Spacebar 3D Help", "Spacebar 3D Support", "Privacy Policy", "Acknowledgements"])
        XCTAssertEqual(items.findAll(ViewType.Divider.self).count, 1)
        XCTAssertEqual(HelpView.windowID, "help")
    }

    func testTheSupportItemOpensTheProjectsIssueTracker() throws {
        var opened: [URL] = []
        try SupportMenuItem(open: { opened.append($0) }).inspect().find(button: "Spacebar 3D Support").tap()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/vitalis/Spacebar3D/issues"])
    }

    func testTheHelpPageCoversWhatTheAppDoesWithoutNamingAHelperScript() throws {
        // What the window shows is these sections (ViewInspector cannot read into this scroll view).
        XCTAssertTrue(String(describing: type(of: HelpView().body)).hasPrefix("ModifiedContent<ScrollView"))
        let page = HelpView.sections.flatMap { [$0.title] + $0.lines }.joined(separator: "\n")
        for topic in ["Controls on the canvas", "Pointer", "Keys", "Textures in other files", "Quick Look"] {
            XCTAssertTrue(page.contains(topic), topic)
        }
        XCTAssertTrue(page.contains("Login Items & Extensions"))
        for kind in ["OBJ", "STL", "PLY", "USD", "USDZ"] { XCTAssertTrue(page.contains(kind), kind) }
        XCTAssertTrue(page.contains("macOS may use its own preview"))
        XCTAssertFalse(page.lowercased().contains("prefer-spacebar3d"))
        // Short, and the headings in sentence case.
        for section in HelpView.sections {
            XCTAssertEqual(section.title.first?.isUppercase, true)
            // Only a name, here Quick Look, has a second capital.
            XCTAssertNil(section.title.dropFirst().first(where: \.isUppercase).flatMap { section.title == "Quick Look" ? nil : $0 }, section.title)
        }
        XCTAssertLessThan(page.count, 2500)
    }

    // MARK: Command-= and the recent documents

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 24))
    }

    func testCommandEqualsZoomsInWithoutShift() throws {
        let viewer = FakeViewer()
        viewer.statuses[.zoomIn] = ViewerCommandStatus(enabled: true)
        XCTAssertFalse(AppDelegate.zoomsIn(try key("=", .command), focus: focus), "no viewer in front")
        focus.focus(viewer)
        XCTAssertTrue(AppDelegate.zoomsIn(try key("=", .command), focus: focus))
        XCTAssertEqual(viewer.performed, [.zoomIn])
        // Other keys, and other modifiers, are left to the menus and to the viewer.
        XCTAssertFalse(AppDelegate.zoomsIn(try key("=", [.command, .shift]), focus: focus))
        XCTAssertFalse(AppDelegate.zoomsIn(try key("=", [.command, .option]), focus: focus))
        XCTAssertFalse(AppDelegate.zoomsIn(try key("=", []), focus: focus))
        XCTAssertFalse(AppDelegate.zoomsIn(try key("-", .command), focus: focus))
        XCTAssertEqual(viewer.performed, [.zoomIn])
        viewer.statuses[.zoomIn] = ViewerCommandStatus(enabled: false)
        XCTAssertFalse(AppDelegate.zoomsIn(try key("=", .command), focus: focus), "nothing to zoom")
    }

    /// An opened file is told to the system, for its recent lists: here to a closure of the
    /// test's own, and to nothing at all for a store that is not the app's.
    func testAnOpenedFileIsToldToTheSystemsRecentDocuments() throws {
        var told: [URL] = []
        let own = ViewerFocus(defaults: store, noteDocument: { told.append($0) })
        let file = try triangle("noted.stl")
        own.noteOpened(file)
        XCTAssertEqual(told, [file])
        XCTAssertEqual(own.recent.map(\.lastPathComponent), ["noted.stl"])
        // Left alone, a focus with a store of its own tells nobody (the system's list is not
        // reachable from here, and this makes sure the call does not fail).
        focus.noteOpened(try triangle("quiet.stl"))
        XCTAssertEqual(focus.recent.map(\.lastPathComponent), ["quiet.stl", "noted.stl"])
    }

    func testTheMenusAreDeclaredForTheFocusTheyAreGiven() {
        let commands = ViewerCommands(focus: focus)
        XCTAssertTrue(commands.focus === focus)
        _ = commands.body
        XCTAssertEqual(ViewerCommands.directions.count, 6)
        XCTAssertEqual(ViewerCommands.turns.count, 4)
    }

    // MARK: Viewer windows

    func testAWindowIsMadeInItsPlaceAndItsFileIsNotedButNothingIsShown() throws {
        let before = ModelViewerWindowController.openCount
        let first = try ModelViewerWindowController.make(try triangle("a.stl"), focus: focus)
        let second = try ModelViewerWindowController.make(try triangle("b.stl"), focus: focus)
        defer { [first, second].forEach { $0.windowWillClose(Notification(name: NSWindow.willCloseNotification)) } }
        XCTAssertEqual(ModelViewerWindowController.openCount, before + 2)
        XCTAssertEqual(focus.recent.map(\.lastPathComponent), ["b.stl", "a.stl"])
        XCTAssertEqual(first.window?.isVisible, false)
        XCTAssertEqual(second.window?.isVisible, false)
        // The file's icon is in the title bar, and the window can go full screen.
        XCTAssertEqual(first.window?.representedURL, try triangle("a.stl"))
        XCTAssertEqual(second.window?.collectionBehavior.contains(.fullScreenPrimary), true)
        // Space plays in the app's viewers, as the arrows turn them.
        XCTAssertTrue(first.viewer.playsWithSpaceKey)
        XCTAssertTrue(first.viewer.orbitsWithArrowKeys)
        // The second stands aside of the first.
        XCTAssertNotEqual(first.window?.frame.origin, second.window?.frame.origin)
        XCTAssertEqual(first.window?.frame.size, second.window?.frame.size)
    }

    func testClosingAWindowTakesItOffTheList() throws {
        let before = ModelViewerWindowController.openCount
        let controller = try ModelViewerWindowController.make(try triangle(), focus: focus)
        XCTAssertEqual(ModelViewerWindowController.openCount, before + 1)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(ModelViewerWindowController.openCount, before)
    }

    func testAFileThatCannotBeReadMakesNoWindowAndIsNotNoted() throws {
        let before = ModelViewerWindowController.openCount
        let missing = modelDir.appendingPathComponent("none.stl")
        XCTAssertThrowsError(try ModelViewerWindowController.make(missing, focus: focus)) { error in
            // What the user is then told names the file and gives the reason.
            let alert = ModelViewerWindowController.failure(missing, error)
            XCTAssertEqual(alert.messageText, "“none.stl” could not be opened.")
            XCTAssertEqual(alert.informativeText, error.localizedDescription)
            XCTAssertFalse(alert.informativeText.isEmpty)
        }
        XCTAssertEqual(ModelViewerWindowController.openCount, before)
        XCTAssertEqual(focus.recent, [])
    }

    func testTheOpenPanelTakesAnyNumberOfModelFilesAndNoFolders() {
        let panel = ModelViewerWindowController.openPanel()
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.isVisible, "made, not run")
        let types = Set(panel.allowedContentTypes)
        XCTAssertFalse(types.isEmpty)
        for ext in ["obj", "stl", "usdz"] { XCTAssertTrue(types.contains(try! XCTUnwrap(UTType(filenameExtension: ext))), ext) }
    }

    // MARK: Showing, the panel and launch, with the screen left alone

    func testShowingAFileHandsTheMadeWindowToWhatPresentsIt() throws {
        var presented: [ModelViewerWindowController] = [], alerts: [NSAlert] = []
        let before = ModelViewerWindowController.openCount
        ModelViewerWindowController.show(try triangle("a.stl"), focus: focus, present: { presented.append($0) }, report: { alerts.append($0) })
        defer { presented.forEach { $0.windowWillClose(Notification(name: NSWindow.willCloseNotification)) } }
        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(presented.first?.window?.title, "a.stl")
        XCTAssertEqual(presented.first?.window?.isVisible, false, "presenting is the caller's")
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(ModelViewerWindowController.openCount, before + 1)
        XCTAssertEqual(focus.recent.map(\.lastPathComponent), ["a.stl"])
    }

    func testAFileThatCannotBeShownIsReportedAndNothingIsPresented() {
        var presented = 0, alerts: [NSAlert] = []
        ModelViewerWindowController.show(modelDir.appendingPathComponent("none.stl"), focus: focus, present: { _ in presented += 1 }, report: { alerts.append($0) })
        XCTAssertEqual(presented, 0)
        XCTAssertEqual(alerts.map(\.messageText), ["“none.stl” could not be opened."])
        XCTAssertEqual(focus.recent, [])
    }

    func testTheOpenPanelOpensWhatWasChosenAndNothingWhenCancelled() throws {
        var shown: [URL] = [], asked = 0
        let panel = ModelViewerWindowController.openPanel()
        ModelViewerWindowController.runOpenPanel(panel, run: { _ in asked += 1; return .cancel }, show: { shown.append($0) })
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(shown.isEmpty)
        // Confirmed: every chosen file is opened (a panel that was never run has chosen none).
        ModelViewerWindowController.runOpenPanel(panel, run: { _ in asked += 1; return .OK }, show: { shown.append($0) })
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(shown, panel.urls)
    }

    func testFilesOpenedFromFinderEachGetAWindowAndAFolderGetsNone() throws {
        let grants = FolderGrants(role: .app, sharedContainer: root.appendingPathComponent("group", isDirectory: true))
        let a = try triangle("a.stl"), b = try triangle("b.stl")
        var shown: [URL] = []
        AppDelegate.open([a, modelDir, b], grants: grants) { shown.append($0) }
        // In a debug build a folder is granted, not opened; in neither build is it shown as a model.
        #if DEBUG
        XCTAssertEqual(shown, [a, b])
        // Where this process may make such a key, the folder was granted.
        if grants.grant(modelDir) { XCTAssertNotNil(grants.beginAccess(forFileAt: a)) }
        #endif
        AppDelegate.open([], grants: grants) { shown.append($0) }
        XCTAssertEqual(shown.filter { $0 == a }.count, 1)
    }

    #if DEBUG
    func testADebugLaunchCanTakeAFolderGrantBack() throws {
        let grants = FolderGrants(role: .app, sharedContainer: root.appendingPathComponent("group", isDirectory: true))
        let file = try triangle()
        try XCTSkipUnless(grants.grant(modelDir), "this process cannot make security-scoped bookmarks")
        XCTAssertNotNil(grants.beginAccess(forFileAt: file))
        // Nothing asked for: nothing taken back.
        AppDelegate.launched(grants: grants, defaults: store)
        XCTAssertNotNil(grants.beginAccess(forFileAt: file))
        store.set(modelDir.path, forKey: "P3DRevokeFolder")
        AppDelegate.launched(grants: grants, defaults: store)
        XCTAssertNil(grants.beginAccess(forFileAt: file))
    }
    #endif

    // MARK: The app's own entry points, with its surroundings replaced

    /// Puts the test's own focus, alert and panel in place of the app's, runs `body`, and
    /// puts the app's back.
    private func withOwnSurroundings(panel answer: NSApplication.ModalResponse = .cancel, _ body: (_ alerts: () -> [NSAlert], _ panels: () -> Int) throws -> Void) rethrows {
        let (oldFocus, oldAlert, oldPanel, oldGrants) = (ModelViewerWindowController.focus, ModelViewerWindowController.runAlert, ModelViewerWindowController.runPanel, ViewerFactory.folderGrants)
        defer {
            ModelViewerWindowController.focus = oldFocus; ModelViewerWindowController.runAlert = oldAlert
            ModelViewerWindowController.runPanel = oldPanel; ViewerFactory.folderGrants = oldGrants
        }
        var alerts: [NSAlert] = [], panels = 0
        let own = focus!
        ModelViewerWindowController.focus = { own }
        ModelViewerWindowController.runAlert = { alerts.append($0) }
        ModelViewerWindowController.runPanel = { _ in panels += 1; return answer }
        ViewerFactory.folderGrants = FolderGrants(role: .app, sharedContainer: root.appendingPathComponent("group", isDirectory: true))
        try body({ alerts }, { panels })
    }

    /// Open With, a double click, a drop on the Dock icon: the window comes to the front
    /// with the keys going to its viewer. It is on screen for a moment and closed again.
    func testOpeningAFileShowsItsWindowInFront() throws {
        try withOwnSurroundings { alerts, _ in
            let before = ModelViewerWindowController.openCount
            let file = try triangle("shown.stl")
            ModelViewerWindowController.show(file)
            let window = try XCTUnwrap(NSApp.windows.first { $0.title == "shown.stl" })
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(window.windowController is ModelViewerWindowController)
            XCTAssertEqual(ModelViewerWindowController.openCount, before + 1)
            XCTAssertEqual(focus.recent.map(\.lastPathComponent), ["shown.stl"])
            XCTAssertTrue(alerts().isEmpty)
            window.close()
            XCTAssertEqual(ModelViewerWindowController.openCount, before, "closed, it is off the list")
            XCTAssertFalse(window.isVisible)
        }
    }

    func testOpeningAFileThatCannotBeReadSaysSoAndShowsNoWindow() throws {
        withOwnSurroundings { alerts, _ in
            ModelViewerWindowController.show(modelDir.appendingPathComponent("none.stl"))
            XCTAssertEqual(alerts().map(\.messageText), ["“none.stl” could not be opened."])
            XCTAssertNil(NSApp.windows.first { $0.title == "none.stl" })
            XCTAssertEqual(focus.recent, [])
        }
    }

    func testFileOpenAsksWithThePanelAndOpensNothingWhenItIsCancelled() throws {
        withOwnSurroundings(panel: .cancel) { alerts, panels in
            let before = ModelViewerWindowController.openCount
            ModelViewerWindowController.runOpenPanel()
            XCTAssertEqual(panels(), 1)
            XCTAssertEqual(ModelViewerWindowController.openCount, before)
            XCTAssertTrue(alerts().isEmpty)
        }
    }

    /// At launch the app writes the granted folders again for the Quick Look extension,
    /// here into a store of the test's own.
    func testLaunchingWritesTheGrantedFoldersAgain() throws {
        try withOwnSurroundings { _, _ in
            let shared = root.appendingPathComponent("group", isDirectory: true)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            AppDelegate().applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            // The writing is done off the main thread; it is given a moment.
            let done = expectation(description: "the grants were refreshed")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        }
    }
}
