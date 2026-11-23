import AppKit
import XCTest
@testable import ViewerUI

/// The Quick Look extension's view controller, driven as Quick Look drives it but without
/// Quick Look: its view is made, a file is prepared, the preview goes away.
@MainActor
final class PreviewViewControllerTests: TempDirTestCase {
    private func controller() -> PreviewViewController {
        let controller = PreviewViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        return controller
    }

    /// The viewer the controller holds: private there, so read by reflection.
    private func viewer(of controller: PreviewViewController) -> NativeViewer? {
        for child in Mirror(reflecting: controller).children where child.label == "viewer" {
            return (child.value as? Viewer?).flatMap { $0 } as? NativeViewer
        }
        return nil
    }

    /// Prepares the file. `told` says whether Quick Look was answered before the call
    /// returned; `error` is what it was answered with.
    private func prepare(_ controller: PreviewViewController, _ url: URL) -> (told: Bool, error: Error?) {
        var told = false, failure: Error?
        controller.preparePreviewOfFile(at: url) { told = true; failure = $0 }
        return (told, failure)
    }

    func testTheControllersOwnViewIsAnEmptyContainer() {
        let controller = PreviewViewController()
        controller.loadView()
        XCTAssertTrue(type(of: controller.view) == NSView.self)
        XCTAssertEqual(controller.view.subviews, [])
        XCTAssertNil(viewer(of: controller))
    }

    func testAPreparedFileFillsTheContainerAndQuickLookIsToldAtOnce() throws {
        let controller = controller()
        let answer = prepare(controller, try triangle())
        // Told before the model has been read: the view is ready, the model follows.
        XCTAssertTrue(answer.told)
        XCTAssertNil(answer.error)
        XCTAssertEqual(controller.view.subviews.count, 1)
        let shown = try XCTUnwrap(controller.view.subviews.first)
        XCTAssertEqual(shown.frame, controller.view.bounds)
        XCTAssertEqual(shown.autoresizingMask, [.width, .height])
        let viewer = try XCTUnwrap(viewer(of: controller))
        XCTAssertTrue(viewer.view === shown)
        XCTAssertFalse(viewer.orbitsWithArrowKeys, "in Quick Look the arrows go to the next file")
    }

    func testTheModelArrivesAfterQuickLookHasBeenTold() async throws {
        let controller = controller()
        XCTAssertTrue(prepare(controller, try triangle()).told)
        let viewer = try XCTUnwrap(viewer(of: controller))
        XCTAssertTrue(viewer.model.loading)
        await viewer.loadTask?.value
        XCTAssertFalse(viewer.model.loading)
        XCTAssertNil(viewer.model.message)
        XCTAssertEqual(viewer.model.statistics?.faces, 1)
    }

    func testAFileThatCannotBeReadIsReportedAndNothingIsShown() throws {
        let controller = controller()
        let answer = prepare(controller, modelDir.appendingPathComponent("none.stl"))
        XCTAssertTrue(answer.told)
        XCTAssertNotNil(answer.error, "Quick Look is given the error")
        XCTAssertEqual(controller.view.subviews, [])
        XCTAssertNil(viewer(of: controller))
    }

    func testTheNextFileTakesThePlaceOfTheLast() throws {
        let controller = controller()
        _ = prepare(controller, try triangle("one.stl"))
        let first = try XCTUnwrap(controller.view.subviews.first)
        _ = prepare(controller, try triangle("two.stl"))
        XCTAssertEqual(controller.view.subviews.count, 1)
        XCTAssertFalse(controller.view.subviews.first === first)
        XCTAssertNil(first.superview)
    }

    /// A file that fails after one that was shown leaves the shown one where it is.
    func testAFailedFileLeavesTheLastPreviewInPlace() throws {
        let controller = controller()
        _ = prepare(controller, try triangle())
        let first = try XCTUnwrap(controller.view.subviews.first)
        XCTAssertNotNil(prepare(controller, modelDir.appendingPathComponent("none.stl")).error)
        XCTAssertEqual(controller.view.subviews, [first])
    }

    /// Quick Look may show the same view again for the same file; it should not remember
    /// what was switched on the last time.
    func testWhenThePreviewGoesAwayTheControlsGoBackToTheSettings() async throws {
        let controller = controller()
        controller.viewDidDisappear()  // with nothing prepared, nothing to do
        _ = prepare(controller, try triangle())
        let viewer = try XCTUnwrap(viewer(of: controller))
        await viewer.loadTask?.value
        let grid = viewer.status(of: .grid).on, wire = viewer.status(of: .wireframe).on
        viewer.perform(.grid)
        viewer.perform(.wireframe)
        XCTAssertEqual(viewer.status(of: .grid).on, !grid)
        XCTAssertEqual(viewer.status(of: .wireframe).on, !wire)
        controller.viewDidDisappear()
        XCTAssertEqual(viewer.status(of: .grid).on, grid)
        XCTAssertEqual(viewer.status(of: .wireframe).on, wire)
    }

    /// The extension's Info.plist names this class as the one Quick Look makes.
    func testTheProjectNamesThisClassAsTheExtensionsPrincipalClass() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).\(String(describing: PreviewViewController.self))"))
        XCTAssertTrue(project.contains("NSExtensionPointIdentifier: com.apple.quicklook.preview"))
    }
}
