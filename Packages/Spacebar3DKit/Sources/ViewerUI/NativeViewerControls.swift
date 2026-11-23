import ModelCore
import Combine
import RenderMetal
import SwiftUI

/// What the controls show and edit. The viewer applies every change to the renderer
/// through `onChange`.
@MainActor
final class NativeViewerModel: ObservableObject {
    @Published var look = RenderLook() {
        didSet {
            let rules = look.constrained(textured: hasTextured)
            if rules != look { look = rules }
            onChange?()
        }
    }
    @Published var lightIntensity: Float = 1 { didSet { onChange?() } }
    /// Where the light comes from, how far it is turned (degrees, 0...360), and whether it
    /// keeps turning by itself.
    @Published var surrounding = Surrounding.glasshouse { didSet { onChange?() } }
    // Frame updates redraw only the light panel and do not reapply all renderer settings.
    let lightDirection = LightDirection()
    var lightRotation: Float {
        get { lightDirection.degrees }
        set { lightDirection.degrees = newValue; onChange?() }
    }
    @Published var rotatesLight = false { didSet { onChange?() } }
    @Published var showGrid = true { didSet { onChange?() } }
    @Published var autoRotate = false { didSet { onChange?() } }
    /// False for a model with no appearance of its own (`ModelScene.hasTexturedAppearance`):
    /// no Textured view, Unlit and Cartoon disabled. Changing it re-applies the rules to the look.
    @Published var hasTextured = true { didSet { if hasTextured != oldValue { look = look } } }
    @Published var flags = NativeViewerState(NativeViewerSettings())
    @Published var statistics: NativeViewerStatistics?
    @Published var message: String?
    /// A file is being read.
    @Published var loading = false
    /// Shown when files the model names could not be read.
    @Published var notice: MissingFilesNotice?
    /// Whether the canvas's two popovers are open; the menus open them too.
    @Published var showsViewSettings = false
    @Published var showsLightSettings = false
    /// The camera's axes change with every frame of a turning view, so they are kept
    /// apart: only the gizmo is redrawn for them, not every control.
    let gizmo = GizmoState()
    @Published var barAvailableWidth: CGFloat = 448
    @Published var compactSideControls = false
    @Published var visibility = ControlsVisibility(size: .zero)

    /// The model's animations by name; empty for a model that has none.
    @Published var clipNames: [String] = []
    /// The name the file gives its one clip, when it has one clip and names it.
    @Published var onlyClipName: String?
    @Published var clip = 0 { didSet { if clip != oldValue { onClip?() } } }
    @Published var playing = false { didSet { if playing != oldValue { onChange?() } } }
    /// Whether a clip starts over when it ends; otherwise it plays once and stops on its last moment.
    @Published var repeats = false { didSet { if repeats != oldValue { onChange?() } } }
    /// Where playback is, kept apart so that only the scrubber redraws as it moves.
    let clock = AnimationClock()

    var onChange: (() -> Void)?
    var onClip: (() -> Void)?
    /// A position chosen on the scrubber, 0...1.
    var onSeek: ((Double) -> Void)?
    var onLayoutChange: (() -> Void)?
    var onFit: (() -> Void)?
    /// The user asks to allow the model's folder.
    var onGrant: (() -> Void)?
    var onLook: ((ViewPreset) -> Void)?
    var onGizmoDrag: ((CGFloat, CGFloat) -> Void)?

    func apply(_ state: NativeViewerState) {
        flags = state
        look = state.look.constrained(textured: hasTextured)
        lightIntensity = state.lightIntensity
        showGrid = state.showGrid
        autoRotate = state.autoRotate
    }
}

/// How the bar's controls act on one another, as pure functions.
extension RenderLook {
    var isFlatStyle: Bool { style == .unlit || style == .anime }

    /// Choosing a view. Normal has no Unlit or Cartoon version, so it leaves those styles.
    func selecting(view chosen: RenderLook.View) -> RenderLook {
        var l = self
        l.view = chosen
        if chosen == .normal && l.isFlatStyle { l.style = .none }
        return l
    }

    /// The wireframe button. From a style it leaves the style for Textured with the wire on;
    /// otherwise it toggles the wire.
    func togglingWire() -> RenderLook {
        var l = self
        if style != .none { l.style = .none; l.view = .textured; l.wire = true } else { l.wire.toggle() }
        return l
    }

    /// A style button: the active one switches off. A style is shown without the wire. On a
    /// model with an appearance of its own, turning any style on goes to the Textured view;
    /// on one without, the view stays, except that Unlit and Cartoon do not show Normal.
    func toggling(style chosen: RenderLook.Style, textured: Bool) -> RenderLook {
        var l = self
        l.style = style == chosen ? .none : chosen
        if l.style != .none {
            l.wire = false
            if textured || (l.isFlatStyle && l.view == .normal) { l.view = .textured }
        }
        return l
    }

    /// A model with no appearance of its own is shown in Solid, with no Unlit or Cartoon.
    func constrained(textured: Bool) -> RenderLook {
        var l = self
        if !textured {
            if l.view == .textured { l.view = .solid }
            if l.isFlatStyle { l.style = .none }
        }
        return l
    }
}

final class GizmoState: ObservableObject {
    @Published var basis = GizmoBasis()
}

final class LightDirection: ObservableObject {
    @Published var degrees: Float = 0
}

final class AnimationClock: ObservableObject {
    /// 0...1 through the current clip.
    @Published var progress: Double = 0
}

/// Short hover labels. Disabled controls retain an explanation when needed.
enum ViewerTips {
    static let wireframe = L10n.text("Wireframe")
    static let viewSettings = L10n.text("View settings")
    static let fit = L10n.text("Zoom to fit")
    static let light = L10n.text("Light")
    static let grid = L10n.text("Floor grid")
    static let autoRotate = L10n.text("Auto-rotate")
    static let play = L10n.text("Play")
    static let pause = L10n.text("Pause")
    static let clip = L10n.text("Clip")
    /// For a file that has only one animation, so that there is nothing to choose.
    static let onlyClip = L10n.text("Clip")
    static let scrubber = L10n.text("Animation position")
    static let repeats = L10n.text("Repeat animations")
    /// Why a style cannot be chosen: it restyles the model's own textures and colors.
    static let needsTexture = L10n.text("Needs a model with textures or colors")
    /// Under the shading choice of the view settings, outside the Textured view.
    static let materialNote = L10n.text("Material settings apply to the Textured view.")
}

/// Above the bottom bar, for models with animation: play or pause, the clip when there is
/// more than one, and the position, which can be dragged (dragging pauses, so the chosen
/// moment stays on screen).
struct AnimationBar: View {
    @ObservedObject var model: NativeViewerModel

    var body: some View {
        if model.visibility.controls && model.flags.showAnimationBar && !model.clipNames.isEmpty {
            Pill {
                HStack(spacing: 8) {
                    Button { model.playing.toggle() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 14)
                    }
                    .gardenButton()
                    .help(model.playing ? ViewerTips.pause : ViewerTips.play)
                    .accessibilityLabel(model.playing ? L10n.text("Pause") : L10n.text("Play"))
                    if model.clipNames.count > 1 {
                        GardenPicker(L10n.text("Animation clip"),
                                     selectedTitle: model.clipNames.indices.contains(model.clip) ? model.clipNames[model.clip] : "",
                                     selection: $model.clip, showsLabel: false) {
                            ForEach(Array(model.clipNames.enumerated()), id: \.offset) { Text($0.element).font(GardenTypography.body).tag($0.offset) }
                        }
                        .labelsHidden().frame(width: 180).help(ViewerTips.clip)
                    } else if let name = model.onlyClipName {
                        // Nothing to choose from, but the file's name for its motion is worth seeing.
                        Text(name).font(GardenTypography.supporting).foregroundStyle(NeonGarden.text2.color).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 140).fixedSize(horizontal: true, vertical: false)
                            .help(ViewerTips.onlyClip).accessibilityLabel(L10n.format("Animation clip: %@", String(describing: name)))
                    }
                    Scrubber(clock: model.clock) { model.onSeek?($0) }
                    Toggle(isOn: $model.repeats) { Image(systemName: "repeat") }
                        .toggleStyle(GardenToggleStyle())
                        .help(ViewerTips.repeats)
                        .accessibilityLabel(L10n.text("Repeat"))
                }
                .frame(maxWidth: max(0, model.barAvailableWidth - 16))
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in model.onLayoutChange?() }
        }
    }
}

private struct Scrubber: View {
    @ObservedObject var clock: AnimationClock
    var seek: (Double) -> Void

    var body: some View {
        Slider(value: Binding(get: { clock.progress }, set: { seek($0) }), in: 0...1)
            .frame(minWidth: 60, idealWidth: 220, maxWidth: 220)
            .help(ViewerTips.scrubber)
            .gardenSlider()
            .accessibilityLabel(L10n.text("Animation position"))
    }
}

/// Bottom bar: Solid / Textured / Normal, the wireframe toggle, the styles, the view settings.
struct ViewsBar: View {
    @ObservedObject var model: NativeViewerModel

    var body: some View {
        if model.visibility.controls && model.flags.showViewsBar {
            Pill {
                ViewThatFits(in: .horizontal) {
                    controls(compact: false)
                    controls(compact: true)
                }
                .frame(maxWidth: max(0, model.barAvailableWidth - 16))
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in model.onLayoutChange?() }
        }
    }

    private var selection: Binding<RenderLook.View> {
        Binding(get: { model.look.view }, set: { model.look = model.look.selecting(view: $0) })
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if compact {
                GardenPicker(L10n.text("View"),
                             selectedTitle: ViewsBar.views.first { $0.value == selection.wrappedValue }?.title ?? "",
                             selection: selection, showsLabel: false) {
                    ForEach(ViewsBar.views, id: \.value) { option in
                        Text(option.title).font(GardenTypography.body).tag(option.value)
                            .disabled(option.value == .textured && !model.hasTextured)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            } else {
                GardenSegments(label: L10n.text("View"), options: ViewsBar.views, selection: selection, disabledOption: model.hasTextured ? nil : .textured)
                    .fixedSize()
            }
            Toggle(isOn: Binding(get: { model.look.wire }, set: { _ in model.look = model.look.togglingWire() })) {
                Image(systemName: ViewsBar.wireframeIcon)
            }
            .toggleStyle(GardenToggleStyle()).help(ViewerTips.wireframe).accessibilityLabel(L10n.text("Wireframe"))
            GardenRule()
            ForEach(StyleButton.all) { entry in
                Toggle(isOn: Binding(get: { model.look.style == entry.style },
                                     set: { _ in model.look = model.look.toggling(style: entry.style, textured: model.hasTextured) })) {
                    entry.glyph
                }
                .toggleStyle(GardenToggleStyle()).help(ViewsBar.tooltip(for: entry, hasTextured: model.hasTextured)).accessibilityLabel(entry.label)
                .disabled(entry.needsTexture && !model.hasTextured)
            }
            GardenRule()
            Button { model.showsViewSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .gardenButton()
                .help(ViewerTips.viewSettings).accessibilityLabel(L10n.text("View settings"))
        }
    }
}

extension ViewsBar {
    /// The tooltip of a style: what it does, or why it cannot be had just now.
    static func tooltip(for entry: StyleButton, hasTextured: Bool) -> String {
        entry.needsTexture && !hasTextured ? ViewerTips.needsTexture : entry.tip
    }

    /// A wire cube: the model's edges. (The floor grid has the grid.)
    static let wireframeIcon = "cube.transparent"

    /// Keep the view positions stable when Textured is unavailable.
    static var views: [(value: RenderLook.View, title: String)] {
        [(.solid, L10n.text("Solid")), (.textured, L10n.text("Textured")), (.normal, L10n.text("Normal"))]
    }
}

/// A thin upright line between groups of controls.
struct GardenRule: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View { Rectangle().fill(NeonGarden.border(increased: contrast == .increased)).frame(width: 1, height: 18) }
}

/// The style buttons, in the bar's order.
struct StyleButton: Identifiable {
    let style: RenderLook.Style
    let label: String
    let icon: String
    /// Unlit and Cartoon restyle the model's own textures and colours.
    let needsTexture: Bool
    /// What the button does, for its tooltip.
    let tip: String
    var id: String { label }

    @ViewBuilder var glyph: some View {
        if style == .anime {
            Image(icon, bundle: .module)
        } else {
            Image(systemName: icon)
        }
    }

    static let all = [
        StyleButton(style: .unlit, label: L10n.text("Unshaded style"), icon: "circle.lefthalf.filled", needsTexture: true, tip: L10n.text("Unshaded")),
        StyleButton(style: .anime, label: L10n.text("Anime style"), icon: "anime-eye", needsTexture: true, tip: L10n.text("Anime")),
        StyleButton(style: .celShaded, label: L10n.text("Cel-Shaded"), icon: "hexagon.lefthalf.filled", needsTexture: false, tip: L10n.text("Cel-Shaded")),
        StyleButton(style: .retro, label: L10n.text("Retro"), icon: "gamecontroller", needsTexture: false, tip: L10n.text("Retro")),
        StyleButton(style: .voxel, label: L10n.text("Voxel Art"), icon: "square.3.layers.3d", needsTexture: false, tip: L10n.text("Voxel Art")),
        StyleButton(style: .hologram, label: L10n.text("Hologram style"), icon: "sparkles", needsTexture: false, tip: L10n.text("Hologram")),
    ]
}

/// A persistent anchor keeps menu-driven settings available when canvas controls are hidden.
struct ViewerSettingsAnchor: View {
    @ObservedObject var model: NativeViewerModel
    let light: Bool

    var body: some View {
        if !light || !model.visibility.controls || !model.flags.showLightButton {
            Color.clear.frame(width: 1, height: 1)
                .popover(isPresented: light ? $model.showsLightSettings : $model.showsViewSettings) {
                    if light { EnvironmentPanel(model: model) }
                    else { ViewSettingsPopover(model: model) }
                }
        }
    }
}

struct ViewSettingsPopover: View {
    @ObservedObject var model: NativeViewerModel

    var body: some View {
        let textured = model.look.view == .textured
        GardenPanel { VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("Shading")).foregroundStyle(NeonGarden.text2.color)
                GardenSegments(label: L10n.text("Shading"), options: [(false, L10n.text("Smooth")), (true, L10n.text("Flat"))], selection: $model.look.flat)
            }
            // Why the rest is dimmed.
            if !textured {
                Text(ViewerTips.materialNote).font(GardenTypography.supporting).foregroundStyle(NeonGarden.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L10n.text("Physically based lighting"), isOn: $model.look.pbr).disabled(!textured)
            EnvironmentPanel.row(L10n.text("Metallic"), figure: EnvironmentPanel.percentage(model.look.metallic ?? 0), accessory: {
                Toggle(L10n.text("Override"), isOn: Binding(get: { model.look.metallic != nil }, set: { model.look.metallic = $0 ? 0 : nil }))
                    .toggleStyle(.checkbox).accessibilityLabel(L10n.text("Override metallic")).disabled(!textured)
            }) {
                Slider(value: Binding(get: { model.look.metallic ?? 0 }, set: { model.look.metallic = $0 }), in: 0...1)
                    .accessibilityLabel(L10n.text("Metallic"))
                    .gardenSlider()
                    .disabled(!textured || model.look.metallic == nil)
            }
            EnvironmentPanel.row(L10n.text("Roughness"), figure: EnvironmentPanel.percentage(model.look.roughness ?? 0.5), accessory: {
                Toggle(L10n.text("Override"), isOn: Binding(get: { model.look.roughness != nil }, set: { model.look.roughness = $0 ? 0.5 : nil }))
                    .toggleStyle(.checkbox).accessibilityLabel(L10n.text("Override roughness")).disabled(!textured)
            }) {
                Slider(value: Binding(get: { model.look.roughness ?? 0.5 }, set: { model.look.roughness = $0 }), in: 0...1)
                    .accessibilityLabel(L10n.text("Roughness"))
                    .gardenSlider()
                    .disabled(!textured || model.look.roughness == nil)
            }
        }
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 380) }
    }
}

/// Top right: the gizmo above the viewing controls.
struct SideControls: View {
    @ObservedObject var model: NativeViewerModel
    var toolbarHelp: AnyView? = nil

    var body: some View {
        if model.visibility.controls {
            // The glass shapes that sit together are drawn together; closer than 8 pt they would
            // run into one another, and at rest they are 10 pt apart.
            GlassEffectContainer(spacing: 8) { VStack(alignment: .trailing, spacing: 10) {
                if model.flags.showGizmo { GizmoView(model: model, gizmo: model.gizmo) }
                let f = model.flags
                if f.showFitButton || f.showLightButton || f.showGridButton || f.showRotateButton || toolbarHelp != nil {
                    Pill {
                        let layout = model.compactSideControls
                            ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
                        layout {
                            if f.showFitButton {
                                Button { model.onFit?() } label: { Image(systemName: "viewfinder") }
                                    .gardenButton().help(ViewerTips.fit).accessibilityLabel(L10n.text("Zoom to fit"))
                            }
                            if f.showLightButton {
                                Button { model.showsLightSettings.toggle() } label: { Image(systemName: "sun.max") }
                                    .gardenButton()
                                    .help(ViewerTips.light).accessibilityLabel(L10n.text("Light"))
                                    // Present below the actual button, keeping the gizmo above clear.
                                    .popover(isPresented: $model.showsLightSettings, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                                        EnvironmentPanel(model: model)
                                    }
                            }
                            if f.showGridButton {
                                Toggle(isOn: $model.showGrid) { Image(systemName: "grid") }
                                    .toggleStyle(GardenToggleStyle()).help(ViewerTips.grid).accessibilityLabel(L10n.text("Floor grid"))
                            }
                            if f.showRotateButton {
                                Toggle(isOn: $model.autoRotate) { Image(systemName: "rotate.3d") }
                                    .toggleStyle(GardenToggleStyle()).help(ViewerTips.autoRotate).accessibilityLabel(L10n.text("Auto-rotate"))
                            }
                            toolbarHelp
                        }
                    }
                }
            } }
        }
    }
}

struct GizmoView: View {
    let model: NativeViewerModel
    @ObservedObject var gizmo: GizmoState
    static let size: CGFloat = 100
    private static let reach: CGFloat = 0.66
    /// How near the pointer must be to an end, in the handles' own measure. One unit is
    /// `size / 2 * reach`, 33 pt, so an end is 22 pt across, over the 20 pt minimum for a pointer.
    static let hitRadius: CGFloat = 0.34
    @Environment(\.colorSchemeContrast) private var contrast
    /// Where the pointer is, in the handles' own measure; nil when it is elsewhere.
    @State private var hover: CGPoint?

    /// How large an end is drawn: the nearer the viewer, the larger; a letter's sticker
    /// larger than a far end's ring.
    static func radius(_ handle: GizmoHandle) -> CGFloat {
        let near = CGFloat(max(-1, min(1, handle.depth)))
        return handle.positive ? 10 + 2 * near : 5.5 + 1.2 * near
    }

    @State private var start: CGPoint?
    @State private var last: CGPoint?
    @State private var moved = false

    /// The palette's colour for an axis: X warm, Y green, Z the blue of facts.
    static func tone(_ axis: Character) -> NeonGarden.Tone {
        axis == "X" ? NeonGarden.warm : axis == "Y" ? NeonGarden.success : NeonGarden.info
    }

    var body: some View {
        let handles = ViewGizmo.handles(gizmo.basis)
        let half = Self.size / 2
        let strokes = NeonGarden.strokes(increased: contrast == .increased)
        Canvas { context, _ in
            let middle = CGPoint(x: half, y: half)
            func end(_ h: GizmoHandle) -> CGPoint {
                CGPoint(x: half + h.point.x * half * Self.reach, y: half + h.point.y * half * Self.reach)
            }
            let hot = hover.flatMap { ViewGizmo.hit($0, handles: handles, radius: Self.hitRadius) }
            // What points away is the back half of an axis: a faint dashed line.
            for h in handles where !h.positive {
                var line = Path(); line.move(to: middle); line.addLine(to: end(h))
                context.stroke(line, with: .color(GizmoView.tone(h.axis).color.opacity(strokes.gizmoBackAxis)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
            }
            // The three axes are neon tubes from the middle to their near ends: gas first,
            // adding up to light, then the glass and its line of ink.
            func tubes(_ layer: inout GraphicsContext, width: CGFloat, opacity: Double, ink: Bool = false) {
                for h in handles where h.positive {
                    var line = Path(); line.move(to: middle); line.addLine(to: end(h))
                    let color = ink ? NeonGarden.warmInk.color : GizmoView.tone(h.axis).color
                    layer.stroke(line, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }
            for (blur, opacity) in [(9.0, 0.45), (4.0, 0.6)] {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: blur)); layer.blendMode = .plusLighter
                    tubes(&layer, width: 3, opacity: opacity)
                    for h in handles where h.positive {
                        let c = end(h), r = GizmoView.radius(h)
                        layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(GizmoView.tone(h.axis).color.opacity(opacity)))
                    }
                }
            }
            tubes(&context, width: 2.2, opacity: 0.96)
            tubes(&context, width: 0.7, opacity: 0.85, ink: true)
            // The pin everything turns on.
            context.fill(Path(ellipseIn: CGRect(x: half - 3.2, y: half - 3.2, width: 6.4, height: 6.4)), with: .color(NeonGarden.warmInk.color))
            context.fill(Path(ellipseIn: CGRect(x: half - 1.9, y: half - 2.3, width: 2, height: 2)), with: .color(.white))
            // The ends, farthest first; the nearer an end, the larger it is.
            for h in handles {
                let c = end(h), color = GizmoView.tone(h.axis).color
                let r = GizmoView.radius(h) * (hot == h.preset ? 1.18 : 1)
                let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                if h.positive {
                    // A lit bead with the axis' letter.
                    context.fill(disc, with: .color(color))
                    context.fill(disc, with: .linearGradient(Gradient(colors: [.white.opacity(0.4), .clear]),
                                                             startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r * 0.3)))
                    var letter = context
                    letter.translateBy(x: c.x, y: c.y)
                    letter.draw(Text(String(h.axis)).font(.system(.title3, design: .rounded).weight(.black))
                        .foregroundColor(NeonGarden.background.color), at: .zero)
                } else {
                    // The far end of an axis: a hollow dashed ring, told from the near end by shape.
                    context.fill(disc, with: .color(NeonGarden.surface.color))
                    context.stroke(disc, with: .color(color.opacity(strokes.gizmoFarRing)), style: StrokeStyle(lineWidth: 1.5, dash: [2.6, 2.2]))
                }
                if hot == h.preset {
                    let ring = Path(ellipseIn: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: 2 * r + 6, height: 2 * r + 6))
                    context.stroke(ring, with: .color(NeonGarden.text.color), lineWidth: 1.5)
                }
            }
        }
        .frame(width: Self.size, height: Self.size)
        .liquidGlass(in: Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = CGPoint(x: (p.x - half) / (half * Self.reach), y: (p.y - half) / (half * Self.reach))
            case .ended: hover = nil
            }
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if start == nil { start = value.startLocation; last = value.startLocation; moved = false }
                if hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) > 3 { moved = true }
                if moved, let l = last { model.onGizmoDrag?(value.location.x - l.x, value.location.y - l.y) }
                last = value.location
            }
            .onEnded { value in
                if !moved {
                    let p = CGPoint(x: (value.location.x - half) / (half * Self.reach), y: (value.location.y - half) / (half * Self.reach))
                    if let preset = ViewGizmo.hit(p, handles: handles, radius: Self.hitRadius) { model.onLook?(preset) }
                }
                start = nil; last = nil; moved = false
            })
        .help(L10n.text("Click an axis to look along it; drag to orbit"))
        // The drawing says nothing to VoiceOver: the gizmo is one element whose actions are the six views.
        .accessibilityElement()
        .accessibilityLabel(L10n.text("View direction"))
        .accessibilityAction(named: L10n.text("Front view")) { model.onLook?(.front) }
        .accessibilityAction(named: L10n.text("Back view")) { model.onLook?(.back) }
        .accessibilityAction(named: L10n.text("Left view")) { model.onLook?(.left) }
        .accessibilityAction(named: L10n.text("Right view")) { model.onLook?(.right) }
        .accessibilityAction(named: L10n.text("Top view")) { model.onLook?(.top) }
        .accessibilityAction(named: L10n.text("Bottom view")) { model.onLook?(.bottom) }
    }
}

/// The light: where the model stands, how strong the light is, where it comes from.
struct EnvironmentPanel: View {
    /// As far as the brightness goes: every value a setting may hold can be shown and reached.
    static let brightness = Float(NativeViewerSettings.lightIntensityRange.lowerBound)...Float(NativeViewerSettings.lightIntensityRange.upperBound)
    @ObservedObject var model: NativeViewerModel
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var direction: LightDirection

    init(model: NativeViewerModel) {
        self.model = model
        direction = model.lightDirection
    }

    var body: some View {
        GardenPanel {
            VStack(alignment: .leading, spacing: 10) {
                SurroundingPicture(surrounding: model.surrounding, degrees: direction.degrees)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: NeonGarden.controlRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: NeonGarden.controlRadius, style: .continuous).strokeBorder(NeonGarden.border(increased: contrast == .increased), lineWidth: 1))
                    .accessibilityHidden(true)
                GardenPicker(L10n.text("Mood"), selectedTitle: model.surrounding.title, selection: $model.surrounding) {
                    ForEach(Surrounding.allCases, id: \.self) { Text($0.title).font(GardenTypography.body).tag($0) }
                }
                EnvironmentPanel.row(L10n.text("Brightness"), figure: EnvironmentPanel.percentage(model.lightIntensity)) {
                    Slider(value: $model.lightIntensity, in: EnvironmentPanel.brightness).accessibilityLabel(L10n.text("Brightness")).gardenSlider()
                }
                EnvironmentPanel.row(L10n.text("Direction"), figure: "\(Int(direction.degrees.rounded()))°") {
                    Slider(value: $model.lightRotation, in: 0...360).accessibilityLabel(L10n.text("Direction")).gardenSlider()
                }
                Toggle(EnvironmentPanel.rotateLightLabel, isOn: $model.rotatesLight)
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
        }
    }

    static let rotateLightLabel = L10n.text("Rotate the light automatically")

    /// A share from 0 to 1 as a whole percentage.
    static func percentage(_ share: Float) -> String { "\(Int((share * 100).rounded()))%" }

    /// A name over a slider with its figure beside it, in the colour of facts.
    static func row<Control: View>(_ name: String, figure: String, @ViewBuilder control: () -> Control) -> some View {
        row(name, figure: figure, accessory: { EmptyView() }, control: control)
    }

    /// The same with something at the end of the name's line (a checkbox).
    static func row<Accessory: View, Control: View>(_ name: String, figure: String, @ViewBuilder accessory: () -> Accessory,
                                                    @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).foregroundStyle(NeonGarden.text2.color)
                Spacer(minLength: 8)
                accessory()
            }
            HStack(spacing: 10) {
                control()
                Text(figure).monospacedDigit().foregroundStyle(NeonGarden.info.color).frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// A surrounding as a strip of panorama, turned as its light is.
struct SurroundingPicture: View {
    let surrounding: Surrounding
    let degrees: Float
    static let columns = 72, rows = 24

    var body: some View {
        Canvas { context, size in
            let w = size.width / CGFloat(Self.columns), h = size.height / CGFloat(Self.rows)
            let angle = degrees * .pi / 180
            for y in 0..<Self.rows {
                for x in 0..<Self.columns {
                    let c = surrounding.panorama(u: (Float(x) + 0.5) / Float(Self.columns), v: (Float(y) + 0.5) / Float(Self.rows), turned: angle)
                    context.fill(Path(CGRect(x: CGFloat(x) * w, y: CGFloat(y) * h, width: w + 0.5, height: h + 0.5)),
                                 with: .color(Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))))
                }
            }
        }
    }
}

/// Bottom right: Topology, Faces, Vertices.
struct StatisticsView: View {
    @ObservedObject var model: NativeViewerModel

    var body: some View {
        if model.visibility.stats, model.flags.showStats, let s = model.statistics {
            // Facts to read, not a control: not glass.
            Pill(glass: false) {
                // A receipt: small capital labels, and the facts in their own colour and a
                // typewriter's figures.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow { StatisticsView.label(L10n.text("Topology")); Text(s.topology).gridColumnAlignment(.trailing) }
                    GridRow { StatisticsView.label(L10n.text("Faces")); Text(s.faces, format: .number) }
                    GridRow { StatisticsView.label(L10n.text("Vertices")); Text(s.vertices, format: .number) }
                }
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(NeonGarden.info.color)
                .padding(.horizontal, 6).padding(.vertical, 3)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in model.onLayoutChange?() }
        }
    }
}

/// What to say when a model's separate files (materials, images) were not read.
struct MissingFilesNotice: Equatable {
    var title: String
    var detail: String
    /// The label of the button that asks for the folder; nil where there is none to offer.
    var action: String?

    static let panelPrompt = L10n.text("Allow")
    static func panelMessage(file: String) -> String {
        L10n.format("Choose the folder that holds “%@” and its supporting files. Spacebar 3D needs read-only access.", String(describing: file))
    }

    /// Nil when nothing is missing. `granted` says the folder was open while the model was
    /// read, but the referenced files could still be missing or unreadable; `canGrant` is true where the folder
    /// can be asked for (the app and Quick Look both can). `failed`
    /// says the model itself could not be shown for want of these files: the notice then
    /// speaks of the model, never of textures a model that is not there would have had.
    init?(missing: [String], granted: Bool, canGrant: Bool, failed: Bool = false) {
        var seen = Set<String>()
        let names = missing.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !names.isEmpty else { return nil }
        // A material library names the images; without it they are not known.
        let onlyLibraries = names.allSatisfy { $0.lowercased().hasSuffix(".mtl") }
        let unavailable = failed ? L10n.text("Model unavailable") : onlyLibraries ? L10n.text("Materials unavailable") : L10n.text("Textures unavailable")
        let notShown = failed ? L10n.text("Model not shown") : onlyLibraries ? L10n.text("Materials not shown") : L10n.text("Textures not shown")
        let show = failed ? L10n.text("Show Model…") : onlyLibraries ? L10n.text("Show Materials…") : L10n.text("Show Textures…")
        if granted {
            let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? L10n.format(" and %@ more", String(describing: names.count - 3)) : "")
            title = unavailable
            detail = L10n.format("Could not read: %@.", String(describing: shown))
            action = nil
        } else if canGrant {
            title = notShown
            detail = L10n.text("The model references other files that could not be read.")
            action = show
        } else {
            title = notShown
            detail = L10n.text("The model references other files that cannot be read here.")
            action = nil
        }
    }
}

extension StatisticsView {
    static func label(_ name: String) -> some View {
        Text(name).textCase(.uppercase)
            .font(GardenTypography.supporting.weight(.semibold)).tracking(0.5)
            .foregroundStyle(NeonGarden.text.color.opacity(0.9))
    }
}

/// The notice about files that were not read, in the top left corner.
struct NoticeView: View {
    @ObservedObject var model: NativeViewerModel

    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var actionFocused: Bool

    var body: some View {
        if model.visibility.controls, let notice = model.notice {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(GardenTypography.action)
                    .foregroundStyle(NeonGarden.warm.color)
                    .frame(width: NeonGarden.stickerSize, height: NeonGarden.stickerSize)
                    .background(NeonGarden.warm.color.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: NeonGarden.controlRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(notice.title)
                        .font(GardenTypography.body.weight(.semibold))
                        .foregroundStyle(NeonGarden.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(notice.detail)
                        .accessibilityHint(notice.detail)
                    if let action = notice.action {
                        Button(action) { model.onGrant?() }
                            .buttonStyle(GardenActionButtonStyle())
                            .focusEffectDisabled()
                            .focused($actionFocused)
                            .overlay {
                                if actionFocused {
                                    RoundedRectangle(cornerRadius: NeonGarden.controlRadius)
                                        .strokeBorder(NeonGarden.mint.color, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
            .padding(12)
            .background(NeonGarden.surface.color, in: RoundedRectangle(cornerRadius: NeonGarden.radius))
            .overlay {
                RoundedRectangle(cornerRadius: NeonGarden.radius)
                    .strokeBorder(NeonGarden.border(increased: contrast == .increased))
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: min(360, max(0, model.barAvailableWidth - 104)), alignment: .leading)
        }
    }
}

/// While a file is being read: the app's mark, turning, in the middle of the view.
struct LoadingView: View {
    @ObservedObject var model: NativeViewerModel

    var body: some View {
        if model.loading {
            NeonMark()
                .frame(width: 132, height: 132)
                .padding(NeonMark.margin)
                .transition(.opacity)
                .accessibilityElement()
                .accessibilityLabel(L10n.text("Loading"))
                .allowsHitTesting(false)
        }
    }
}

/// A load error, in the middle of the view.
struct MessageView: View {
    @ObservedObject var model: NativeViewerModel

    var body: some View {
        if let text = model.message {
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(NeonGarden.text2.color)
                // As many lines as it needs: a reason cut short is no reason.
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: 420)
                .allowsHitTesting(false)
        }
    }
}
