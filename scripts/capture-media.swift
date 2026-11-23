import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private struct CaptureError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct CaptureTarget: Equatable {
    let window: CGWindowID
    let base: String
    let styles: [String]
}

@MainActor
private final class ViewerSession: NSObject {
    private let center = DistributedNotificationCenter.default()
    private let token = UUID()
    private var commandName: Notification.Name { Notification.Name(channel + ".command") }
    private var replyName: Notification.Name { Notification.Name(channel + ".reply") }
    private var channel: String { "com.vitalis.Spacebar3D.media.\(token.uuidString)" }
    private var pending: UUID?
    private var reply: String?
    private var process: NSRunningApplication?

    override init() {
        super.init()
        center.addObserver(self, selector: #selector(receive(_:)), name: replyName, object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func receive(_ notification: Notification) {
        guard let pending, let object = notification.object as? String else { return }
        let prefix = pending.uuidString + ":"
        if object.hasPrefix(prefix) { reply = String(object.dropFirst(prefix.count)) }
    }

    func launch(app: URL, model: URL) async throws -> pid_t {
        let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.vitalis.Spacebar3D").map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.arguments = ["-P3DReleaseCapture", token.uuidString]
        if ProcessInfo.processInfo.environment["SPACEBAR3D_SCREENSHOTS"] == "1" {
            configuration.arguments.append("-P3DReleaseCaptureStills")
        }
        let launched = try await NSWorkspace.shared.open([model], withApplicationAt: app, configuration: configuration)
        guard launched.processIdentifier > 0, !existing.contains(launched.processIdentifier) else {
            throw CaptureError("Launch Services reused a running instance of Spacebar 3D. Capture needs a separate process.")
        }
        process = launched
        return launched.processIdentifier
    }

    func close() {
        if let process, !process.isTerminated {
            _ = process.terminate()
        }
        center.removeObserver(self)
    }

    private func request(_ command: String) async throws -> String? {
        guard process?.isTerminated == false else { throw CaptureError("The capture instance of Spacebar 3D exited.") }
        let id = UUID()
        pending = id
        reply = nil
        defer { pending = nil }
        center.postNotificationName(commandName, object: "\(id.uuidString):\(command)", userInfo: nil, deliverImmediately: true)
        let deadline = ContinuousClock.now + .seconds(2)
        while reply == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return reply
    }

    func ready() async throws -> CaptureTarget {
        let deadline = ContinuousClock.now + .seconds(90)
        var attempts = 0
        while ContinuousClock.now < deadline {
            let status = try await request("status")
            switch status {
            case "loading":
                attempts = 0
            case "open-failed":
                throw CaptureError("Spacebar 3D could not open the supplied model.")
            case "window-closed":
                throw CaptureError("The capture viewer window was closed or minimized.")
            case nil:
                attempts += 1
                if attempts >= 3 { throw CaptureError("The capture app did not respond. Use a build with SPACEBAR_MEDIA_CAPTURE enabled.") }
            default:
                let parts = status?.split(separator: ":", omittingEmptySubsequences: false) ?? []
                guard parts.count == 4, parts[0] == "ready", let window = CGWindowID(parts[1]), window > 0,
                      ["textured", "solid"].contains(parts[2]) else {
                    throw CaptureError("The capture app returned an invalid window or render mode.")
                }
                return CaptureTarget(window: window, base: String(parts[2]), styles: parts[3].split(separator: ",").map(String.init))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CaptureError("Spacebar 3D did not finish loading the model in 90 seconds. Check that the file is readable and supported.")
    }

    func apply(_ command: String) async throws {
        guard try await request(command) == "ok" else {
            throw CaptureError("Spacebar 3D could not apply the capture command '\(command)'.")
        }
    }

    func reviewWindowID(for command: String) async throws -> CGWindowID {
        let response = try await request(command)
        let parts = response?.split(separator: ":", maxSplits: 1) ?? []
        guard parts.count == 2, parts[0] == "window", let window = CGWindowID(parts[1]), window > 0 else {
            throw CaptureError("Spacebar 3D could not present '\(command)' (\(response ?? "no reply")).")
        }
        return window
    }

    func waitForWireframe() async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline {
            switch try await request("wireframe-ready") {
            case "ok": return
            case "preparing-wireframe": try await Task.sleep(for: .milliseconds(150))
            default: throw CaptureError("The capture viewer closed or did not respond while preparing the wireframe.")
            }
        }
        throw CaptureError("Spacebar 3D did not prepare the wireframe in 25 seconds.")
    }

    func recordTour(of target: CaptureTarget) async throws {
        // Give the Hologram arrival and its settled look six seconds in the 30-second cut.
        // Budget the rest evenly so style availability does not leave gaps in the tour.
        // The encoder discards the preroll because ScreenCaptureKit can emit a stale first frame.
        try await Task.sleep(for: .milliseconds(750))
        let start = ContinuousClock.now
        let comparison = target.styles.filter { $0 != "hologram" }
        let comparisonEnd = target.styles.contains("hologram") ? 24_000 : 30_000
        for (index, style) in target.styles.enumerated() {
            // The first style is already on when recording starts.
            if index > 0 { try await apply(style) }
            // Keep a tail for the 30-second export trim.
            let deadline = index == target.styles.count - 1 ? 31_500 : comparisonEnd * (index + 1) / comparison.count
            try await Task.sleep(until: start + .milliseconds(deadline), clock: .continuous)
            try await apply("check-\(style)")
        }
    }

    func reviewerCapabilities() async throws -> (clips: Int, mesh: Bool) {
        let capabilities = try await request("review-capabilities")?.split(separator: ":") ?? []
        guard capabilities.count == 3, capabilities[0] == "clips", let count = Int(capabilities[1]), count >= 0,
              ["mesh", "points"].contains(capabilities[2]) else {
            throw CaptureError("The capture app does not support the reviewer reel. Rebuild the capture-enabled app.")
        }
        return (count, capabilities[2] == "mesh")
    }
}

private final class Recording: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    // ScreenCaptureKit calls its delegates on a thread of its choosing.
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var failure: Error?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { started = true }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { finished = true }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock { failure = error }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = error }
    }

    func waitUntil(_ finishedRecording: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let state = lock.withLock { (finishedRecording ? finished : started, failure) }
            if let error = state.1 { throw error }
            if state.0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CaptureError(finishedRecording ? "The recording did not finish writing." : "The recording did not start.")
    }
}

@MainActor
private func recordWindow(filter: SCContentFilter, configuration: SCStreamConfiguration, destination: URL,
                          duringRecording: () async throws -> Void) async throws {
    let recording = Recording()
    let stream = SCStream(filter: filter, configuration: configuration, delegate: recording)
    let outputConfiguration = SCRecordingOutputConfiguration()
    outputConfiguration.outputURL = destination
    outputConfiguration.outputFileType = .mov
    outputConfiguration.videoCodecType = .h264
    let output = SCRecordingOutput(configuration: outputConfiguration, delegate: recording)
    try stream.addRecordingOutput(output)
    try await stream.startCapture()
    do {
        try await recording.waitUntil(false)
        try await duringRecording()
        try await stream.stopCapture()
        try await recording.waitUntil(true)
    } catch {
        try? await stream.stopCapture()
        throw error
    }
}

@MainActor
private func captureReviewSettings(viewer: ViewerSession, pid: pid_t, directory: URL) async throws {
    do {
        let windowID = try await viewer.reviewWindowID(for: "review-settings")
        // Wait for the hosted Settings form and the window to reach the compositor.
        try await Task.sleep(for: .milliseconds(500))
        let contents = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = contents.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.windowID == windowID && $0.isOnScreen && $0.windowLayer == 0
        }) else {
            throw CaptureError("ScreenCaptureKit could not identify the isolated Settings window.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = min(Double(filter.pointPixelScale), 1440 / window.frame.height)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale) / 2 * 2
        configuration.height = Int(window.frame.height * scale) / 2 * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        configuration.colorSpaceName = CGColorSpace.itur_709
        guard configuration.width > 0, configuration.height > 0 else {
            throw CaptureError("The Settings window has no capturable area.")
        }

        let movie = directory.appendingPathComponent("review-settings.mov")
        let pages: [(command: String?, caption: String)] = [
            (nil, "Settings controls what happens when models open and how they look."),
            ("review-settings-default-app", "Make Default… lets you choose Spacebar 3D for supported files you double-click."),
            ("review-help", "Built-in Help lists supported formats, viewer controls, and shortcuts."),
            ("review-privacy", "The Help menu also opens the app's Privacy Policy."),
        ]
        var captions: [String] = []
        try await recordWindow(filter: filter, configuration: configuration, destination: movie) {
            let start = ContinuousClock.now
            for (index, page) in pages.enumerated() {
                if let command = page.command {
                    guard try await viewer.reviewWindowID(for: command) == windowID else {
                        throw CaptureError("The Settings and Help chapter window changed during recording.")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                let from = start.duration(to: .now)
                try await Task.sleep(for: .seconds(5.5))
                let to = start.duration(to: .now)
                captions.append("\(index + 1)\n\(reviewTimecode(from)) --> \(reviewTimecode(to))\n\(page.caption)\n")
            }
        }
        try captions.joined(separator: "\n").write(to: directory.appendingPathComponent("review-settings.srt"),
                                                   atomically: true, encoding: .utf8)
        try await viewer.apply("review-close")
    } catch {
        try? await viewer.apply("review-close")
        throw error
    }
}

@MainActor
private func captureReviewerReel(target: CaptureTarget, viewer: ViewerSession, filter: SCContentFilter,
                                 configuration: SCStreamConfiguration, directory: URL, animationOnly: Bool) async throws {
    struct Step {
        var commands: [String]
        var caption: String
        var duration: Duration
        var warmup: Duration?
    }

    let (clips, mesh) = try await viewer.reviewerCapabilities()
    if animationOnly, clips == 0 { throw CaptureError("The supplied reviewer animation sample has no playable clips.") }
    try await viewer.apply("review-prepare")
    try await viewer.apply("screenshot-hero")
    try await viewer.apply("base")
    try await Task.sleep(for: .milliseconds(700))

    let title = animationOnly ? "review-animation" : "review-features"
    var steps: [Step] = []
    func scene(_ commands: [String], _ caption: String, _ duration: Duration = .seconds(3), warmup: Duration? = nil) {
        steps.append(Step(commands: commands, caption: caption, duration: duration, warmup: warmup))
    }

    if !animationOnly {
        scene([], "Standalone viewer · The statistics show source topology, faces and vertices.", .seconds(3.5))
        scene(["review-orbitLeft", "review-orbitUp"], "Orbit · Turn the model to inspect it from another angle.")
        scene(["review-panUp", "review-panRight", "review-zoomIn"], "Pan and zoom · Move the model in the view and inspect detail.")
        scene(["review-fit", "review-front"], "Front preset · The three-axis gizmo shows the current orientation.")
        scene(["review-right"], "Right preset · Inspect the model from the side.")
        scene(["review-top"], "Top preset · Look straight down on the model.")
        scene(["review-fit", "review-rotate-on"], "Zoom to Fit and Auto-Rotate · Reframe and turn the model automatically.", .seconds(4))
        scene(["review-rotate-off", "screenshot-hero", "review-grid-off"], "Floor grid · Hide the ground reference.")
        scene(["review-grid-on"], "Floor grid · Restore the ground reference.", .seconds(2))

        scene(["solid"], "Solid · Inspect geometry without material colors.")
        if target.base == "textured" {
            scene(["base"], "Textured · See the model's materials and colors.")
        }
        if mesh {
            scene(["solid-wireframe"], "Wireframe · Inspect source mesh edges over Solid.", .seconds(4))
        }
        scene(["normals"], "Normal · Surface directions are encoded as colors.")

        let styleNames = ["unlit": "Unshaded", "anime": "Anime", "celShaded": "Cel-Shaded", "retro": "Retro",
                          "voxel": "Voxel Art", "hologram": "Hologram"]
        for style in target.styles {
            guard let name = styleNames[style] else { continue }
            if style == "hologram" {
                scene(["screenshot-hero", "review-grid-off", style],
                      "Hologram · Two scan lines travel from the center toward opposite edges and back.",
                      .seconds(9), warmup: .seconds(6))
            } else {
                scene([style], "Render style · \(name)")
            }
        }

        scene(["base", "screenshot-hero", "review-grid-on", "review-showLightSettings", "review-moodGoldenHour", "review-light-reset"],
              "Light · Choose a mood preset, such as Golden Hour.", .seconds(4))
        scene(["review-moodMoonlit"], "Mood · Moonlit changes the color and character of the light.")
        scene(["review-light-dim"], "Brightness · Reduce the light to 45%.")
        scene(["review-light-direction"], "Direction · Turn the light to 120° and restore brightness to 100%.")
        scene(["review-moodGoldenHour", "review-light-rotate"],
              "Auto-rotate light · The direction slider, mood preview, and light on the model move together.",
              .seconds(9))
        scene(["review-light-reset", "review-moodGlasshouse", "review-panels-close", "review-showViewSettings", "review-flatShading"],
              "View settings · Compare Flat and Smooth shading.")
        scene(["review-smoothShading"], "Smooth shading · Blend the shading across connected surfaces.")
        if target.base == "textured" {
            scene(["review-material-override"], "Textured settings · Override Metallic and Roughness with physically based lighting.", .seconds(4))
            scene(["review-material-reset"], "Restore the model's own material values.", .seconds(2))
        }
        scene(["review-panels-close"], clips > 0 ? "The viewer also exposes this model's animation controls." : "Playback controls appear when the model has animation clips.")
    }

    if clips > 0 {
        if animationOnly { scene([], "Animation sample · This model includes animation clips.") }
        scene(["review-clip-0", "review-repeat-on", "review-play"], "Play and Repeat · Preview the first animation clip.", .seconds(4.7))
        scene(["review-pause"], "Pause · Hold the current pose.", .seconds(2.5))
        scene(["review-seek"], "Animation position · Scrub to a point in the clip.")
        if clips > 1 {
            scene(["review-clip-1", "review-play"], "Animation clip · Select and play a different clip.", .seconds(4.5))
        }
        scene(["review-pause", "review-repeat-off"], "Repeat can be switched off to play a clip once.")
    }

    var captions: [String] = []
    var warmupCuts: [String] = []
    try await recordWindow(filter: filter, configuration: configuration, destination: directory.appendingPathComponent(title + ".mov")) {
        let start = ContinuousClock.now
        for step in steps {
            let setupStart = start.duration(to: .now)
            for command in step.commands { try await viewer.apply(command) }
            let preparesWireframe = step.commands.contains("solid-wireframe")
            if preparesWireframe { try await viewer.waitForWireframe() }
            if let warmup = step.warmup { try await Task.sleep(for: warmup) }
            if preparesWireframe || step.warmup != nil {
                warmupCuts.append("(lt(t,\(captureSeconds(setupStart)))+gte(t,\(captureSeconds(start.duration(to: .now)))))")
            }
            let from = start.duration(to: .now)
            try await Task.sleep(for: step.duration)
            let to = start.duration(to: .now)
            captions.append("\(captions.count + 1)\n\(reviewTimecode(from)) --> \(reviewTimecode(to))\n\(step.caption)\n")
        }
        guard try await viewer.ready() == target else { throw CaptureError("The reviewer window changed during capture.") }
    }
    try captions.joined(separator: "\n").write(to: directory.appendingPathComponent(title + ".srt"), atomically: true, encoding: .utf8)
    if !warmupCuts.isEmpty {
        try warmupCuts.joined(separator: "*").write(to: directory.appendingPathComponent(title + ".keep"),
                                                   atomically: true, encoding: .utf8)
    }
}

private func captureSeconds(_ duration: Duration) -> String {
    let parts = duration.components
    return String(format: "%lld.%03lld", parts.seconds, parts.attoseconds / 1_000_000_000_000_000)
}

private func reviewTimecode(_ duration: Duration) -> String {
    let parts = duration.components
    let seconds = Int(parts.seconds)
    let milliseconds = Int(parts.attoseconds / 1_000_000_000_000_000)
    return String(format: "%02d:%02d:%02d,%03d", seconds / 3600, (seconds / 60) % 60, seconds % 60, milliseconds)
}

@MainActor
private func captureFeatureClips(target: CaptureTarget, viewer: ViewerSession, filter: SCContentFilter,
                                 configuration: SCStreamConfiguration, directory: URL) async throws {
    let priority = ["celShaded", "voxel", "hologram", "retro", "anime", "unlit"]
    let styles = priority.filter(target.styles.contains).prefix(3)
    guard styles.count == 3 else { throw CaptureError("A feature loop needs three available render styles.") }
    for (index, style) in styles.enumerated() {
        try await viewer.apply(style)
        // Let the viewer present the style, and wait for the Hologram's arrival to complete.
        try await Task.sleep(for: style == "hologram" ? .seconds(5.5) : .seconds(1))
        let destination = directory.appendingPathComponent("feature-0\(index + 1).mov")
        try await recordWindow(filter: filter, configuration: configuration, destination: destination) {
            try await Task.sleep(for: .seconds(7))
            try await viewer.apply("check-\(style)")
        }
    }
}

@MainActor
private func captureStills(target: CaptureTarget, viewer: ViewerSession, filter: SCContentFilter,
                           configuration: SCStreamConfiguration, directory: URL) async throws {
    let stills: [(mode: String, name: String, angle: String?, settle: Duration)] = [
        ("base", "01-\(target.base)", "screenshot-hero", .milliseconds(500)),
        ("solid-wireframe", "02-wireframe", "screenshot-inspection", .seconds(1)),
        ("normals", "03-normals", nil, .milliseconds(500)),
        ("hologram", "04-hologram", "screenshot-hero", .seconds(5.25)),
    ]
    for still in stills {
        if let angle = still.angle { try await viewer.apply(angle) }
        try await viewer.apply(still.mode)
        if still.mode == "solid-wireframe" { try await viewer.waitForWireframe() }
        try await Task.sleep(for: still.settle)
        try await viewer.apply("screenshot-refresh")
        // The first request can return the compositor's cached Metal surface.
        _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try await Task.sleep(for: .milliseconds(100))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let url = directory.appendingPathComponent(still.name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError("Could not create \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError("Could not write \(url.lastPathComponent).") }
    }
}

@MainActor
private func capture(model: URL, app: URL, directory: URL, animationOnly: Bool = false) async throws {
    let viewer = ViewerSession()
    defer { viewer.close() }
    let pid = try await viewer.launch(app: app, model: model)
    let target = try await viewer.ready()
    let contents = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = contents.windows.first(where: {
        $0.owningApplication?.processID == pid && $0.windowID == target.window
            && $0.title == model.lastPathComponent && $0.isOnScreen && $0.windowLayer == 0
    }) else {
        throw CaptureError("ScreenCaptureKit could not identify the new Spacebar 3D viewer window.")
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let environment = ProcessInfo.processInfo.environment
    let screenshots = environment["SPACEBAR3D_SCREENSHOTS"] == "1"
    let heightLimit: Double = screenshots ? 1600 : 1440
    let scale = min(Double(filter.pointPixelScale), 2560 / window.frame.width, heightLimit / window.frame.height)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * scale) / 2 * 2
    configuration.height = Int(window.frame.height * scale) / 2 * 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.shouldBeOpaque = true
    configuration.colorSpaceName = CGColorSpace.itur_709
    guard configuration.width > 0, configuration.height > 0 else {
        throw CaptureError("The viewer window has no capturable area.")
    }

    if environment["SPACEBAR3D_REVIEW_SETTINGS_ONLY"] == "1" {
        try await captureReviewSettings(viewer: viewer, pid: pid, directory: directory)
        return
    }
    if environment["SPACEBAR3D_REVIEW_FEATURES"] == "1" {
        configuration.includeChildWindows = true
        try await captureReviewerReel(target: target, viewer: viewer, filter: filter, configuration: configuration,
                                      directory: directory, animationOnly: animationOnly)
        if !animationOnly { try await captureReviewSettings(viewer: viewer, pid: pid, directory: directory) }
        return
    }
    if screenshots {
        try await captureStills(target: target, viewer: viewer, filter: filter, configuration: configuration,
                                directory: directory)
        return
    }

    try await viewer.apply("screenshot-hero")
    if environment["SPACEBAR3D_FEATURE_LOOP"] == "1" {
        try await captureFeatureClips(target: target, viewer: viewer, filter: filter, configuration: configuration, directory: directory)
        return
    }

    guard let firstStyle = target.styles.first else { throw CaptureError("The supplied model has no available render styles.") }
    try await viewer.apply(firstStyle)
    try await Task.sleep(for: .milliseconds(300))
    try await recordWindow(filter: filter, configuration: configuration, destination: directory.appendingPathComponent("video.mov")) {
        try await viewer.recordTour(of: target)
        let finalWindow = try await viewer.ready()
        guard finalWindow == target else { throw CaptureError("The capture window changed during recording.") }
    }
    if target.styles.count >= 3 {
        try await captureFeatureClips(target: target, viewer: viewer, filter: filter, configuration: configuration, directory: directory)
    }
}

do {
    guard CommandLine.arguments.count == 3 else { throw CaptureError("Usage: capture-media.swift MODEL EMPTY_OUTPUT_DIRECTORY") }
    guard CGPreflightScreenCaptureAccess() else {
        throw CaptureError("Screen Recording permission is required for the calling terminal. Enable it in macOS System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch the terminal.")
    }
    // Establish the WindowServer connection before asking ScreenCaptureKit for windows.
    guard CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) != nil else {
        throw CaptureError("Run the capture from a logged-in macOS desktop session.")
    }
    guard let appPath = ProcessInfo.processInfo.environment["SPACEBAR3D_APP"], !appPath.isEmpty else {
        throw CaptureError("SPACEBAR3D_APP must name a Spacebar 3D app built with SPACEBAR_MEDIA_CAPTURE enabled.")
    }
    let app = URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
    guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.vitalis.Spacebar3D",
          bundle.object(forInfoDictionaryKey: "P3DReleaseMediaCapture") as? String == "SPACEBAR_MEDIA_CAPTURE" else {
        throw CaptureError("SPACEBAR3D_APP must point to a Spacebar 3D app built with SPACEBAR_MEDIA_CAPTURE enabled.")
    }
    let model = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
    let files = FileManager.default
    guard try model.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true, files.isReadableFile(atPath: model.path) else {
        throw CaptureError("The input model is not a readable file.")
    }
    guard try files.contentsOfDirectory(atPath: directory.path).isEmpty else {
        throw CaptureError("The capture output directory must be empty.")
    }
    let environment = ProcessInfo.processInfo.environment
    let animationModel = environment["SPACEBAR3D_REVIEW_FEATURES"] == "1"
        ? environment["SPACEBAR3D_REVIEW_ANIMATION_MODEL"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL }
        : nil
    if let animationModel {
        guard try animationModel.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              files.isReadableFile(atPath: animationModel.path) else {
            throw CaptureError("The reviewer animation sample is not a readable model file.")
        }
    }
    try await capture(model: model, app: app, directory: directory)
    if let animationModel { try await capture(model: animationModel, app: app, directory: directory, animationOnly: true) }
} catch {
    FileHandle.standardError.write(Data("capture-media: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
