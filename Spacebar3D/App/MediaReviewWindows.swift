#if SPACEBAR_MEDIA_CAPTURE
import AppKit
import ModelCore
import SwiftUI

/// Hosts the app's Settings and Help views for the private, window-only recording.
@MainActor
final class MediaReviewWindows {
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?
    private var settingsDirectory: URL?

    func run(_ command: String) -> String? {
        switch command {
        case "review-settings":
            return showSettings()
        case "review-settings-default-app":
            return showDefaultApp()
        case "review-help":
            return show(HelpView(), title: L10n.text("Spacebar 3D Help"))
        case "review-privacy":
            return show(PrivacyPolicyView(), title: L10n.text("Privacy Policy"))
        case "review-close":
            window?.close()
            window = nil
            host = nil
            if let settingsDirectory { try? FileManager.default.removeItem(at: settingsDirectory) }
            settingsDirectory = nil
            return "ok"
        default:
            return nil
        }
    }

    private func showSettings() -> String {
        let directory = settingsDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("spacebar-review-\(UUID().uuidString)", isDirectory: true)
        settingsDirectory = directory
        let model = SettingsModel(file: directory.appendingPathComponent("viewer-settings.json"))
        guard !model.saveFailed else { return "review-settings-unavailable" }
        return show(SettingsView(model: model), title: L10n.text("Settings…"))
    }

    private func showDefaultApp() -> String {
        guard let host, let window else { return "review-window-unavailable" }
        host.layoutSubtreeIfNeeded()
        guard let scroll = scrollingForm(in: host), let document = scroll.documentView else {
            return "review-settings-cannot-scroll"
        }
        let clip = scroll.contentView
        let visible = clip.bounds
        let bottom = document.isFlipped ? document.frame.maxY - visible.height : document.frame.minY
        clip.scroll(to: NSPoint(x: visible.minX, y: bottom))
        scroll.reflectScrolledClipView(clip)
        return "window:\(window.windowNumber)"
    }

    private func scrollingForm(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.hasVerticalScroller { return scroll }
        for child in view.subviews {
            if let scroll = scrollingForm(in: child) { return scroll }
        }
        return nil
    }

    private func show(_ page: some View, title: String) -> String {
        let content = AnyView(page.frame(maxWidth: .infinity, maxHeight: .infinity).gardenWindow())
        if let host, let window {
            host.rootView = content
            window.title = title
            return "window:\(window.windowNumber)"
        }

        guard let available = NSScreen.main?.visibleFrame.insetBy(dx: 12, dy: 12),
              available.width >= 560, available.height >= 632 else { return "review-window-unavailable" }
        let width = min(720, available.width)
        let height = min(640, available.height - 32)
        let appWindow = NSWindow(contentRect: NSRect(x: available.midX - width / 2, y: available.midY - height / 2,
                                                   width: width, height: height).integral,
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        appWindow.contentView = hostingView
        appWindow.title = title
        appWindow.isReleasedWhenClosed = false
        appWindow.isRestorable = false
        appWindow.ignoresMouseEvents = true
        appWindow.orderFrontRegardless()
        window = appWindow
        host = hostingView
        return "window:\(appWindow.windowNumber)"
    }
}
#endif
