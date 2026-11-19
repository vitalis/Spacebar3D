import AppKit
import AVFoundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Vision

private struct ReviewError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@available(macOS 26.0, *)
private final class WindowRecording: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var failure: Error?
    private var streamFailure: Error?
    private var firstSampleTime: Double?
    private var lastSampleTime: Double?
    private var firstMovementTime: Double?
    private var previousSample: [UInt8]?
    private var changes = 0

    var hasMovement: Bool { lock.withLock { changes >= 2 } }

    var leadInTrim: Double {
        lock.withLock {
            guard let firstSampleTime, let firstMovementTime else { return 0 }
            return max(0, firstMovementTime - firstSampleTime - 2)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard type == .screen, now.isFinite,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
        lock.withLock {
            if let lastSampleTime, now - lastSampleTime < 0.25 { return }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { return }
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            // Sample the central viewport so cursor and toolbar changes cannot substitute for model motion.
            var sample = [UInt8]()
            for row in 0..<36 {
                let y = height / 4 + row * height / 72
                for column in 0..<48 {
                    let x = width / 4 + column * width / 96
                    let index = y * stride + 4 * x
                    sample.append(UInt8((19 * Int(bytes[index]) + 183 * Int(bytes[index + 1]) + 54 * Int(bytes[index + 2])) / 256))
                }
            }
            if firstSampleTime == nil { firstSampleTime = now }
            if let previousSample {
                let difference = zip(previousSample, sample).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                if Double(difference) / Double(sample.count) > 1.7 {
                    if firstMovementTime == nil { firstMovementTime = now }
                    changes += 1
                }
            }
            previousSample = sample
            lastSampleTime = now
        }
    }

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
        lock.withLock { streamFailure = error }
    }

    func waitForRecording(finishing: Bool, windowClosed: Bool = false) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let (ready, error) = lock.withLock { (finishing ? finished : started, failure ?? (windowClosed ? nil : streamFailure)) }
            if let error { throw error }
            if ready { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ReviewError(finishing ? "The window recording did not finalize." : "The window recording did not start.")
    }
}

private func writeTimestamp(_ time: Double, to url: URL) throws {
    guard time.isFinite, time >= 0 else { throw ReviewError("The capture returned an invalid timestamp.") }
    let value = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), time)
    try value.write(to: url, atomically: true, encoding: .utf8)
}

private func announce(_ message: String) {
    FileHandle.standardError.write(Data("capture-app-review: \(message)\n".utf8))
}

@MainActor
private func windows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    return content.windows.filter { $0.isOnScreen && $0.frame.width > 200 && $0.frame.height > 160 }
}

@MainActor
private func waitFor<T>(_ failure: String, timeout: Duration = .seconds(90),
                        _ observe: () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if let value = try await observe() { return value }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw ReviewError(failure)
}

private func configuration(for window: SCWindow, filter: SCContentFilter, cursor: Bool = false) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    let scale = min(Double(filter.pointPixelScale), 1920 / window.frame.width, 1080 / window.frame.height)
    config.width = Int(window.frame.width * scale) / 2 * 2
    config.height = Int(window.frame.height * scale) / 2 * 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.showsCursor = cursor
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.ignoreShadowsSingleWindow = true
    config.shouldBeOpaque = true
    config.colorSpaceName = CGColorSpace.itur_709
    return config
}

/// Finder presents Quick Look above its ordinary windows. ScreenCaptureKit
/// rejects a desktop-independent stream for that panel, so include only that
/// window in the display filter and restrict capture to the panel's bounds.
private func surface(for window: SCWindow, cursor: Bool = false) async throws -> (SCContentFilter, SCStreamConfiguration) {
    if window.owningApplication?.bundleIdentifier == "com.apple.finder", window.windowLayer > 0 {
        let available = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = available.displays.first(where: { $0.frame.contains(window.frame) }) else {
            throw ReviewError("Place the whole Quick Look window on one display before recording.")
        }
        let filter = SCContentFilter(display: display, including: [window])
        let config = configuration(for: window, filter: filter, cursor: cursor)
        config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return (filter, config)
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    return (filter, configuration(for: window, filter: filter, cursor: cursor))
}

private func image(of window: SCWindow) async throws -> CGImage {
    let (filter, config) = try await surface(for: window)
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

private func imageBounds(_ image: CGImage) -> CGRect {
    CGRect(x: 0, y: 0, width: image.width, height: image.height)
}

private func text(in image: CGImage, area: CGRect) -> [(String, CGRect)] {
    let region = area.integral.intersection(imageBounds(image))
    guard !region.isEmpty, !region.isNull, let crop = image.cropping(to: region),
          let bitmap = CGContext(data: nil, width: crop.width, height: crop.height,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
    bitmap.draw(crop, in: imageBounds(crop))
    guard let readable = bitmap.makeImage() else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    // ScreenCaptureKit can provide a transitional image when a Finder window
    // changes. Treat an unreadable frame as a miss and wait for a clear one.
    guard (try? VNImageRequestHandler(cgImage: readable).perform([request])) != nil else { return [] }
    return (request.results ?? []).compactMap { result in
        guard let line = result.topCandidates(1).first?.string else { return nil }
        let box = result.boundingBox
        let rect = CGRect(x: region.minX + box.minX * region.width, y: region.minY + (1 - box.maxY) * region.height,
                          width: box.width * region.width, height: box.height * region.height)
        return (line.trimmingCharacters(in: .whitespacesAndNewlines), rect)
    }
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
        throw ReviewError("Could not create the cropped Finder image.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ReviewError("Could not save the cropped Finder image.") }
    try (bytes as Data).write(to: url, options: .atomic)
}

@MainActor
private func record<T>(_ window: SCWindow, at url: URL, cursor: Bool = false, windowCloses: Bool = false,
                       during body: (SCStreamConfiguration, SCRecordingOutput, WindowRecording) async throws -> T) async throws -> T {
    let (filter, config) = try await surface(for: window, cursor: cursor)
    let recording = WindowRecording()
    let outputConfig = SCRecordingOutputConfiguration()
    outputConfig.outputURL = url
    outputConfig.outputFileType = .mov
    outputConfig.videoCodecType = .h264
    let output = SCRecordingOutput(configuration: outputConfig, delegate: recording)
    let stream = SCStream(filter: filter, configuration: config, delegate: recording)
    try stream.addRecordingOutput(output)
    try stream.addStreamOutput(recording, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Spacebar3D.ReviewCapture"))
    try await stream.startCapture()
    do {
        try await recording.waitForRecording(finishing: false)
        let result = try await body(config, output, recording)
        if windowCloses {
            try? await stream.stopCapture()
        } else {
            try await stream.stopCapture()
        }
        try await recording.waitForRecording(finishing: true, windowClosed: windowCloses)
        return result
    } catch {
        try? await stream.stopCapture()
        throw error
    }
}

@MainActor
private func recordSelection(model: URL, directory: URL) async throws -> SCWindow {
    let file = model.lastPathComponent
    let stem = model.deletingPathExtension().lastPathComponent
    let folder = model.deletingLastPathComponent()
    announce("1. Finder will reveal \(file). Switch to List view (Command–2) if needed, and keep the file selected. Wait for the instruction to press Space.")
    NSWorkspace.shared.activateFileViewerSelecting([model])
    let finder: SCWindow = try await waitFor("Finder did not reveal the model’s folder.") {
        try await windows().first { window in
            guard window.owningApplication?.bundleIdentifier == "com.apple.finder", window.windowLayer == 0,
                  let title = window.title else { return false }
            return title == folder.lastPathComponent || (title.hasPrefix("/") &&
                URL(fileURLWithPath: title).resolvingSymlinksInPath().path == folder.path)
        }
    }
    // The filename crop is a visual aid. An unavailable still must not delay the walkthrough.
    Task { @MainActor in
        guard let screenshot = try? await image(of: finder), !Task.isCancelled else { return }
        let area = CGRect(x: 0, y: screenshot.height / 12, width: screenshot.width * 2 / 3,
                          height: screenshot.height * 5 / 6)
        let lines = text(in: screenshot, area: area)
        if let (_, nameRect) = lines.first(where: { $0.0 == file || $0.0 == stem }),
           let label = screenshot.cropping(to: nameRect.insetBy(dx: -3, dy: -2).integral.intersection(imageBounds(screenshot))) {
            // Retain only the matching filename. The rest of Finder never goes to disk.
            try? writePNG(label, to: directory.appendingPathComponent("finder.png"))
        }
    }
    return finder
}

@MainActor
private func openPreview(file: String, finder: SCWindow, before: Set<CGWindowID>) async throws -> SCWindow {
    announce("2. Press Space in Finder to open Quick Look on the selected file.")
    return try await waitFor("No new Finder Quick Look panel appeared. Keep the requested model selected and press Space.") {
        // Finder's floating Quick Look panel is level 3. WindowServer may leave
        // its title blank. Confirm the exact model again at the app handoff.
        let panels = try await windows().filter { window in
            window.owningApplication?.processID == finder.owningApplication?.processID
                && window.windowLayer == 3 && !before.contains(window.windowID)
                && window.frame.width >= 400 && window.frame.height >= 300
        }
        guard panels.count <= 1 else { throw ReviewError("More than one new Finder preview appeared.") }
        guard let panel = panels.first else { return nil }
        if let title = panel.title, !title.isEmpty, title != file, !title.localizedCaseInsensitiveContains("Quick Look") {
            throw ReviewError("The new Finder panel does not show the selected file.")
        }
        return panel
    }
}

@MainActor
private func verifyMovement(in window: SCWindow, recording: WindowRecording) async throws {
    _ = try await waitFor("No model movement was visible. Keep the model window open and orbit or zoom twice.") { () -> Bool? in
        guard try await windows().contains(where: { $0.windowID == window.windowID }) else {
            throw ReviewError("The model window closed or was minimized before its interaction was recorded.")
        }
        return recording.hasMovement ? true : nil
    }
}

@MainActor
private func capture(model: URL, app: URL, directory: URL) async throws {
    let file = model.lastPathComponent
    let installedPath = app.resolvingSymlinksInPath().path
    let initial = try await windows()
    guard !initial.contains(where: { $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer > 0 }) else {
        throw ReviewError("Close the current Finder Quick Look window before starting a new review.")
    }
    guard !initial.contains(where: { $0.owningApplication?.bundleIdentifier == "com.vitalis.Spacebar3D" && $0.title == file }) else {
        throw ReviewError("Close the existing \(file) document in Spacebar 3D before recording its handoff.")
    }
    let finder = try await recordSelection(model: model, directory: directory)
    let finderIDs = Set(try await windows().filter { $0.owningApplication?.processID == finder.owningApplication?.processID }.map(\.windowID))
    let preview = try await openPreview(file: file, finder: finder, before: finderIDs)
    announce("3. In Quick Look, wait for the model, then drag to orbit or scroll to zoom twice. Wait for the next prompt before opening the app.")
    let viewer: SCWindow = try await record(preview, at: directory.appendingPathComponent("quick-look.mov"), cursor: true, windowCloses: true) { _, output, recording in
        try await verifyMovement(in: preview, recording: recording)
        let standaloneIDs = Set(try await windows().filter { $0.owningApplication?.bundleIdentifier == "com.vitalis.Spacebar3D" }.map(\.windowID))
        announce("4. Click Open with Spacebar 3D in Quick Look. If macOS shows a menu, choose Spacebar 3D there. If the button is unavailable, close Quick Look and open \(file) from Spacebar 3D’s File > Open menu.")
        let interactionEnd = output.recordedDuration.seconds
        var lastVisible = interactionEnd
        let opened: SCWindow = try await waitFor("The exact model did not open in the installed Spacebar 3D app after Quick Look.", timeout: .seconds(180)) {
            let elapsed = output.recordedDuration.seconds
            let available = try await windows()
            if available.contains(where: { $0.windowID == preview.windowID }) {
                // Give the click time to appear without publishing a long idle hold.
                lastVisible = min(elapsed, interactionEnd + 8)
                return nil
            }
            return available.first { window in
                guard window.windowLayer == 0, !standaloneIDs.contains(window.windowID), window.title == file,
                      window.owningApplication?.bundleIdentifier == "com.vitalis.Spacebar3D",
                      let pid = window.owningApplication?.processID else { return false }
                return NSRunningApplication(processIdentifier: pid)?.bundleURL?.resolvingSymlinksInPath().path == installedPath
            }
        }
        guard lastVisible.isFinite, lastVisible > 0 else { throw ReviewError("Quick Look did not produce a visible recording.") }
        let start = min(recording.leadInTrim, max(0, lastVisible - 2))
        try writeTimestamp(start, to: directory.appendingPathComponent("quick-look-start.txt"))
        try writeTimestamp(lastVisible, to: directory.appendingPathComponent("quick-look-end.txt"))
        return opened
    }
    announce("5. In Spacebar 3D, wait for the model, then orbit or zoom twice. The script finishes once it sees the changes.")
    try await record(viewer, at: directory.appendingPathComponent("app.mov")) { config, _, recording in
        // Exclude title and tab chrome in publication, including names of other open documents.
        let crop = Int(ceil(84 * Double(config.height) / viewer.frame.height / 2)) * 2
        try String(crop).write(to: directory.appendingPathComponent("app-crop.txt"), atomically: true, encoding: .utf8)
        try await verifyMovement(in: viewer, recording: recording)
        try writeTimestamp(recording.leadInTrim, to: directory.appendingPathComponent("app-start.txt"))
        try await Task.sleep(for: .seconds(2))
    }
}

do {
    guard #available(macOS 26.0, *) else { throw ReviewError("macOS 26 or later is required.") }
    guard CommandLine.arguments.count == 4 else { throw ReviewError("Usage: capture-app-review.swift MODEL APP EMPTY_DIRECTORY") }
    guard CGPreflightScreenCaptureAccess() else {
        throw ReviewError("Allow your terminal under System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch it.")
    }
    guard CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) != nil else {
        throw ReviewError("Run the capture from a logged-in macOS desktop session.")
    }
    let model = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
    let app = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
    let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).standardizedFileURL
    guard try model.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
          FileManager.default.isReadableFile(atPath: model.path) else { throw ReviewError("The input model is not a readable regular file.") }
    guard Bundle(url: app)?.bundleIdentifier == "com.vitalis.Spacebar3D" else {
        throw ReviewError("The installed Spacebar 3D app was not found at \(app.path).")
    }
    let recording = Task { @MainActor in try await capture(model: model, app: app, directory: directory) }
    let cancellationSources = [SIGHUP, SIGINT, SIGTERM].map { number in
        signal(number) { _ in }
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { recording.cancel() }
        source.resume()
        return source
    }
    defer { cancellationSources.forEach { $0.cancel() } }
    try await recording.value
} catch is CancellationError {
    announce("Capture canceled.")
    exit(130)
} catch {
    announce(error.localizedDescription)
    exit(EXIT_FAILURE)
}
