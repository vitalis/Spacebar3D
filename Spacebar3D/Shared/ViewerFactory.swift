import AppKit
import SwiftUI
import ModelCore
import ViewerUI

/// Makes the viewer for a file. The app and the Quick Look extension both come through
/// here, so both show a file the same way and with the same settings.
@MainActor
enum ViewerFactory {
    enum Failure: LocalizedError {
        case noGraphics

        var errorDescription: String? { L10n.text("This Mac's graphics cannot show 3D models.") }
    }

    /// The user's settings (already normalised by `ViewerSettings.load()`) for the native viewer.
    static func nativeSettings(from v: [String: Any]) -> NativeViewerSettings {
        func flag(_ key: ViewerSettings.Key) -> Bool { v[key.rawValue] as? Bool ?? true }
        return NativeViewerSettings(
            defaultLook: (v[ViewerSettings.Key.defaultShading.rawValue] as? String).flatMap(DefaultLook.init(rawValue:)) ?? .original,
            backgroundColor: v[ViewerSettings.Key.backgroundColor.rawValue] as? String ?? NativeViewerSettings.defaultBackground,
            solidColor: v[ViewerSettings.Key.solidColor.rawValue] as? String ?? NativeViewerSettings.defaultSolid,
            lightIntensity: v[ViewerSettings.Key.lightIntensity.rawValue] as? Double ?? 1,
            showGrid: flag(.showGrid),
            autoRotate: v[ViewerSettings.Key.autoRotate.rawValue] as? Bool ?? false,
            autoplay: flag(.autoplay),
            repeatAnimations: v[ViewerSettings.Key.repeatAnimations.rawValue] as? Bool ?? false)
    }

    /// The folders the user has allowed. The app and the Quick Look extension each keep
    /// their own grants; the extension also uses what the app left in the shared container.
    /// (Not a constant only so that tests can put a store of their own in its place.)
    static var folderGrants = FolderGrants(
        role: Bundle.main.bundleURL.pathExtension == "appex" ? .quickLook : .app,
        sharedContainer: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ViewerSettings.appGroup))

    /// Throws when there is no Metal device to draw with.
    static func makeViewer(frame: NSRect) throws -> Viewer {
        guard let viewer = NativeViewer(settings: nativeSettings(from: ViewerSettings.load()), toolbarHelp: { present in AnyView(ViewerHelpMenu(present: present)) }) else { throw Failure.noGraphics }
        viewer.folderGrants = folderGrants
        viewer.view.frame = frame
        return viewer
    }
}
