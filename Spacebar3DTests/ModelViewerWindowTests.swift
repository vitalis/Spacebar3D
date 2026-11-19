import AppKit
import ModelCore
import UniformTypeIdentifiers
import ViewerUI
import XCTest

/// The app's viewer window, made but never shown: no window comes on screen, no panel and
/// no alert is opened.
@MainActor
final class ModelViewerWindowTests: TempDirTestCase {
    override func tearDownWithError() throws {
        // The menus' focus is the app's one; it is left with no viewer, as it was found.
        MainActor.assumeIsolated { ViewerFocus.shared.focus(nil) }
        try super.tearDownWithError()
    }

    private let anyNote = Notification(name: NSWindow.didBecomeKeyNotification)

    func testTheWindowIsNamedAfterItsFileAndHoldsTheViewer() throws {
        let controller = try ModelViewerWindowController(url: try triangle("ship.stl"))
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "ship.stl")
        XCTAssertFalse(window.isVisible, "made, not shown")
        XCTAssertTrue(window.delegate === controller)
        XCTAssertFalse(window.isReleasedWhenClosed)
        // A dark room whatever the system's appearance, and never too small to use.
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 320, height: 260))
        XCTAssertTrue(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertNotNil(window.contentView)
    }

    /// Every viewer window remembers the same place, so files opened together would cover
    /// one another exactly: each after the first steps down and to the right.
    func testWindowsOpenedTogetherDoNotCoverOneAnother() throws {
        let first = try ModelViewerWindowController(url: try triangle("a.stl"))
        let second = try ModelViewerWindowController(url: try triangle("b.stl"))
        let third = try ModelViewerWindowController(url: try triangle("c.stl"))
        XCTAssertEqual(first.window?.frame, second.window?.frame, "as made, they are in one place")
        let home = try XCTUnwrap(first.window).frame
        ModelViewerWindowController.place(first, amongOpen: false)
        ModelViewerWindowController.place(second, amongOpen: true)
        ModelViewerWindowController.place(third, amongOpen: true)
        let frames = try [first, second, third].map { try XCTUnwrap($0.window).frame }
        XCTAssertEqual(frames[0], home, "the first stays where the last one was left")
        XCTAssertEqual(Set(frames.map(\.origin.x)).count, 3)
        XCTAssertGreaterThan(frames[1].minX, frames[0].minX); XCTAssertLessThan(frames[1].maxY, frames[0].maxY)
        XCTAssertGreaterThan(frames[2].minX, frames[1].minX); XCTAssertLessThan(frames[2].maxY, frames[1].maxY)
        XCTAssertEqual(Set(frames.map(\.size.width)).count, 1, "moved, not resized")
        // Only the first remembers its place; the ones that stepped aside would drag it along.
        XCTAssertEqual(first.window?.frameAutosaveName, "ModelViewer")
        XCTAssertEqual(second.window?.frameAutosaveName, "")
        XCTAssertEqual(third.window?.frameAutosaveName, "")
        // With none open the next one starts over from the remembered place.
        let later = try ModelViewerWindowController(url: try triangle("d.stl"))
        let remembered = try XCTUnwrap(later.window).frame
        ModelViewerWindowController.place(later, amongOpen: false)
        XCTAssertEqual(try XCTUnwrap(later.window).frame, remembered)
    }

    func testAFileThatCannotBeReadMakesNoWindow() {
        XCTAssertThrowsError(try ModelViewerWindowController(url: modelDir.appendingPathComponent("none.stl")))
    }

    /// The menus speak to the window in front: becoming key gives them its viewer, with the
    /// arrow keys turning the model; resigning or closing takes it away again.
    func testTheMenusFollowTheWindowInFront() throws {
        let controller = try ModelViewerWindowController(url: try triangle())
        let window = try XCTUnwrap(controller.window)
        XCTAssertNil(ViewerFocus.shared.viewer)

        controller.windowDidBecomeKey(anyNote)
        let viewer = try XCTUnwrap(ViewerFocus.shared.viewer)
        XCTAssertTrue(viewer.view === window.contentView)
        XCTAssertTrue(viewer.orbitsWithArrowKeys, "in the app's own window the arrows turn the model")

        controller.windowDidResignKey(anyNote)
        XCTAssertNil(ViewerFocus.shared.viewer)

        controller.windowDidBecomeKey(anyNote)
        controller.windowWillClose(anyNote)
        XCTAssertNil(ViewerFocus.shared.viewer)
    }

    func testAWindowBehindDoesNotTakeTheMenusFromTheOneInFront() throws {
        let front = try ModelViewerWindowController(url: try triangle("front.stl"))
        let behind = try ModelViewerWindowController(url: try triangle("behind.stl"))
        front.windowDidBecomeKey(anyNote)
        behind.windowDidResignKey(anyNote)
        behind.windowWillClose(anyNote)
        XCTAssertTrue(ViewerFocus.shared.viewer?.view === front.window?.contentView)
    }

    // MARK: What the Open panel offers

    func testTheExtensionsOfferedAreLowerCaseAndListedOnce() {
        let listed = ModelViewerWindowController.fileExtensions
        XCTAssertEqual(Set(listed).count, listed.count)
        XCTAssertEqual(listed, listed.map { $0.lowercased() })
        XCTAssertEqual(Set(listed), ["obj", "stl", "ply", "3mf", "usdz", "usd", "usda", "usdc", "3ds", "gltf", "glb", "fbx", "blend", "vrm", "vrma"])
    }

    /// Each extension is one the viewer takes as a hint (short, plain letters and digits),
    /// and each has a content type for the panel to filter by.
    func testEveryExtensionOfferedIsOneTheViewerCanBeGiven() {
        for ext in ModelViewerWindowController.fileExtensions {
            XCTAssertLessThanOrEqual(ext.count, 8, ext)
            XCTAssertTrue(ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, ext)
            XCTAssertNotNil(UTType(filenameExtension: ext), ext)
        }
        // The extensions that alone can decide the format are all offered.
        for ext in ["stl", "3ds", "gltf", "3mf", "usd", "usda", "usdc", "usdz"] {
            XCTAssertTrue(ModelViewerWindowController.fileExtensions.contains(ext), ext)
        }
    }

    /// Every type the app says it opens (project.yml) has its extension in the panel.
    func testTheDeclaredDocumentTypesAreAllOffered() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let declared: [String: String] = [
            "public.geometry-definition-format": "obj", "public.standard-tesselated-geometry-format": "stl",
            "com.pixar.universal-scene-description-mobile": "usdz", "public.polygon-file-format": "ply",
            "com.pixar.universal-scene-description": "usd", "org.khronos.gltf": "gltf", "com.autodesk.3ds": "3ds",
            "org.3mf.3mf": "3mf", "org.blenderfoundation.blender.file": "blend", "org.khronos.glb": "glb",
            "com.autodesk.fbx": "fbx", "com.vrm.vrm": "vrm", "com.vrm.vrma": "vrma",
        ]
        for (type, ext) in declared {
            XCTAssertTrue(project.contains("- \(type)\n"), type)
            XCTAssertTrue(ModelViewerWindowController.fileExtensions.contains(ext), ext)
        }
    }

    // MARK: Files handed over by Finder

    func testOpeningNoFilesOpensNothing() {
        let before = NSApplication.shared.windows.count
        AppDelegate().application(NSApplication.shared, open: [])
        XCTAssertEqual(NSApplication.shared.windows.count, before)
        XCTAssertNil(ViewerFocus.shared.viewer)
    }
}
