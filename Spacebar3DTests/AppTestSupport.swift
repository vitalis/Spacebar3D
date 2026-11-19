import AppKit
import ViewerUI
import XCTest

/// A viewer that draws nothing and remembers what it was told, standing in for the Metal one.
final class FakeViewer: Viewer {
    let view = NSView()
    var orbitsWithArrowKeys = false
    var playsWithSpaceKey = false
    var clipNames: [String] = []
    var currentClip = 0
    func selectClip(_ index: Int) { currentClip = index }
    var onCommandStateChange: (() -> Void)?
    /// What `status(of:)` answers; a command not listed cannot be chosen.
    var statuses: [ViewerCommand: ViewerCommandStatus] = [:]
    private(set) var performed: [ViewerCommand] = []

    func load(fileAt url: URL) throws {}
    func resetControls() {}
    func takeFocus() {}
    func perform(_ command: ViewerCommand) { performed.append(command) }
    func status(of command: ViewerCommand) -> ViewerCommandStatus { statuses[command] ?? ViewerCommandStatus(enabled: false) }
}

extension TempDirTestCase {
    /// A defaults store of the test's own, never the app's or the user's. It is named by a
    /// path, so its file is in the test's temp folder (`<root>/defaults/<name>.plist`) and
    /// not among the user's preferences; it goes when the folder does.
    func isolatedDefaults(_ name: String = "store") throws -> (store: UserDefaults, suite: String) {
        let folder = root.appendingPathComponent("defaults", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent(name).path
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    /// Empties the store made by `isolatedDefaults`, and nothing else. Call it before the
    /// temp folder is removed.
    func forget(_ suite: String) {
        guard let root, suite.hasPrefix(root.path) else { return }
        let domain = suite as CFString
        let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetMultiple(nil, keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// A model small enough to read at once: one triangle, as a text STL.
    @discardableResult
    func triangle(_ name: String = "triangle.stl") throws -> URL {
        let text = "solid t\n facet normal 0 0 1\n  outer loop\n   vertex 0 0 0\n   vertex 1 0 0\n   vertex 0 1 0\n  endloop\n endfacet\nendsolid t\n"
        return try put(name, bytes: Data(text.utf8))
    }
}
