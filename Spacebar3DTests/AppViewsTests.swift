import SwiftUI
import ViewInspector
import ViewerUI
import XCTest

/// The app's plain views, read in the test process: the first window's page and the
/// Acknowledgements window.
@MainActor
final class AppViewsTests: TempDirTestCase {
    func testTheFirstWindowNamesTheAppAndSaysHowAPreviewIsOpenedAndHowToTurnItOn() throws {
        let view = try ContentView().inspect()
        XCTAssertNoThrow(try view.find(text: "Spacebar 3D"))
        XCTAssertNoThrow(try view.find(text: "Select a supported 3D file in Finder and press Space."))
        XCTAssertNoThrow(try view.find(text: "Enable Spacebar 3D in System Settings > General > Login Items & Extensions > Quick Look."))
        XCTAssertNoThrow(try view.find(text: "OBJ, STL, PLY, USD and USDZ may use macOS's own preview. Use Open a Model… to view them here."))
        XCTAssertNoThrow(try view.find(NeonMark.self), "under the app's mark")
        XCTAssertFalse(view.findAll(ViewType.Text.self).contains { (try? $0.string())?.contains("prefer-spacebar3d") == true })
    }

    func testTheFirstWindowsButtonsOpenAModelAndTheSystemsPane() throws {
        var opened = 0, settings = 0
        let view = try ContentView(openModel: { opened += 1 }, openExtensionSettings: { settings += 1 }).inspect()
        try view.find(button: "Open a Model…").tap()
        try view.find(button: "Open System Settings").tap()
        XCTAssertEqual([opened, settings], [1, 1])
        XCTAssertEqual(view.findAll(ViewType.Button.self).count, 2)
    }

    /// The pane is the one System Settings declares for Login Items & Extensions; the URL
    /// goes to the system, and the sandbox needs no network for it.
    func testTheExtensionPaneIsLoginItemsAndExtensions() {
        XCTAssertEqual(ContentView.extensionSettingsURL.absoluteString, "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    func testTheAcknowledgementsWindowShowsTheNoticesItIsGiven() throws {
        let view = try AcknowledgementsView(text: "own terms\n\n\ntheir terms").inspect()
        XCTAssertEqual(try view.find(ViewType.ScrollView.self).find(ViewType.Text.self).string(), "own terms\n\n\ntheir terms")
        XCTAssertEqual(AcknowledgementsView.windowID, "acknowledgements")
    }

    func testTheAcknowledgementsAreSetInALargerMonospacedFace() throws {
        let text = try AcknowledgementsView(text: "x").inspect().find(ViewType.Text.self)
        XCTAssertEqual(try text.attributes().font(), GardenTypography.monospaced)
    }

    /// Left to itself the window reads the three files from the app's resources.
    func testTheAcknowledgementsWindowReadsTheBundledNoticesByDefault() throws {
        XCTAssertEqual(AcknowledgementsView().text, Acknowledgements.text())
        try put("LICENSE", bytes: Data("own terms\n".utf8))
        try put("CREDITS.md", bytes: Data("project credits\n".utf8))
        try put("THIRD_PARTY_LICENSES.md", bytes: Data("their terms\n".utf8))
        XCTAssertEqual(AcknowledgementsView(text: Acknowledgements.text(in: modelDir)).text, "own terms\n\n\nproject credits\n\n\ntheir terms")
    }

    /// The item is a plain button; pressed outside the app's scenes there is no window for
    /// it to open, and it opens none.
    func testTheMenuItemIsNamedAcknowledgements() throws {
        let button = try AcknowledgementsMenuItem().inspect().find(button: "Acknowledgements")
        let before = NSApplication.shared.windows.count
        XCTAssertNoThrow(try button.tap())
        XCTAssertEqual(NSApplication.shared.windows.count, before)
    }

    /// The look of the app's windows is put around their content, which stays as it is.
    func testAGardenWindowKeepsItsContent() throws {
        let view = try Text("inside").gardenWindow().inspect()
        XCTAssertEqual(try view.find(ViewType.Text.self).string(), "inside")
        XCTAssertEqual(view.findAll(ViewType.Text.self).count, 1)
    }
}
