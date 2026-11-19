#if SPACEBAR_MEDIA_CAPTURE
import AppKit
@_spi(MediaCapture) import ViewerUI

/// Drives the ordinary viewer only in the isolated instance launched by capture-media.swift.
/// The random channel name scopes commands to one run. Sandboxed posts carry no userInfo.
@MainActor
final class MediaCaptureSession: NSObject {
    private static let styles: [ViewerCommand] = [.unlit, .anime, .celShaded, .retro, .voxel, .hologram]

    private let center = DistributedNotificationCenter.default()
    private let commands: Notification.Name
    private let replies: Notification.Name
    private var controller: ModelViewerWindowController?
    private var openFailed = false
    private var lease: Timer?
    private let captureStills: Bool
    private let reviewWindows = MediaReviewWindows()

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "-P3DReleaseCapture"),
              arguments.indices.contains(flag + 1),
              let token = UUID(uuidString: arguments[flag + 1]) else { return nil }
        let channel = "com.vitalis.Spacebar3D.media.\(token.uuidString)"
        captureStills = arguments.contains("-P3DReleaseCaptureStills")
        commands = Notification.Name(channel + ".command")
        replies = Notification.Name(channel + ".reply")
        super.init()
        center.addObserver(self, selector: #selector(receive(_:)), name: commands, object: nil, suspensionBehavior: .deliverImmediately)
        renewLease()
    }

    func open(_ urls: [URL]) {
        guard controller == nil, !openFailed, urls.count == 1, let url = urls.first else { return }
        do {
            let capture = try ModelViewerWindowController(url: url, rememberFrame: false)
            guard let window = capture.window, let screen = NSScreen.main else {
                openFailed = true
                return
            }
            let available = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let aspect: CGFloat = captureStills ? 16 / 10 : 16 / 9
            let width = min(1280, available.width, available.height * aspect)
            let height = width / aspect
            window.setFrame(NSRect(x: available.midX - width / 2, y: available.midY - height / 2,
                                   width: width, height: height).integral, display: true)
            window.ignoresMouseEvents = true
            controller = capture
            window.orderFront(nil)
        } catch {
            openFailed = true
            NSLog("Could not open the release media model: %@", error.localizedDescription)
        }
    }

    // A vanished helper must not leave its viewer or capture build running indefinitely.
    private func renewLease() {
        lease?.invalidate()
        lease = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    @objc private func receive(_ notification: Notification) {
        guard let message = notification.object as? String else { return }
        let parts = message.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return }
        renewLease()
        let response = run(String(parts[1]))
        center.postNotificationName(replies, object: "\(parts[0]):\(response)", userInfo: nil, deliverImmediately: true)
    }

    private func run(_ command: String) -> String {
        if openFailed { return "open-failed" }
        guard let controller, let window = controller.window else { return "loading" }
        guard window.isVisible, !window.isMiniaturized else { return "window-closed" }
        let viewer = controller.viewer
        guard viewer.status(of: .solid).enabled else { return "loading" }
        if let reply = reviewWindows.run(command) { return reply }
        if command.hasPrefix("review-") { return review(command, viewer: viewer) }
        let base: ViewerCommand = viewer.status(of: .textured).enabled ? .textured : .solid

        switch command {
        case "status":
            let styles = Self.styles.filter { viewer.status(of: $0).enabled }.map(\.rawValue)
            return "ready:\(window.windowNumber):\(base.rawValue):\(styles.joined(separator: ","))"
        case "front":
            if viewer.status(of: .playPause).on { viewer.perform(.playPause) }
            if viewer.status(of: .autoRotate).on { viewer.perform(.autoRotate) }
            viewer.perform(.front)
            return "ok"
        case "screenshot-hero", "screenshot-inspection":
            guard let native = viewer as? NativeViewer else { return "state-failed" }
            if viewer.status(of: .playPause).on { viewer.perform(.playPause) }
            if viewer.status(of: .autoRotate).on { viewer.perform(.autoRotate) }
            let inspection = command == "screenshot-inspection"
            native.frameModel(yaw: inspection ? -.pi / 3 : .pi / 3, pitch: inspection ? .pi / 5 : .pi / 6)
            return "ok"
        case "angle":
            [.orbitRight, .orbitRight, .orbitUp, .zoomIn].forEach(viewer.perform)
            return "ok"
        case "base": return select(viewer, view: base)
        case "solid": return select(viewer, view: .solid)
        case "wireframe": return select(viewer, view: base, wire: true)
        case "solid-wireframe": return select(viewer, view: .solid, wire: true)
        case "wireframe-ready":
            return (viewer as? NativeViewer)?.isWireframeReady == true ? "ok" : "preparing-wireframe"
        case "screenshot-refresh":
            guard let native = viewer as? NativeViewer else { return "state-failed" }
            native.drawCaptureFrame()
            return "ok"
        case "normals": return select(viewer, view: .normal)
        default:
            if command.hasPrefix("check-"), let style = ViewerCommand(rawValue: String(command.dropFirst(6))) {
                return viewer.status(of: style).on && !viewer.status(of: .autoRotate).on ? "ok" : "state-failed"
            }
            guard let style = ViewerCommand(rawValue: command), Self.styles.contains(style) else { return "unknown-command" }
            guard viewer.status(of: style).enabled else { return "style-unavailable" }
            return select(viewer, view: base, style: style)
        }
    }

    private func review(_ command: String, viewer: Viewer) -> String {
        guard let native = viewer as? NativeViewer else { return "state-failed" }

        switch command {
        case "review-capabilities": return "clips:\(viewer.clipNames.count):\(native.mediaReviewHasFaces ? "mesh" : "points")"
        case "review-prepare":
            native.prepareReviewControls()
            return set(.grid, on: true, viewer: viewer)
        case "review-grid-off": return set(.grid, on: false, viewer: viewer)
        case "review-grid-on": return set(.grid, on: true, viewer: viewer)
        case "review-rotate-on": return set(.autoRotate, on: true, viewer: viewer)
        case "review-rotate-off": return set(.autoRotate, on: false, viewer: viewer)
        case "review-play": return set(.playPause, on: true, viewer: viewer)
        case "review-pause": return set(.playPause, on: false, viewer: viewer)
        case "review-repeat-on": return set(.repeatClip, on: true, viewer: viewer)
        case "review-repeat-off": return set(.repeatClip, on: false, viewer: viewer)
        case "review-seek": native.seekReviewAnimation(position: 0.65)
        case "review-clip-0", "review-clip-1":
            let clip = command == "review-clip-0" ? 0 : 1
            guard viewer.clipNames.indices.contains(clip) else { return "clip-unavailable" }
            viewer.selectClip(clip)
            return viewer.currentClip == clip ? "ok" : "state-failed"
        case "review-panels-close": native.closeReviewPanels()
        case "review-light-dim": native.adjustReviewLight(brightness: 0.45, direction: 0)
        case "review-light-direction": native.adjustReviewLight(brightness: 1, direction: 120)
        case "review-light-rotate": native.adjustReviewLight(brightness: 1.75, direction: 120, rotates: true)
        case "review-light-reset": native.adjustReviewLight(brightness: 1, direction: 0)
        case "review-material-override": native.adjustReviewMaterial(pbr: true, metallic: 0.65, roughness: 0.25)
        case "review-material-reset": native.adjustReviewMaterial(pbr: true, metallic: nil, roughness: nil)
        default:
            let available: [ViewerCommand] = [.fit, .front, .right, .top, .orbitLeft, .orbitUp, .panUp, .panRight,
                                               .zoomIn, .zoomOut, .showLightSettings, .showViewSettings, .moodGlasshouse,
                                               .moodGoldenHour, .moodMoonlit, .flatShading, .smoothShading]
            guard let action = ViewerCommand(rawValue: String(command.dropFirst("review-".count))), available.contains(action),
                  viewer.status(of: action).enabled else { return "unknown-command" }
            viewer.perform(action)
            if action.isState && !viewer.status(of: action).on { return "state-failed" }
        }
        return "ok"
    }

    private func set(_ command: ViewerCommand, on: Bool, viewer: Viewer) -> String {
        guard viewer.status(of: command).enabled else { return "state-failed" }
        if viewer.status(of: command).on != on { viewer.perform(command) }
        return viewer.status(of: command).on == on ? "ok" : "state-failed"
    }

    private func select(_ viewer: Viewer, view: ViewerCommand, wire: Bool = false, style: ViewerCommand? = nil) -> String {
        for active in Self.styles where active != style && viewer.status(of: active).on {
            viewer.perform(active)
        }
        viewer.perform(view)
        if let style, !viewer.status(of: style).on { viewer.perform(style) }
        if viewer.status(of: .wireframe).on != wire { viewer.perform(.wireframe) }

        let selectedStyle = Self.styles.first { viewer.status(of: $0).on }
        let succeeded = viewer.status(of: view).on && viewer.status(of: .wireframe).on == wire && selectedStyle == style
        return succeeded ? "ok" : "state-failed"
    }
}
#endif
