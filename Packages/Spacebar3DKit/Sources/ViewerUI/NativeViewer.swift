import AppKit
import ImportRouter
import MetalKit
import ModelCore
import QuartzCore
import RenderMetal
import SwiftUI

/// The MTKView with the mouse and trackpad input of an orbit viewer.
final class ViewerMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    /// How much nearer or farther, and the pointer's place in the view when it says where.
    var onZoom: ((Float, NSPoint?) -> Void)?
    /// The space bar; returns false when there is nothing for it to do.
    var onSpace: (() -> Bool)?

    /// An arrow key (123 left, 124 right, 125 down, 126 up); returns false to pass it on.
    var onArrow: ((UInt16) -> Bool)?
    var onPanArrow: ((UInt16) -> Bool)?
    /// A two-finger turn on the trackpad, in degrees, counterclockwise positive.
    var onRotate: ((Float) -> Void)?
    /// A two-finger double tap on the trackpad.
    var onSmartMagnify: (() -> Void)?
    /// The menu of a secondary click; nil for none.
    var contextMenu: (() -> NSMenu?)?

    /// How far a secondary press may travel, in points, and still be a click rather than a pan.
    static let clickSlop: CGFloat = 3
    static func isClick(travel: CGFloat) -> Bool { travel < clickSlop }
    private var secondaryTravel: CGFloat = 0

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .shift, (123...126).contains(event.keyCode), onPanArrow?(event.keyCode) == true { return }
        let plain = modifiers.isEmpty
        if plain, (123...126).contains(event.keyCode), onArrow?(event.keyCode) == true { return }
        if event.keyCode == 49, modifiers.isEmpty, onSpace?() == true { return }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Control-click is a secondary click, as everywhere on the Mac.
        if event.modifierFlags.contains(.control), let menu = contextMenu?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        secondaryTravel = 0
    }
    /// A secondary click that did not move shows the menu; one that moved was a pan.
    override func rightMouseUp(with event: NSEvent) {
        guard Self.isClick(travel: secondaryTravel), let menu = contextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func mouseDragged(with event: NSEvent) {
        // NSEvent's deltaY already points down, as the camera expects.
        if !event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty {
            onPan?(event.deltaX, event.deltaY)
        } else {
            onOrbit?(event.deltaX, event.deltaY)
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        secondaryTravel += hypot(event.deltaX, event.deltaY)
        onPan?(event.deltaX, event.deltaY)
    }
    override func otherMouseDragged(with event: NSEvent) { onPan?(event.deltaX, event.deltaY) }

    override func scrollWheel(with event: NSEvent) {
        // The wheel dollies; a trackpad's two-finger scroll the same.
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        onZoom?(Float(exp(-event.scrollingDeltaY * k)), convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) { onZoom?(Float(max(0.05, 1 - event.magnification)), convert(event.locationInWindow, from: nil)) }
    override func rotate(with event: NSEvent) { onRotate?(event.rotation) }
    override func smartMagnify(with event: NSEvent) { onSmartMagnify?() }
}

/// Holds the Metal view and the overlay controls; reports its size.
final class NativeViewerContainer: NSView {
    var onResize: ((CGSize) -> Void)?
    override func layout() {
        super.layout()
        onResize?(bounds.size)
    }
}

/// Notify the layout when localized labels or animation controls change size.
private final class MeasuredHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?
    private var lastFittingSize = CGSize.zero

    override func layout() {
        super.layout()
        let size = fittingSize
        guard size != lastFittingSize else { return }
        lastFittingSize = size
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }


}

/// The native viewer: an MTKView driven by `MetalRenderer`, with SwiftUI controls on top.
/// Draws only on demand: when something changes, and every frame while the camera glides
/// or auto-rotate is on.
@MainActor
/// A layer of decoration over the view: drawn, but nothing in it can be clicked, so the
/// mouse reaches the model under it.
final class PassthroughHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

public final class NativeViewer: NSObject, Viewer, MTKViewDelegate {
    /// How far the controls stand from the edge of the view.
    static let edge = ControlsVisibility.edge
    struct Loaded: @unchecked Sendable {
        var scene: GPUScene
        var statistics: NativeViewerStatistics
        var textured: Bool
        /// Files the model names that could not be read.
        var missing: [String]
    }

    /// The folders the user has allowed; nil when nothing beside a model may be read.
    public var folderGrants: FolderGrants?
    private var currentURL: URL?

    let renderer: MetalRenderer
    let model = NativeViewerModel()
    private let queue: MTLCommandQueue
    private let container = NativeViewerContainer()
    private var helpDocumentHost: NSView?
    private let mtkView: ViewerMTKView
    private let initial: NativeViewerState

    /// Longest side of a model's images once loaded (see `MetalRenderer.maxTextureSide`).
    /// Applies to models loaded after it is set.
    public var maxTextureSide: Int {
        get { renderer.maxTextureSide }
        set { renderer.maxTextureSide = newValue }
    }

    private var generation = 0
    /// Seconds into the current clip.
    private var clipTime: Float = 0
    private var lastScrubberUpdate: CFTimeInterval = 0
    private var lastGizmoUpdate: CFTimeInterval = 0
    /// When the Hologram style was turned on; nil until its first frame, so the intro
    /// starts with what is seen and not while the model is still loading.
    private var hologramStart: CFTimeInterval?
    /// Whether the system asks for less motion; replaced in tests.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var loadTask: Task<Void, Never>?
    private var lastFrame: CFTimeInterval?
    private var animation: (from: OrbitCamera, to: OrbitCamera, start: CFTimeInterval)?
    private static let moveDuration: CFTimeInterval = 0.25
    /// How long the present move takes; the opening takes longer than a change of view.
    private var animationDuration: CFTimeInterval = NativeViewer.moveDuration
    /// The opening: the camera comes in from a little farther off and a little to one side.
    static let openingDuration: CFTimeInterval = 1.1
    static let openingYaw: Float = -0.42
    static let openingDistance: Float = 1.22
    /// While something moves, the view draws at this rate, also on a display that
    /// refreshes faster: every frame costs the same to hand to the screen.
    static let framesPerSecond = 60
    /// What only drifts (auto-rotate, the settled hologram) is drawn at half that: these
    /// run for as long as the preview is open, and each frame costs the same.
    static let driftFramesPerSecond = 30
    /// True while the view draws by its own clock; otherwise it draws only when asked.
    private var continuous = false

    private func setContinuous(_ on: Bool) {
        guard continuous != on else { return }
        continuous = on
        mtkView.enableSetNeedsDisplay = !on
        mtkView.isPaused = !on
    }
    /// One turn in 30 s.
    private static let autoRotateSpeed: Float = 2 * .pi / 30
    /// Automatic light rotation in degrees per second: one turn in twenty seconds.
    static let lightTurnSpeed: Float = 360 / 20

    public var view: NSView { container }

    /// nil when this Mac has no Metal device or the shaders do not compile.
    public init?(settings: NativeViewerSettings = NativeViewerSettings(), toolbarHelp: ((@escaping (AnyView?) -> Void) -> AnyView)? = nil) {
        guard let renderer = try? MetalRenderer(), let queue = renderer.device.makeCommandQueue() else { return nil }
        self.renderer = renderer
        self.queue = queue
        initial = settings.initialState()
        mtkView = ViewerMTKView(frame: .zero, device: renderer.device)
        super.init()

        // The view holds only its drawables; the renderer brings the multisampled colour
        // and depth a frame is drawn into, which take no memory of the process.
        mtkView.colorPixelFormat = MetalRenderer.colorFormat
        // To VoiceOver the picture is one image; the controls around it say the rest.
        mtkView.setAccessibilityElement(true)
        mtkView.setAccessibilityRole(.image)
        mtkView.setAccessibilityLabel(L10n.text("3D model"))
        mtkView.setAccessibilityRoleDescription(L10n.text("3D view"))
        installAccessibilityActions()
        mtkView.depthStencilPixelFormat = .invalid
        mtkView.sampleCount = 1
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.preferredFramesPerSecond = Self.framesPerSecond
        mtkView.autoResizeDrawable = true
        mtkView.delegate = self
        (mtkView.layer as? CAMetalLayer)?.isOpaque = false
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mtkView)
        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: container.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        @discardableResult
        func overlay<V: View>(_ content: V, quiet: Bool = true, measured: Bool = false, _ place: (NSView, NSView) -> [NSLayoutConstraint]) -> NSView {
            let host = MeasuredHostingView(rootView: content)
            if measured { host.onSizeChange = { [weak self] in self?.placeStatistics() } }
            if quiet { chrome.append(host) }
            host.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host)
            NSLayoutConstraint.activate(place(host, container))
            return host
        }
        // Under the controls, and never in the way of the mouse: the light a model opens in.
        let frame = PassthroughHost(rootView: OpeningLight(model: model))
        frame.translatesAutoresizingMaskIntoConstraints = false
        // It takes the view's size and has no say in it.
        frame.sizingOptions = []
        container.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.leadingAnchor.constraint(equalTo: container.leadingAnchor), frame.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            frame.topAnchor.constraint(equalTo: container.topAnchor), frame.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        barHost = overlay(ViewsBar(model: model), measured: true) {
            let middle = $0.centerXAnchor.constraint(equalTo: $1.centerXAnchor)
            barMiddle = middle
            return [middle, $0.bottomAnchor.constraint(equalTo: $1.bottomAnchor, constant: -NativeViewer.edge)]
        }
        overlay(ViewerSettingsAnchor(model: model, light: false), quiet: false) {
            [$0.centerXAnchor.constraint(equalTo: $1.centerXAnchor),
             $0.bottomAnchor.constraint(equalTo: $1.bottomAnchor, constant: -NativeViewer.edge - 24)]
        }
        overlay(ViewerSettingsAnchor(model: model, light: true), quiet: false) {
            [$0.trailingAnchor.constraint(equalTo: $1.trailingAnchor, constant: -NativeViewer.edge - 24),
             $0.topAnchor.constraint(equalTo: $1.topAnchor, constant: NativeViewer.edge + 140)]
        }
        // Above the views bar and over its middle, wherever that is.
        let viewsBar = barHost
        animationHost = overlay(AnimationBar(model: model), measured: true) {
            let foot = $0.bottomAnchor.constraint(equalTo: $1.bottomAnchor, constant: -NativeViewer.edge)
            animationFoot = foot
            return [$0.centerXAnchor.constraint(equalTo: (viewsBar ?? $1).centerXAnchor), foot]
        }
        let help = toolbarHelp? { [weak self] content in self?.showHelpDocument(content) }
        sideHost = overlay(SideControls(model: model, toolbarHelp: help), measured: true) { [$0.trailingAnchor.constraint(equalTo: $1.trailingAnchor, constant: -NativeViewer.edge),
                                               $0.topAnchor.constraint(equalTo: $1.topAnchor, constant: NativeViewer.edge)] }
        // Facts about the model are read, not used: they do not step back with the controls.
        statisticsHost = overlay(StatisticsView(model: model), quiet: false, measured: true) {
            let foot = $0.bottomAnchor.constraint(equalTo: $1.bottomAnchor, constant: -NativeViewer.edge)
            statisticsFoot = foot
            let trailing = $0.trailingAnchor.constraint(equalTo: $1.trailingAnchor, constant: -NativeViewer.edge)
            statisticsTrailing = trailing
            return [trailing, foot]
        }
        // What asks for something, and what says why nothing is shown, do not fade.
        noticeHost = overlay(NoticeView(model: model), quiet: false, measured: true) { [$0.leadingAnchor.constraint(equalTo: $1.leadingAnchor, constant: NativeViewer.edge),
                                             $0.topAnchor.constraint(equalTo: $1.topAnchor, constant: NativeViewer.edge),
                                             $0.widthAnchor.constraint(lessThanOrEqualTo: $1.widthAnchor, constant: -120)] }
        overlay(LoadingView(model: model), quiet: false) { [$0.centerXAnchor.constraint(equalTo: $1.centerXAnchor),
                                                              $0.centerYAnchor.constraint(equalTo: $1.centerYAnchor)] }
        overlay(MessageView(model: model), quiet: false) { [$0.centerXAnchor.constraint(equalTo: $1.centerXAnchor),
                                              $0.centerYAnchor.constraint(equalTo: $1.centerYAnchor),
                                              $0.widthAnchor.constraint(lessThanOrEqualTo: $1.widthAnchor, constant: -40)] }

        container.onResize = { [weak self] size in
            self?.model.visibility = ControlsVisibility(size: size)
            self?.model.compactSideControls = size.height < 500
            self?.model.barAvailableWidth = max(0, size.width - 2 * NativeViewer.edge)
            // Beside the bar where there is room for both, above it where there is not.
            self?.placeStatistics()
        }
        model.onChange = { [weak self] in self?.syncRenderer(); self?.refreshAccessibilityValue(); self?.onCommandStateChange?() }
        model.onLayoutChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.placeStatistics() }
        }
        model.onFit = { [weak self] in self?.fit() }
        model.onGrant = { [weak self] in self?.askForTheFolder() }
        model.onClip = { [weak self] in
            guard let self else { return }
            self.clipTime = 0
            self.model.clock.progress = 0
            self.lastFrame = nil
            self.requestDraw()
            self.onCommandStateChange?()
        }
        model.onSeek = { [weak self] position in
            guard let self, let scene = self.renderer.scene, scene.clips.indices.contains(self.model.clip) else { return }
            // Seeking pauses, so the chosen moment stays on screen.
            self.model.playing = false
            self.clipTime = Float(min(max(position, 0), 1)) * scene.clips[self.model.clip].duration
            self.model.clock.progress = min(max(position, 0), 1)
            self.requestDraw()
        }
        // Only while the model itself has the keyboard: a slider with the keyboard keeps its arrows.
        mtkView.onArrow = { [weak self] key in
            guard let self, self.orbitsWithArrowKeys, self.model.statistics != nil else { return false }
            self.perform([123: .orbitLeft, 124: .orbitRight, 125: .orbitDown, 126: .orbitUp][key] ?? .orbitLeft)
            return true
        }
        mtkView.onPanArrow = { [weak self] key in
            guard let self, self.orbitsWithArrowKeys, self.model.statistics != nil else { return false }
            self.perform([123: .panLeft, 124: .panRight, 125: .panDown, 126: .panUp][key] ?? .panLeft)
            return true
        }
        // Only where the viewer is asked to: in Quick Look the space bar closes the preview.
        mtkView.onSpace = { [weak self] in
            guard let self, self.playsWithSpaceKey, !self.model.clipNames.isEmpty else { return false }
            self.model.playing.toggle()
            return true
        }
        model.onLook = { [weak self] in self?.look(along: $0) }
        model.onGizmoDrag = { [weak self] dx, dy in self?.orbit(dx: dx, dy: dy, height: GizmoView.size * 2) }
        mtkView.onOrbit = { [weak self] dx, dy in
            guard let self else { return }
            self.orbit(dx: dx, dy: dy, height: self.mtkView.bounds.height)
        }
        mtkView.onRotate = { [weak self] degrees in
            // The model turns about the vertical axis the way the fingers turn.
            self?.animation = nil
            self?.renderer.camera.rotate(yaw: -degrees * .pi / 180, pitch: 0)
            self?.requestDraw()
        }
        mtkView.onSmartMagnify = { [weak self] in self?.fit() }
        mtkView.contextMenu = { [weak self] in self?.makeContextMenu() }
        mtkView.onPan = { [weak self] dx, dy in
            guard let self else { return }
            self.animation = nil
            // The picture is drawn smaller than the view; the model stays under the pointer.
            self.renderer.camera.pan(dx: Float(dx), dy: Float(dy), viewHeight: Float(self.mtkView.bounds.height) * self.renderer.pictureScale)
            self.requestDraw()
        }
        mtkView.onZoom = { [weak self] scale, pointer in
            guard let self else { return }
            self.animation = nil
            let size = self.mtkView.bounds.size
            if let pointer, size.height > 0 {
                // What is under the pointer stays under it. The picture fills the view above
                // what covers its bottom, and the camera looks at its middle.
                let height = Float(size.height) * self.renderer.pictureScale
                let middle = SIMD2(Float(size.width) / 2, Float(size.height) - height / 2)
                self.renderer.camera.zoom(scale: scale, toward: SIMD2(Float(pointer.x), Float(pointer.y)) - middle, viewHeight: height,
                                          distanceLimits: self.renderer.distanceLimits)
            } else {
                self.renderer.camera.zoom(scale: scale)
            }
            self.requestDraw()
        }
        resetControls()
    }

    // MARK: Viewer

    public func load(fileAt url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        let format: Format
        do {
            let data = try Data(contentsOf: url.resolvingSymlinksInPath(), options: .mappedIfSafe)
            format = FormatDetector.detect(data, ext: Self.formatHint(for: url))
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        generation += 1
        let mine = generation
        loadTask?.cancel()
        // Until the file has been read there is nothing to control: the controls wait, and
        // the app's mark turns in the middle.
        model.loading = true
        setChrome(alpha: 0, seconds: 0)
        currentURL = url
        let renderer = renderer
        // The model's own folder, when the user has allowed it: opened for the import only.
        let access = folderGrants?.beginAccess(forFileAt: url)
        let granted = access != nil
        loadTask = Task { [weak self] in
            let outcome: Result<Loaded, Error> = await Task.detached(priority: .userInitiated) {
                defer {
                    access?.end()
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let scene = try ImportRouter.load(url, format: format)
                    let statistics = NativeViewerStatistics(scene.topology)
                    let uploaded = try renderer.makeScene(scene)
                    let textured = uploaded.hasTexturedView
                    return .success(Loaded(scene: uploaded, statistics: statistics, textured: textured, missing: scene.diagnostics.missingResources))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, mine == self.generation else { return }
            self.model.loading = false
            self.finishLoad(outcome, granted: granted)
        }
    }

    /// Asks the user for the model's folder and, once allowed, shows the model again with
    /// the files beside it.
    private func askForTheFolder() {
        guard let url = currentURL, let grants = folderGrants else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = MissingFilesNotice.panelMessage(file: url.lastPathComponent)
        panel.prompt = MissingFilesNotice.panelPrompt
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url, grants.grant(folder) else { return }
            try? self?.load(fileAt: url)
        }
        if let window = container.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private func showHelpDocument(_ content: AnyView?) {
        if let host = helpDocumentHost {
            host.removeFromSuperview()
            helpDocumentHost = nil
            container.window?.makeFirstResponder(mtkView)
        }
        guard let content else { return }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        helpDocumentHost = host
        container.window?.makeFirstResponder(host)
    }

    public func resetControls() {
        showHelpDocument(nil)
        animation = nil
        model.surrounding = .glasshouse
        model.lightRotation = 0
        model.rotatesLight = false
        opening = false
        model.apply(initial)
        // Turning by itself is the user's setting, but not when motion is to be reduced:
        // then it starts only from its button.
        if reducesMotion() { model.autoRotate = false }
        renderer.backgroundColor = initial.backgroundColor
        renderer.solidColor = initial.solidColor
        renderer.setViewportSize(mtkView.drawableSize)
        renderer.camera = renderer.homeCamera
        syncRenderer()
    }

    public func takeFocus() {
        container.window?.makeFirstResponder(mtkView)
    }

    /// The camera arrives: from a little farther off and to one side, it comes round to
    /// where the model is first seen from. Not with Reduce Motion, where it is simply there.
    private var opening = false

    private func openOnTheModel() {
        guard !reducesMotion() else { return }
        var from = renderer.homeCamera
        from.yaw += Self.openingYaw
        from.distance *= Self.openingDistance
        renderer.camera = from
        // The move begins with the first frame that is drawn: Quick Look reads the file
        // before the view is on screen, and the arrival is for someone to see.
        opening = true
        lastFrame = nil
        requestDraw()
    }

    private var barHost: NSView?
    private var statisticsHost: NSView?
    private var animationHost: NSView?
    private var sideHost: NSView?
    private var noticeHost: NSView?
    private var statisticsTrailing: NSLayoutConstraint?
    private var animationFoot: NSLayoutConstraint?
    private var statisticsFoot: NSLayoutConstraint?
    private var barMiddle: NSLayoutConstraint?

    /// Lays out the bottom of the view (see `ControlsVisibility.bottomRow`). Measured, as
    /// the bar is wider with a Textured view and the statistics with larger numbers.
    func placeStatistics() {
        guard let bar = barHost, let statistics = statisticsHost else { return }
        let barSize = model.visibility.controls && model.flags.showViewsBar ? bar.fittingSize : .zero
        let animationSize = model.visibility.controls && model.flags.showAnimationBar && !model.clipNames.isEmpty
            ? animationHost?.fittingSize ?? .zero : .zero
        let statsWidth = model.visibility.stats && model.flags.showStats && model.statistics != nil
            ? statistics.fittingSize.width : 0
        let row = ControlsVisibility.bottomRow(width: container.bounds.width, bar: barSize,
                                               animation: animationSize, statistics: statsWidth)
        statisticsFoot?.constant = -row.statisticsFoot
        animationFoot?.constant = -row.animationFoot
        barMiddle?.constant = -row.barShift

        let bounds = container.bounds
        let statsSize = statistics.fittingSize
        let sideSize = sideHost?.fittingSize ?? .zero
        let noticeSize = noticeHost?.fittingSize ?? .zero
        let rightStats = CGRect(x: bounds.width - Self.edge - statsSize.width, y: row.statisticsFoot,
                                width: statsSize.width, height: statsSize.height)
        let side = CGRect(x: bounds.width - Self.edge - sideSize.width, y: bounds.height - Self.edge - sideSize.height,
                          width: sideSize.width, height: sideSize.height)
        let notice = CGRect(x: Self.edge, y: bounds.height - Self.edge - noticeSize.height,
                            width: noticeSize.width, height: noticeSize.height)
        let leftStats = CGRect(x: Self.edge, y: row.statisticsFoot, width: statsSize.width, height: statsSize.height)
        let useLeft = rightStats.intersects(side)
        statisticsTrailing?.constant = useLeft ? -(bounds.width - Self.edge - statsSize.width) : -Self.edge
        statistics.isHidden = useLeft && leftStats.intersects(notice)
    }

    // MARK: Controls

    /// The hosting views of the controls. They are hidden while a file is being read and
    /// shown in full the rest of the time: they never fade.
    private var chrome: [NSView] = []

    private(set) var chromeAlpha: CGFloat = 1

    private func setChrome(alpha: CGFloat, seconds: TimeInterval) {
        chromeAlpha = alpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducesMotion() ? 0 : seconds
            chrome.forEach { $0.animator().alphaValue = alpha }
        }
    }

    public var onCommandStateChange: (() -> Void)?
    public var orbitsWithArrowKeys = false
    /// Whether the space bar plays and pauses an animation. Off by default: in Quick Look
    /// the space bar closes the preview, and the key is then passed on.
    public var playsWithSpaceKey = false

    public var clipNames: [String] { model.clipNames }
    public var currentClip: Int { model.clip }
    public func selectClip(_ index: Int) { if model.clipNames.indices.contains(index) { model.clip = index } }

    public func status(of command: ViewerCommand) -> ViewerCommandStatus { model.status(of: command) }

    public func perform(_ command: ViewerCommand) {
        guard model.status(of: command).enabled, !model.perform(command) else { return }
        // What is left moves the camera.
        let height = max(mtkView.bounds.height, 1), step = height * ViewerCommand.orbitStep
        switch command {
        case .orbitLeft: orbit(dx: step, dy: 0, height: height)
        case .orbitRight: orbit(dx: -step, dy: 0, height: height)
        case .orbitUp: orbit(dx: 0, dy: step, height: height)
        case .orbitDown: orbit(dx: 0, dy: -step, height: height)
        case .panLeft: mtkView.onPan?(-step, 0)
        case .panRight: mtkView.onPan?(step, 0)
        case .panUp: mtkView.onPan?(0, -step)
        case .panDown: mtkView.onPan?(0, step)
        case .zoomIn: mtkView.onZoom?(ViewerCommand.zoomStep, nil)
        case .zoomOut: mtkView.onZoom?(1 / ViewerCommand.zoomStep, nil)
        default: break
        }
    }

    // MARK: Accessibility

    /// What VoiceOver is told of the picture: the file, its size, the look and where it is seen from.
    static func accessibilityValue(fileName: String?, faces: Int, look: RenderLook, direction: ViewPreset) -> String {
        var parts: [String] = []
        if let fileName, !fileName.isEmpty { parts.append(fileName) }
        parts.append(faces == 1 ? L10n.text("1 face") : L10n.format("%@ faces", String(describing: faces.formatted(.number))))
        switch look.view {
        case .solid: parts.append(L10n.text("Solid view"))
        case .textured: parts.append(L10n.text("Textured view"))
        case .normal: parts.append(L10n.text("Normal view"))
        }
        if look.style != .none, let style = StyleButton.all.first(where: { $0.style == look.style }) { parts.append(style.label) }
        if look.wire { parts.append(L10n.text("wireframe on")) }
        switch direction {
        case .front: parts.append(L10n.text("seen from the front"))
        case .back: parts.append(L10n.text("seen from the back"))
        case .left: parts.append(L10n.text("seen from the left"))
        case .right: parts.append(L10n.text("seen from the right"))
        case .top: parts.append(L10n.text("seen from the top"))
        case .bottom: parts.append(L10n.text("seen from the bottom"))
        }
        return parts.joined(separator: ", ")
    }

    static func directionName(_ preset: ViewPreset) -> String {
        switch preset {
        case .front: return "front"
        case .back: return "back"
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }

    /// The preset whose direction is nearest the camera's own.
    static func nearestDirection(_ basis: GizmoBasis) -> ViewPreset {
        ViewGizmo.handles(basis).last?.preset ?? .front
    }

    private var lastAccessibilityValue: String?

    /// Keeps the picture's accessibility value true; sets it only when it has changed.
    func refreshAccessibilityValue() {
        var value: String?
        if let statistics = model.statistics {
            let (right, up, back) = renderer.camera.basis
            value = Self.accessibilityValue(fileName: currentURL?.lastPathComponent, faces: statistics.faces, look: model.look,
                                            direction: Self.nearestDirection(GizmoBasis(right: right, up: up, back: back)))
        }
        guard value != lastAccessibilityValue else { return }
        lastAccessibilityValue = value
        mtkView.setAccessibilityValue(value)
    }

    /// Moving the model without a pointer: the actions an assistive technology offers on the picture.
    private func installAccessibilityActions() {
        let commands: [ViewerCommand] = [.orbitLeft, .orbitRight, .orbitUp, .orbitDown, .panLeft, .panRight, .panUp, .panDown, .zoomIn, .zoomOut, .fit]
        mtkView.setAccessibilityCustomActions(commands.map { command in
            NSAccessibilityCustomAction(name: command.title) { [weak self] in
                MainActor.assumeIsolated { self?.perform(command) }
                return true
            }
        })
    }

    // MARK: Contextual menu

    /// The menu of a secondary click, made new each time so that its ticks and dimming are
    /// what the controls would show. Every command stays reachable here, as Quick Look has no menu bar.
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        func item(_ command: ViewerCommand) -> NSMenuItem {
            let status = model.status(of: command)
            let entry = NSMenuItem(title: command.title(on: status.on), action: #selector(chooseFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = command.rawValue
            entry.isEnabled = status.enabled
            entry.state = command.isState && status.on ? .on : .off
            let needsTexture = ViewerCommand.styles[command].map { style in StyleButton.all.first { $0.style == style }?.needsTexture ?? false }
                ?? (ViewerCommand.views[command] == .textured)
            if !status.enabled, needsTexture, !model.hasTextured { entry.toolTip = ViewerTips.needsTexture }
            return entry
        }
        let groups: [[ViewerCommand]] = [
            [.solid, .textured, .normal],
            [.wireframe],
            [.unlit, .anime, .celShaded, .retro, .voxel, .hologram],
        ]
        for group in groups {
            group.forEach { menu.addItem(item($0)) }
            menu.addItem(.separator())
        }
        let lookFrom = NSMenuItem(title: L10n.text("Look From"), action: nil, keyEquivalent: "")
        let presets = NSMenu(title: L10n.text("Look From"))
        presets.autoenablesItems = false
        [ViewerCommand.front, .back, .left, .right, .top, .bottom].forEach { presets.addItem(item($0)) }
        lookFrom.submenu = presets
        lookFrom.isEnabled = model.statistics != nil
        menu.addItem(lookFrom)
        menu.addItem(.separator())
        [ViewerCommand.fit, .zoomIn, .zoomOut].forEach { menu.addItem(item($0)) }
        menu.addItem(.separator())
        [ViewerCommand.grid, .autoRotate].forEach { menu.addItem(item($0)) }
        menu.addItem(.separator())
        menu.addItem(item(.playPause))
        menu.addItem(.separator())
        let pan = NSMenuItem(title: L10n.text("Pan"), action: nil, keyEquivalent: "")
        let panMenu = NSMenu(title: L10n.text("Pan"))
        panMenu.autoenablesItems = false
        [ViewerCommand.panLeft, .panRight, .panUp, .panDown].forEach { panMenu.addItem(item($0)) }
        pan.submenu = panMenu
        menu.addItem(pan)
        menu.addItem(.separator())
        [ViewerCommand.showViewSettings, .showLightSettings, .showTextures].forEach { menu.addItem(item($0)) }
        return menu
    }

    @objc private func chooseFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let command = ViewerCommand(rawValue: name) else { return }
        perform(command)
    }

    // MARK: Loading

    static func formatHint(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.count <= 8 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : ""
    }

    private func finishLoad(_ outcome: Result<Loaded, Error>, granted: Bool = false) {
        switch outcome {
        case .success(let loaded):
            renderer.show(loaded.scene)
            let clips = loaded.scene.isSkinned ? loaded.scene.clips : []
            model.clipNames = clips.enumerated().map { $0.element.name.isEmpty ? L10n.format("Clip %@", String(describing: $0.offset + 1)) : $0.element.name }
            model.onlyClipName = clips.count == 1 && !clips[0].name.trimmingCharacters(in: .whitespaces).isEmpty ? clips[0].name : nil
            model.clip = 0
            clipTime = 0
            model.clock.progress = 0
            model.playing = initial.autoplay && !clips.isEmpty
            model.repeats = initial.repeatAnimations
            model.statistics = loaded.statistics
            model.message = nil
            onCommandStateChange?()
            // Once the bar and the statistics have their sizes for this model.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.container.layoutSubtreeIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.container.layoutSubtreeIfNeeded()
                    self.placeStatistics()
                }
            }
            // The controls are shown with the model, and stay.
            setChrome(alpha: 1, seconds: 0.15)
            model.hasTextured = loaded.textured
            model.notice = MissingFilesNotice(missing: loaded.missing, granted: granted, canGrant: folderGrants != nil)
            onCommandStateChange?()
            // A new model is built up anew.
            hologramStart = nil
            resetControls()
            openOnTheModel()
            refreshAccessibilityValue()
        case .failure(let error):
            renderer.clearScene()
            // Nothing is said about textures of a model that could not be shown. Only when
            // its own data is beside it, out of reach, is the folder offered.
            model.notice = MissingFilesNotice(missing: (error as? MissingFilesReporting)?.missingFiles ?? [], granted: granted, canGrant: folderGrants != nil, failed: true)
            model.clipNames = []
            model.onlyClipName = nil
            model.playing = false
            model.statistics = nil
            model.hasTextured = true
            // Localized errors already provide a user-facing explanation in the app language.
            let reason = error.localizedDescription
            model.message = error is LocalizedError ? reason : L10n.format("This file could not be shown.\n%@", String(describing: reason))
            refreshAccessibilityValue()
            onCommandStateChange?()
            setChrome(alpha: 1, seconds: 0.15)
            requestDraw()
        }
    }

    // MARK: Renderer state

    private func syncRenderer() {
        if model.look.style == .hologram, renderer.look.style != .hologram { hologramStart = nil }
        renderer.look = model.look
        renderer.lightIntensity = model.lightIntensity
        renderer.surrounding = model.surrounding
        renderer.lightRotation = model.lightRotation * .pi / 180
        renderer.showGrid = model.showGrid
        if model.look.wire, let scene = renderer.scene, !scene.isWireReady {
            scene.prepareWireAsync { [weak self] in
                DispatchQueue.main.async { self?.requestDraw() }
            }
        }
        if model.look.needsOutline, let scene = renderer.scene, !scene.isOutlineReady {
            scene.prepareOutlineAsync { [weak self] in
                DispatchQueue.main.async { self?.requestDraw() }
            }
        }
        lastFrame = nil
        requestDraw()
    }

    private func requestDraw() { mtkView.needsDisplay = true }

    /// How much of the view's bottom the controls cover, in points.
    static let barHeight: CGFloat = 56
    static let playerHeight: CGFloat = 40

    /// The scene whose materials move their images, and when that began.
    private weak var movingScene: GPUScene?
    private var movingStart: CFTimeInterval = 0

    /// The scene whose springs (hair, skirts) have been started.
    private weak var sprungScene: GPUScene?

    /// The clip and the moment in it the springs of `sprungScene` were last brought to rest at.
    private var settledPose: (clip: Int?, time: Float)?

    /// The time the springs of `scene` are moved by in this frame. When motion is to be
    /// reduced they are shown where they come to rest in the pose on screen and never swing.
    private func springTime(_ dt: Float, for scene: GPUScene, clip: Int? = nil, time: Float = 0) -> Float {
        guard scene.hasSprings else { return 0 }
        if reducesMotion() {
            // Brought to rest again whenever the pose changes: left where they were, they
            // would trail behind what a clip moves, pointing at where it had been.
            if sprungScene !== scene {
                scene.settleSprings(clip: clip, time: time)
            } else if settledPose?.clip != clip || settledPose?.time != time {
                // From where they rested a moment ago it is not far: a second is plenty.
                scene.settleSprings(clip: clip, time: time, longest: 1)
            }
            sprungScene = scene
            settledPose = (clip, time)
            return 0
        }
        settledPose = nil
        if sprungScene !== scene {
            // The first frame only starts them: the time before it is not theirs.
            sprungScene = scene
            return 1.0 / 60
        }
        return dt > 0 ? dt : 1.0 / 60
    }

    private func orbit(dx: CGFloat, dy: CGFloat, height: CGFloat) {
        animation = nil
        renderer.camera.orbit(dx: Float(dx), dy: Float(dy), viewHeight: Float(height))
        requestDraw()
    }

    private func move(to camera: OrbitCamera) {
        animationDuration = Self.moveDuration
        animation = (renderer.camera, camera, CACurrentMediaTime())
        lastFrame = nil
        requestDraw()
    }

    private func fit() {
        renderer.setViewportSize(mtkView.drawableSize)
        move(to: renderer.homeCamera)
    }

    private func look(along preset: ViewPreset) {
        renderer.setViewportSize(mtkView.drawableSize)
        move(to: OrbitCamera.preset(preset, framing: renderer.framing, like: renderer.camera, aspect: renderer.viewportAspect))
    }

    /// Frames the model at an explicit angle, with room for the controls beside it.
    @_spi(MediaCapture) public func frameModel(yaw: Float, pitch: Float) {
        guard renderer.scene != nil, yaw.isFinite, pitch.isFinite else { return }
        opening = false
        renderer.setViewportSize(mtkView.drawableSize)
        var camera = renderer.camera
        camera.yaw = yaw
        camera.pitch = min(OrbitCamera.maxPitch, max(-OrbitCamera.maxPitch, pitch))
        var framing = renderer.framing
        // Fit every corner in the new projection, permitting closer framing of shallow models.
        framing.distance *= 0.65
        move(to: camera.fitted(to: framing, aspect: renderer.viewportAspect * 0.85))
    }

    /// Wire edges are prepared in the background after that view is selected.
    @_spi(MediaCapture) public var isWireframeReady: Bool { renderer.scene?.isWireReady == true }

    /// Presents the current frame when the capture window is waiting for its next redraw.
    @_spi(MediaCapture) public func drawCaptureFrame() { mtkView.draw() }

    /// Enables the viewer's on-canvas controls for a reviewer in the capture instance.
    @_spi(MediaCapture) public func prepareReviewControls() {
        var flags = model.flags
        flags.showViewsBar = true
        flags.showFitButton = true
        flags.showLightButton = true
        flags.showGridButton = true
        flags.showRotateButton = true
        flags.showGizmo = true
        flags.showStats = true
        flags.showAnimationBar = true
        model.flags = flags
    }

    @_spi(MediaCapture) public func closeReviewPanels() {
        model.showsLightSettings = false
        model.showsViewSettings = false
    }

    @_spi(MediaCapture) public func adjustReviewLight(brightness: Float, direction: Float, rotates: Bool = false) {
        model.lightIntensity = brightness
        model.lightRotation = direction
        model.rotatesLight = rotates
    }

    @_spi(MediaCapture) public func adjustReviewMaterial(pbr: Bool, metallic: Float?, roughness: Float?) {
        var look = model.look
        look.pbr = pbr
        look.metallic = metallic
        look.roughness = roughness
        model.look = look
    }

    @_spi(MediaCapture) public func seekReviewAnimation(position: Double) { model.onSeek?(position) }

    @_spi(MediaCapture) public var mediaReviewHasFaces: Bool { (model.statistics?.faces ?? 0) > 0 }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.setViewportSize(size)
        if var move = animation {
            move.to = move.to.fitted(to: renderer.framing, aspect: renderer.viewportAspect)
            animation = move
        }
        requestDraw()
    }

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(lastFrame.map { now - $0 } ?? 1.0 / 60)
        var again = false
        // Set by what should look smooth: a camera move, a playing clip, the hologram's arrival.
        var quick = false
        if opening {
            opening = false
            animationDuration = Self.openingDuration
            animation = (renderer.camera, renderer.homeCamera, now)
        }
        if let a = animation {
            // With Reduce Motion the camera is where it is going, at once.
            let t = reducesMotion() ? 1 : Float(min(1, (now - a.start) / animationDuration))
            // A long move comes to rest gently; a short one eases both ways.
            let eased = animationDuration > Self.moveDuration ? 1 - pow(1 - t, 3) : t * t * (3 - 2 * t)
            renderer.camera = OrbitCamera.blend(a.from, a.to, eased)
            if t >= 1 { animation = nil } else { again = true; quick = true }
        } else {
            if model.autoRotate {
                renderer.camera.rotate(yaw: dt * Self.autoRotateSpeed, pitch: 0)
                again = true
            }
            renderer.camera.step(dt: dt, distanceLimits: renderer.distanceLimits)
            if renderer.camera.isMoving { again = true; quick = true }
        }

        // The light goes round by itself, when asked to.
        if model.rotatesLight {
            model.lightDirection.degrees = (model.lightRotation + dt * Self.lightTurnSpeed).truncatingRemainder(dividingBy: 360)
            renderer.lightRotation = model.lightRotation * .pi / 180
            again = true
        }

        // Skinned parts are moved to the current moment of the current clip.
        if let scene = renderer.scene, scene.isSkinned {
            if scene.clips.indices.contains(model.clip) {
                let duration = scene.clips[model.clip].duration
                if model.playing, duration > 0 {
                    // Played from its end, a clip starts over.
                    if clipTime >= duration { clipTime = 0 }
                    clipTime += dt
                    var ended = false
                    if clipTime >= duration {
                        if model.repeats { clipTime = clipTime.truncatingRemainder(dividingBy: duration) } else { clipTime = duration; ended = true }
                    }
                    if ended {
                        // Played once: it stays on its last moment.
                        model.clock.progress = 1
                        model.playing = false
                    } else {
                        // The scrubber is moved 30 times a second: redrawing the controls for every
                        // frame costs more than drawing the model.
                        if now - lastScrubberUpdate >= 1.0 / 30 {
                            lastScrubberUpdate = now
                            model.clock.progress = Double(clipTime / duration)
                        }
                        again = true
                        quick = true
                    }
                }
                if scene.pose(clip: model.clip, time: clipTime, elapsed: springTime(dt, for: scene, clip: model.clip, time: clipTime)) { again = true; quick = true }
            } else if scene.pose(elapsed: springTime(dt, for: scene)) {
                again = true
                quick = true
            }
        }

        // A material that slides or turns its images keeps the picture changing, where the
        // model's own look shows and unless motion is to be reduced.
        if let scene = renderer.scene, renderer.showsMovingTextures, !reducesMotion() {
            if movingScene !== scene { movingScene = scene; movingStart = now }
            renderer.materialSeconds = now - movingStart
            again = true
        }

        // The hologram never stands still, unless motion is to be reduced.
        if renderer.look.style == .hologram, renderer.scene != nil {
            let still = reducesMotion()
            renderer.hologramStill = still
            if hologramStart == nil { hologramStart = now }
            renderer.hologramSeconds = now - (hologramStart ?? now)
            if !still {
                again = true
                if HologramTimeline(seconds: renderer.hologramSeconds).settled < 1 { quick = true }
            }
        }

        let (right, up, back) = renderer.camera.basis
        let basis = GizmoBasis(right: right, up: up, back: back)
        // While the view keeps turning the gizmo follows 30 times a second (redrawing it
        // costs more than drawing the model); the frame the view comes to rest on always counts.
        if model.gizmo.basis != basis, !again || now - lastGizmoUpdate >= 1.0 / 30 {
            lastGizmoUpdate = now
            model.gizmo.basis = basis
        }

        if let drawable = view.currentDrawable, let commands = queue.makeCommandBuffer() {
            renderer.pixelsPerPoint = Float(view.drawableSize.height / max(view.bounds.height, 1))
            // The bar of controls along the bottom, and the player above it when there are clips.
            let covered = Self.barHeight + ((renderer.scene?.clips.isEmpty ?? true) ? 0 : Self.playerHeight)
            renderer.bottomInset = Float(covered / max(view.bounds.height, 1))
            renderer.encode(into: commands, target: drawable.texture)
            commands.present(drawable)
            commands.commit()
        }
        lastFrame = again ? now : nil
        // A move has come to rest: say where the camera is.
        if !again { refreshAccessibilityValue() }
        let rate = quick ? Self.framesPerSecond : Self.driftFramesPerSecond
        if again, mtkView.preferredFramesPerSecond != rate { mtkView.preferredFramesPerSecond = rate }
        setContinuous(again)
    }
}
