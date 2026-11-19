import ModelCore
import Cocoa
import UniformTypeIdentifiers
import ViewerUI

/// A window in the host app that shows one model with the same viewer the Quick Look
/// extension uses. It exists for file types Finder will not hand to the
/// extension (macOS keeps its own preview for OBJ), and as a larger standalone viewer.
final class ModelViewerWindowController: NSWindowController, NSWindowDelegate {
    /// File extensions the viewer can open.
    static let fileExtensions = ["obj", "stl", "ply", "3mf", "usdz", "usd", "usda", "usdc", "3ds", "gltf", "glb", "fbx", "blend", "vrm", "vrma"]

    private static var open: Set<ModelViewerWindowController> = []

    /// What draws the model.
    let viewer: Viewer

    /// Opens a viewer window for the file, or shows an alert explaining why it cannot.
    static func show(_ url: URL) {
        show(url, focus: focus(), present: present, report: runAlert)
    }

    /// The app's own surroundings, which tests put their own in place of: the focus that
    /// keeps the recent files, what runs an alert and what runs the open panel.
    static var focus: () -> ViewerFocus = { .shared }
    static var runAlert: (NSAlert) -> Void = { $0.runModal() }
    static var runPanel: (NSOpenPanel) -> NSApplication.ModalResponse = { $0.runModal() }

    /// The same, with what shows the window and what reports a failure given from outside.
    static func show(_ url: URL, focus: ViewerFocus, present: (ModelViewerWindowController) -> Void, report: (NSAlert) -> Void) {
        do {
            present(try make(url, focus: focus))
        } catch {
            report(failure(url, error))
        }
    }

    /// Brings a made window to the front, with the keys going to its viewer.
    static func present(_ controller: ModelViewerWindowController) {
        controller.showWindow(nil)
        controller.viewer.takeFocus()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// How many viewer windows there are.
    static var openCount: Int { open.count }

    /// Makes the window for a file, in its place among the others and on the list of files
    /// opened lately, without yet showing it.
    static func make(_ url: URL, focus: ViewerFocus) throws -> ModelViewerWindowController {
        let controller = try ModelViewerWindowController(url: url)
        place(controller, amongOpen: !open.isEmpty)
        open.insert(controller)
        focus.noteOpened(url)
        return controller
    }

    /// What is said when a file cannot be opened.
    static func failure(_ url: URL, _ error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.format("“%@” could not be opened.", String(describing: url.lastPathComponent))
        alert.informativeText = error.localizedDescription
        return alert
    }

    /// The panel that File > Open… shows: any number of model files, no folders.
    static func openPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = fileExtensions.compactMap { UTType(filenameExtension: $0) }
        return panel
    }

    /// Where the next window goes when others are open: a step down and to the right of the last.
    private(set) static var cascade = NSPoint.zero

    /// Puts a new window where it belongs. The first opens where the last one was left;
    /// one opened while others are showing steps aside, so that it does not cover them
    /// exactly (they all remember the same place).
    static func place(_ controller: ModelViewerWindowController, amongOpen others: Bool) {
        guard let window = controller.window else { return }
        if others {
            // Only the first of them remembers its place: one that has stepped aside would
            // otherwise move the remembered place along with it, a step at every opening.
            window.setFrameAutosaveName("")
        } else {
            cascade = .zero
        }
        cascade = window.cascadeTopLeft(from: cascade)
    }

    /// Lets the user pick one or more model files and opens each in its own window.
    static func runOpenPanel() {
        runOpenPanel(openPanel(), run: runPanel, show: show)
    }

    /// The same, with what runs the panel and what opens a chosen file given from outside.
    static func runOpenPanel(_ panel: NSOpenPanel, run: (NSOpenPanel) -> NSApplication.ModalResponse, show: (URL) -> Void) {
        guard run(panel) == .OK else { return }
        panel.urls.forEach(show)
    }

    /// Not private only so that tests can make a window without showing it.
    init(url: URL, rememberFrame: Bool = true) throws {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        viewer = try ViewerFactory.makeViewer(frame: frame)
        viewer.orbitsWithArrowKeys = true
        viewer.playsWithSpaceKey = true
        try viewer.load(fileAt: url)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        // The proxy icon in the title bar: drag the file from it, or Command-click for its folder.
        window.representedURL = url
        window.collectionBehavior.insert(.fullScreenPrimary)
        // The viewer is a dark room whatever the system's appearance; its title bar goes with it.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = viewer.view
        window.contentMinSize = NSSize(width: 320, height: 260)
        window.isReleasedWhenClosed = false
        window.center()
        // A viewer opens where, and as large as, the last one was left.
        if rememberFrame { window.setFrameAutosaveName("ModelViewer") }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        ViewerFocus.shared.drop(viewer)
        Self.open.remove(self)
    }

    // The menus speak to the viewer in front.
    func windowDidBecomeKey(_ notification: Notification) { ViewerFocus.shared.focus(viewer) }
    func windowDidResignKey(_ notification: Notification) { ViewerFocus.shared.drop(viewer) }
}

/// Receives files opened from Finder ("Open With", double-click, drop on the Dock icon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if SPACEBAR_MEDIA_CAPTURE
    private let mediaCapture = MediaCaptureSession(arguments: CommandLine.arguments)
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.installZoomKey()
        #if SPACEBAR_MEDIA_CAPTURE
        if mediaCapture != nil { return }
        #endif
        let grants = ViewerFactory.folderGrants
        Self.launched(grants: grants)
        DispatchQueue.global(qos: .utility).async { grants.refreshShared() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        #if SPACEBAR_MEDIA_CAPTURE
        if let mediaCapture {
            mediaCapture.open(urls)
            return
        }
        #endif
        Self.open(urls)
    }

    /// The monitor that gives Command-= the work of Command-+ (the menu's key), once.
    private static var zoomKeyMonitor: Any?

    static func installZoomKey() {
        guard zoomKeyMonitor == nil else { return }
        zoomKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            zoomsIn(event, focus: .shared) ? nil : event
        }
    }

    /// Command-= without Shift zooms in, as it does in Safari and Preview: the menu's key is
    /// "+", which on most keyboards needs Shift. Returns true when it did.
    static func zoomsIn(_ event: NSEvent, focus: ViewerFocus) -> Bool {
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard held == .command, event.charactersIgnoringModifiers == "=",
              let viewer = focus.viewer, focus.status(.zoomIn).enabled else { return false }
        viewer.perform(.zoomIn)
        return true
    }

    /// What is done at launch before the granted folders are written again for the Quick
    /// Look extension (its keys to them stop working when the Mac restarts).
    static func launched(grants: FolderGrants, defaults: UserDefaults = .standard) {
        #if DEBUG
        // Debug builds only: `-P3DRevokeFolder <path>` takes a grant back, so checks
        // made with the real app leave nothing behind in its stores.
        if let path = defaults.string(forKey: "P3DRevokeFolder") {
            grants.revoke(FolderGrants.key(for: URL(fileURLWithPath: path)))
        }
        #endif
    }

    /// Opens each file in a viewer window.
    static func open(_ urls: [URL], grants given: FolderGrants? = nil, show: @MainActor (URL) -> Void = ModelViewerWindowController.show) {
        #if DEBUG
        // Debug builds only: a folder opened with the app is granted as if it had been
        // chosen in the panel, so the grant can be exercised from the command line.
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let grants = given ?? ViewerFactory.folderGrants
        folders.forEach { NSLog("P3D grant %@: %@", $0.path, grants.grant($0) ? "kept" : "FAILED") }
        urls.filter { !folders.contains($0) }.forEach(show)
        #else
        urls.forEach(show)
        #endif
    }
}
