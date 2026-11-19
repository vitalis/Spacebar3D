import ModelCore
import AppKit
import RenderMetal

/// What a viewer can be told to do from outside its own controls: the app's menus and
/// their keyboard shortcuts. Each has the name it goes by in a menu.
public enum ViewerCommand: String, CaseIterable, Sendable {
    case solid, textured, normal
    case wireframe
    case unlit, anime, celShaded, retro, voxel, hologram
    case fit, zoomIn, zoomOut
    case front, back, left, right, top, bottom
    case orbitLeft, orbitRight, orbitUp, orbitDown
    case panLeft, panRight, panUp, panDown
    case grid, autoRotate
    case playPause
    /// The shading of the surface, and the loop of the animation.
    case smoothShading, flatShading, repeatClip
    /// The light's mood (see `Surrounding`).
    case moodGlasshouse, moodDawn, moodNoon, moodGoldenHour, moodOvercast, moodMoonlit, moodNeon
    /// Open the canvas's two popovers, and ask for the folder of the model's textures.
    case showViewSettings, showLightSettings, showTextures

    /// Title-style capitals, as a menu item is written.
    public var title: String {
        switch self {
        case .solid: return L10n.text("Solid")
        case .textured: return L10n.text("Textured")
        case .normal: return L10n.text("Normal")
        case .wireframe: return L10n.text("Wireframe")
        case .unlit: return L10n.text("Unshaded")
        case .anime: return L10n.text("Anime")
        case .retro: return L10n.text("Retro")
        case .voxel: return L10n.text("Voxel Art")
        case .celShaded: return L10n.text("Cel-Shaded")
        case .hologram: return L10n.text("Hologram")
        case .fit: return L10n.text("Zoom to Fit")
        case .zoomIn: return L10n.text("Zoom In")
        case .zoomOut: return L10n.text("Zoom Out")
        case .front: return L10n.text("Front")
        case .back: return L10n.text("Back")
        case .left: return L10n.text("Left")
        case .right: return L10n.text("Right")
        case .top: return L10n.text("Top")
        case .bottom: return L10n.text("Bottom")
        case .orbitLeft: return L10n.text("Orbit Left")
        case .orbitRight: return L10n.text("Orbit Right")
        case .orbitUp: return L10n.text("Orbit Up")
        case .orbitDown: return L10n.text("Orbit Down")
        case .panLeft: return L10n.text("Pan Left")
        case .panRight: return L10n.text("Pan Right")
        case .panUp: return L10n.text("Pan Up")
        case .panDown: return L10n.text("Pan Down")
        case .grid: return L10n.text("Floor Grid")
        case .autoRotate: return L10n.text("Auto-Rotate")
        // The menu shows "Pause" while it plays: see `title(on:)`.
        case .playPause: return L10n.text("Play")
        case .smoothShading: return L10n.text("Smooth Shading")
        case .flatShading: return L10n.text("Flat Shading")
        case .repeatClip: return L10n.text("Repeat")
        case .showViewSettings: return L10n.text("View Settings…")
        case .showLightSettings: return L10n.text("Light Settings…")
        case .showTextures: return L10n.text("Show Textures…")
        default:
            // A mood is named as the light panel names it.
            return ViewerCommand.moods[self]?.title ?? rawValue
        }
    }

    /// The title for the command's present state: Play becomes Pause while it plays.
    public func title(on: Bool) -> String { self == .playPause && on ? L10n.text("Pause") : title }

    /// Whether the item shows a tick: it is a state that is on or off, not an act.
    public var isState: Bool {
        switch self {
        case .solid, .textured, .normal, .wireframe, .unlit, .anime, .celShaded, .retro, .voxel, .hologram, .grid, .autoRotate,
             .smoothShading, .flatShading, .repeatClip: return true
        default: return ViewerCommand.moods[self] != nil
        }
    }

    static let views: [ViewerCommand: RenderLook.View] = [.solid: .solid, .textured: .textured, .normal: .normal]
    static let styles: [ViewerCommand: RenderLook.Style] = [.unlit: .unlit, .anime: .anime, .celShaded: .celShaded, .retro: .retro, .voxel: .voxel, .hologram: .hologram]
    public static let moods: [ViewerCommand: Surrounding] = [
        .moodGlasshouse: .glasshouse, .moodDawn: .dawn, .moodNoon: .noon, .moodGoldenHour: .goldenHour,
        .moodOvercast: .overcast, .moodMoonlit: .moonlit, .moodNeon: .neon,
    ]
    static let presets: [ViewerCommand: ViewPreset] = [.front: .front, .back: .back, .left: .left, .right: .right, .top: .top, .bottom: .bottom]
    /// One press of an arrow turns the view by a twelfth of its height's worth of dragging.
    static let orbitStep: CGFloat = 1.0 / 12
    static let zoomStep: Float = 0.8
}

/// How a command stands just now.
public struct ViewerCommandStatus: Equatable, Sendable {
    /// Whether it can be chosen.
    public var enabled: Bool
    /// Whether its state is on (always false for an act).
    public var on: Bool
    public init(enabled: Bool, on: Bool = false) { self.enabled = enabled; self.on = on }
}

extension NativeViewerModel {
    /// What the controls on the canvas would say about a command: the same rules, so a
    /// menu can never do what a button cannot.
    func status(of command: ViewerCommand) -> ViewerCommandStatus {
        // Asking for the folder is for a model whose files were not read, shown or not.
        if command == .showTextures { return ViewerCommandStatus(enabled: notice?.action != nil) }
        // Nothing to act on until a model is shown.
        guard statistics != nil else { return ViewerCommandStatus(enabled: false) }
        if let view = ViewerCommand.views[command] {
            return ViewerCommandStatus(enabled: view != .textured || hasTextured, on: look.view == view)
        }
        if let style = ViewerCommand.styles[command] {
            let needsTexture = StyleButton.all.first { $0.style == style }?.needsTexture ?? false
            return ViewerCommandStatus(enabled: !needsTexture || hasTextured, on: look.style == style)
        }
        if let mood = ViewerCommand.moods[command] { return ViewerCommandStatus(enabled: true, on: surrounding == mood) }
        switch command {
        case .wireframe: return ViewerCommandStatus(enabled: true, on: look.wire)
        case .grid: return ViewerCommandStatus(enabled: true, on: showGrid)
        case .autoRotate: return ViewerCommandStatus(enabled: true, on: autoRotate)
        case .playPause: return ViewerCommandStatus(enabled: !clipNames.isEmpty, on: playing)
        case .repeatClip: return ViewerCommandStatus(enabled: !clipNames.isEmpty, on: repeats)
        case .smoothShading: return ViewerCommandStatus(enabled: true, on: !look.flat)
        case .flatShading: return ViewerCommandStatus(enabled: true, on: look.flat)
        // Persistent anchors allow settings from menus at every supported window size.
        case .showViewSettings, .showLightSettings: return ViewerCommandStatus(enabled: true)
        default: return ViewerCommandStatus(enabled: true)
        }
    }

    /// Does what the control on the canvas does. Returns false for a command that moves
    /// the camera, which the model does not hold.
    func perform(_ command: ViewerCommand) -> Bool {
        guard status(of: command).enabled else { return true }
        if let mood = ViewerCommand.moods[command] { surrounding = mood; return true }
        if let view = ViewerCommand.views[command] { look = look.selecting(view: view); return true }
        if let style = ViewerCommand.styles[command] { look = look.toggling(style: style, textured: hasTextured); return true }
        switch command {
        case .wireframe: look = look.togglingWire()
        case .grid: showGrid.toggle()
        case .autoRotate: autoRotate.toggle()
        case .playPause: playing.toggle()
        case .repeatClip: repeats.toggle()
        case .smoothShading: look.flat = false
        case .flatShading: look.flat = true
        case .showViewSettings: showsViewSettings = true
        case .showLightSettings: showsLightSettings = true
        case .showTextures: onGrant?()
        case .fit: onFit?()
        default:
            if let preset = ViewerCommand.presets[command] { onLook?(preset); return true }
            return false
        }
        return true
    }
}
