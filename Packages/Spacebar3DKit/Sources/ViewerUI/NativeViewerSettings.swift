import Foundation
import ModelCore
import RenderMetal
import simd

/// The looks a user can pick as the default (the settings' `defaultShading` values).
public enum DefaultLook: String, CaseIterable, Sendable {
    case original, wireframe, clay, normals, unlit, anime, celShaded, retro, voxel, hologram

    /// The look as `lookToState` gives it (the viewer shows Solid for a model with no
    /// Textured view; a style stays on over it).
    public var look: RenderLook {
        switch self {
        case .wireframe: return RenderLook(view: .textured, wire: true)
        case .clay: return RenderLook(view: .solid)
        case .normals: return RenderLook(view: .normal)
        case .unlit: return RenderLook(view: .textured, style: .unlit)
        case .retro: return RenderLook(view: .textured, style: .retro)
        case .voxel: return RenderLook(view: .textured, style: .voxel)
        case .celShaded: return RenderLook(view: .textured, style: .celShaded)
        case .anime: return RenderLook(view: .textured, style: .anime)
        case .hologram: return RenderLook(view: .textured, style: .hologram)
        case .original: return RenderLook(view: .textured)
        }
    }
}

/// The user's viewer settings, as the hosts read them from the settings file.
public struct NativeViewerSettings: Equatable, Sendable {
    public var defaultLook: DefaultLook
    /// "#rrggbb"; anything else falls back to the default colour.
    public var backgroundColor: String
    public var solidColor: String
    public var lightIntensity: Double
    public var showGrid: Bool
    public var autoRotate: Bool
    public var showShadingButton: Bool
    public var showFitButton: Bool
    public var showLightButton: Bool
    public var showGridButton: Bool
    public var showRotateButton: Bool
    public var showGizmo: Bool
    public var showStats: Bool
    /// Whether a model's animation starts playing when it opens.
    public var autoplay: Bool
    public var showAnimationBar: Bool
    /// Whether an animation starts over when it ends; the player's Repeat switch starts from this.
    public var repeatAnimations: Bool

    /// The darkest green of the palette: the room the model stands in.
    public static let defaultBackground = NeonGarden.background.hex
    public static let defaultSolid = "#b4b4b8"
    public static let lightIntensityRange: ClosedRange<Double> = 0.1...3.0

    public init(defaultLook: DefaultLook = .original, backgroundColor: String = defaultBackground,
                solidColor: String = defaultSolid, lightIntensity: Double = 1,
                showGrid: Bool = true, autoRotate: Bool = false,
                showShadingButton: Bool = true, showFitButton: Bool = true, showLightButton: Bool = true,
                showGridButton: Bool = true, showRotateButton: Bool = true,
                showGizmo: Bool = true, showStats: Bool = true, autoplay: Bool = true, showAnimationBar: Bool = true,
                repeatAnimations: Bool = false) {
        self.defaultLook = defaultLook; self.backgroundColor = backgroundColor; self.solidColor = solidColor
        self.lightIntensity = lightIntensity; self.showGrid = showGrid; self.autoRotate = autoRotate
        self.showShadingButton = showShadingButton; self.showFitButton = showFitButton
        self.showLightButton = showLightButton; self.showGridButton = showGridButton
        self.showRotateButton = showRotateButton; self.showGizmo = showGizmo; self.showStats = showStats
        self.autoplay = autoplay; self.showAnimationBar = showAnimationBar
        self.repeatAnimations = repeatAnimations
    }

    /// "#rrggbb" to sRGB components in 0...1, or nil.
    public static func parseHex(_ string: String) -> SIMD3<Float>? {
        let bytes = Array(string.utf8)
        guard bytes.count == 7, bytes[0] == 0x23 else { return nil }
        guard let value = UInt32(String(string.dropFirst()), radix: 16) else { return nil }
        return SIMD3(Float((value >> 16) & 0xff), Float((value >> 8) & 0xff), Float(value & 0xff)) / 255
    }

    /// The state the viewer opens (and resets) to.
    public func initialState() -> NativeViewerState { NativeViewerState(self) }
}

/// Everything the viewer starts from, resolved from the settings.
public struct NativeViewerState: Equatable, Sendable {
    public var look: RenderLook
    public var lightIntensity: Float
    /// sRGB.
    public var backgroundColor: SIMD3<Float>
    public var solidColor: SIMD3<Float>
    public var showGrid: Bool
    public var autoRotate: Bool
    public var showViewsBar: Bool
    public var showFitButton: Bool
    public var showLightButton: Bool
    public var showGridButton: Bool
    public var showRotateButton: Bool
    public var showGizmo: Bool
    public var showStats: Bool
    public var autoplay: Bool
    public var showAnimationBar: Bool
    public var repeatAnimations: Bool

    public init(_ s: NativeViewerSettings) {
        look = s.defaultLook.look
        let light = s.lightIntensity.isFinite ? s.lightIntensity : 1
        lightIntensity = Float(min(NativeViewerSettings.lightIntensityRange.upperBound,
                                   max(NativeViewerSettings.lightIntensityRange.lowerBound, light)))
        backgroundColor = NativeViewerSettings.parseHex(s.backgroundColor) ?? NativeViewerSettings.parseHex(NativeViewerSettings.defaultBackground)!
        solidColor = NativeViewerSettings.parseHex(s.solidColor) ?? NativeViewerSettings.parseHex(NativeViewerSettings.defaultSolid)!
        showGrid = s.showGrid; autoRotate = s.autoRotate
        showViewsBar = s.showShadingButton; showFitButton = s.showFitButton; showLightButton = s.showLightButton
        showGridButton = s.showGridButton; showRotateButton = s.showRotateButton
        showGizmo = s.showGizmo; showStats = s.showStats
        autoplay = s.autoplay; showAnimationBar = s.showAnimationBar
        repeatAnimations = s.repeatAnimations
    }
}

/// The statistics rows: what the file's author made, not what the GPU draws.
public struct NativeViewerStatistics: Equatable, Sendable {
    public var topology: String
    public var faces: Int
    public var vertices: Int

    public init(topology: String, faces: Int, vertices: Int) { self.topology = topology; self.faces = faces; self.vertices = vertices }

    public init(_ t: SourceTopology) { topology = t.label; faces = t.faces; vertices = t.vertices }
}

/// Which overlays fit a preview of the given size (small Quick Look previews show the
/// model only; the statistics need more room).
struct ControlsVisibility: Equatable {
    var controls: Bool
    var stats: Bool

    init(controls: Bool, stats: Bool) { self.controls = controls; self.stats = stats }

    /// How far the controls stand from the edge of the view.
    static let edge: CGFloat = 16

    init(size: CGSize) {
        controls = size.width >= 480 && size.height >= 340
        stats = controls && size.width >= 560
    }

    /// The bottom bars share a center so the statistics can clear both of them.
    struct BottomRow: Equatable {
        var statisticsFoot: CGFloat
        var barShift: CGFloat
        var animationFoot: CGFloat
    }

    static func bottomRow(width: CGFloat, bar: CGSize, animation: CGSize = .zero, statistics: CGFloat) -> BottomRow {
        let gap: CGFloat = 8
        let viewHeight = bar.width > 0 ? bar.height : 0
        let animationHeight = animation.width > 0 ? animation.height : 0
        let animationFoot = edge + (viewHeight > 0 ? viewHeight + gap : 0)
        let widest = max(bar.width, animation.width)
        let room = (width - widest) / 2 - edge - gap
        let missing = statistics > 0 ? max(0, statistics - room) : 0
        let left = (width - widest) / 2 - missing
        let shift = left >= edge ? missing : 0
        let stacked = widest > 0 && missing > 0 && left < edge
        let topOfBars = edge + viewHeight + (viewHeight > 0 && animationHeight > 0 ? gap : 0) + animationHeight
        return BottomRow(statisticsFoot: stacked ? topOfBars + gap : edge,
                         barShift: shift, animationFoot: animationFoot)
    }

}
