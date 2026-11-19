import ModelCore
import SwiftUI
import ViewerUI

/// Which viewer the menus speak to: the one in the key window, if that is a viewer's.
/// Published, so the menus are redrawn when it changes or when its state does.
@MainActor
final class ViewerFocus: ObservableObject {
    static let shared = ViewerFocus()

    @Published private(set) var viewer: Viewer?
    /// Files opened lately, newest first.
    @Published private(set) var recent: [URL]
    /// Where the recent files are kept: the app's own defaults; tests pass their own.
    private let defaults: UserDefaults
    /// Tells the system a file was opened, for its Open Recent lists and the Dock menu.
    /// Left out, it is the real thing for the app's own defaults and nothing for any other
    /// store, so that a test with a store of its own never reaches the user's recent items.
    private let noteDocument: (URL) -> Void

    private let clearDocuments: () -> Void

    init(defaults: UserDefaults = .standard, noteDocument: ((URL) -> Void)? = nil, clearDocuments: (() -> Void)? = nil) {
        self.defaults = defaults
        self.noteDocument = noteDocument ?? (defaults === UserDefaults.standard
            ? { NSDocumentController.shared.noteNewRecentDocumentURL($0) } : { _ in })
        self.clearDocuments = clearDocuments ?? (defaults === UserDefaults.standard
            ? { NSDocumentController.shared.clearRecentDocuments(nil) } : {})
        recent = RecentModels.urls(in: defaults)
    }

    func focus(_ viewer: Viewer?) {
        self.viewer?.onCommandStateChange = nil
        self.viewer = viewer
        viewer?.onCommandStateChange = { [weak self] in self?.objectWillChange.send() }
    }

    /// The viewer's window is going away.
    func drop(_ viewer: Viewer) { if self.viewer === viewer { focus(nil) } }

    func noteOpened(_ url: URL) {
        RecentModels.note(url, in: defaults)
        noteDocument(url)
        recent = RecentModels.urls(in: defaults)
    }

    func clearRecent() {
        RecentModels.clear(in: defaults)
        clearDocuments()
        recent = []
    }

    func status(_ command: ViewerCommand) -> ViewerCommandStatus {
        viewer?.status(of: command) ?? ViewerCommandStatus(enabled: false)
    }
}

/// The files opened lately. A sandboxed app may open a file again later only with a key to
/// it, so each is kept as a security-scoped bookmark, in the app's own defaults.
enum RecentModels {
    static let key = "recentModels"
    static let most = 10

    static func urls(in defaults: UserDefaults = .standard) -> [URL] {
        let stored = defaults.array(forKey: key) as? [Data] ?? []
        var kept = stored, renewed = false
        let urls = stored.enumerated().compactMap { index, bookmark -> URL? in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            if let fresh = renew(bookmark, for: url, stale: stale) { kept[index] = fresh; renewed = true }
            return url
        }
        if renewed { defaults.set(kept, forKey: key) }
        return urls
    }

    /// A bookmark the system says is stale (the file was moved, or the system updated) still
    /// opens its file, but may stop doing so: it is made again while it still works. Nil
    /// when the old one is to be kept.
    static func renew(_ bookmark: Data, for url: URL, stale: Bool) -> Data? {
        guard stale else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil),
              fresh != bookmark else { return nil }
        return fresh
    }

    static func note(_ url: URL, in defaults: UserDefaults = .standard) {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let path = url.standardizedFileURL.path
        // Newest first, each file once.
        let kept = (defaults.array(forKey: key) as? [Data] ?? []).filter { old in
            var stale = false
            let there = try? URL(resolvingBookmarkData: old, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            return there.map { $0.standardizedFileURL.path != path } ?? false
        }
        defaults.set(Array(([bookmark] + kept).prefix(most)), forKey: key)
    }

    static func clear(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    /// Opens one of them: the key is used for as long as the app runs.
    @MainActor
    static func open(_ url: URL, show: @MainActor (URL) -> Void = ModelViewerWindowController.show) {
        _ = url.startAccessingSecurityScopedResource()
        show(url)
    }
}

/// The keys of the commands: the first three views and the wireframe on the digits, as
/// tabs and panes are; the standard keys for zooming. Plain arrows turn
/// the model. The other commands are in the menus only.
enum ViewerShortcuts {
    static func shortcut(for command: ViewerCommand) -> KeyboardShortcut? {
        switch command {
        case .solid: return KeyboardShortcut("1")
        case .textured: return KeyboardShortcut("2")
        case .normal: return KeyboardShortcut("3")
        case .wireframe: return KeyboardShortcut("4")
        case .fit: return KeyboardShortcut("0")
        case .zoomIn: return KeyboardShortcut("+")
        case .zoomOut: return KeyboardShortcut("-")
        // The plain arrows turn the model while it has the keyboard (the viewer takes them
        // itself): as menu keys they would be taken from a slider that has it.
        case .grid: return KeyboardShortcut("g", modifiers: [.command, .option])
        case .autoRotate: return KeyboardShortcut("r", modifiers: [.command, .option])
        // Space belongs to the focused control. The canvas handles playback in keyDown.
        // Only the most used commands have keys; the rest are in the menus.
        default: return nil
        }
    }
}

/// One command as a menu item: a tick for a state, plain for an act; dimmed when it cannot
/// be chosen or there is no viewer in front.
struct ViewerCommandItem: View {
    @ObservedObject var focus: ViewerFocus
    let command: ViewerCommand

    var body: some View {
        let status = focus.status(command)
        Group {
            if command.isState {
                Toggle(command.title, isOn: Binding(get: { status.on }, set: { _ in focus.viewer?.perform(command) }))
            } else {
                Button(command.title(on: status.on)) { focus.viewer?.perform(command) }
            }
        }
        .keyboardShortcut(ViewerShortcuts.shortcut(for: command))
        .disabled(!status.enabled)
    }
}

/// The View menu's part for the model, and File > Open Recent.
struct ViewerCommands: Commands {
    @ObservedObject var focus: ViewerFocus

    /// The app passes its one focus; tests pass their own.
    init(focus: ViewerFocus) { self.focus = focus }

    static let groups: [[ViewerCommand]] = [
        [.solid, .textured, .normal],
        [.wireframe],
        [.unlit, .anime, .celShaded, .retro, .voxel, .hologram],
        [.grid, .autoRotate],
        [.fit, .zoomIn, .zoomOut],
    ]
    static let shadings: [ViewerCommand] = [.smoothShading, .flatShading]
    static let moods: [ViewerCommand] = [.moodGlasshouse, .moodDawn, .moodNoon, .moodGoldenHour, .moodOvercast, .moodMoonlit, .moodNeon]
    static let panels: [ViewerCommand] = [.showViewSettings, .showLightSettings]
    static let directions: [ViewerCommand] = [.front, .back, .left, .right, .top, .bottom]
    static let pans: [ViewerCommand] = [.panLeft, .panRight, .panUp, .panDown]
    static let turns: [ViewerCommand] = [.orbitLeft, .orbitRight, .orbitUp, .orbitDown]

    var body: some Commands {
        CommandGroup(after: .newItem) {
            RecentMenu(focus: focus)
            ViewerCommandItem(focus: focus, command: .showTextures)
        }
        CommandGroup(before: .toolbar) { ViewerMenu(focus: focus) }
        // Between View and Window, where the menu bar puts an app's own menus.
        CommandMenu(L10n.text("Playback")) { PlaybackMenu(focus: focus) }
    }
}

/// File > Open Recent: the files opened lately, newest first, and a way to forget them.
struct RecentMenu: View {
    @ObservedObject var focus: ViewerFocus
    /// What choosing a file does: opens it in a viewer window.
    var open: (URL) -> Void = { RecentModels.open($0) }

    var body: some View {
        Menu(L10n.text("Open Recent")) {
            ForEach(focus.recent, id: \.self) { url in
                Button(url.lastPathComponent) { open(url) }
            }
            if !focus.recent.isEmpty { Divider() }
            Button(L10n.text("Clear Menu")) { focus.clearRecent() }.disabled(focus.recent.isEmpty)
        }
    }
}

/// The View menu's part for the model: everything the controls on the canvas do.
struct ViewerMenu: View {
    @ObservedObject var focus: ViewerFocus

    var body: some View {
        ForEach(Array(ViewerCommands.groups.enumerated()), id: \.offset) { _, group in
            ForEach(group, id: \.self) { ViewerCommandItem(focus: focus, command: $0) }
            Divider()
        }
        Menu(L10n.text("Look From")) {
            ForEach(ViewerCommands.directions, id: \.self) { ViewerCommandItem(focus: focus, command: $0) }
        }
        Menu(L10n.text("Orbit")) {
            ForEach(ViewerCommands.turns, id: \.self) { ViewerCommandItem(focus: focus, command: $0) }
        }
        Divider()
        Menu(L10n.text("Pan")) {
            ForEach(ViewerCommands.pans, id: \.self) { ViewerCommandItem(focus: focus, command: $0) }
        }
        ForEach(ViewerCommands.shadings, id: \.self) { ViewerCommandItem(focus: focus, command: $0) }
        Menu(L10n.text("Mood")) {
            ForEach(ViewerCommands.moods, id: \.self) { ViewerCommandItem(focus: focus, command: $0) }
        }
        ForEach(ViewerCommands.panels, id: \.self) { ViewerCommandItem(focus: focus, command: $0) }
        Divider()
    }
}

/// The Playback menu: play or pause, repeat and the clip; all dimmed for a model with no animation.
struct PlaybackMenu: View {
    @ObservedObject var focus: ViewerFocus

    var body: some View {
        ViewerCommandItem(focus: focus, command: .playPause)
        ViewerCommandItem(focus: focus, command: .repeatClip)
        let clips = focus.viewer?.clipNames ?? []
        Menu(L10n.text("Clip")) {
            ForEach(Array(clips.enumerated()), id: \.offset) { index, name in
                Toggle(name, isOn: Binding(get: { focus.viewer?.currentClip == index }, set: { _ in focus.viewer?.selectClip(index) }))
            }
        }
        .disabled(clips.isEmpty)
    }
}
