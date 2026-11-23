import SwiftUI

/// Shared text sizes for app windows and viewer overlays.
public enum GardenTypography {
    public static let body = Font.title2
    public static let supporting = Font.title3
    public static let action = Font.title2.weight(.medium)
    public static let heading = Font.title.weight(.semibold)
    public static let title = Font.largeTitle.weight(.bold)
    public static let monospaced = Font.system(.title3, design: .monospaced)
}

/// Text buttons whose labels keep their requested size instead of using AppKit's
/// small default control font. SwiftUI retains keyboard activation and focus rings.
public struct GardenActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GardenTypography.action)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .foregroundStyle(enabled ? NeonGarden.mint.color : NeonGarden.text3.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? NeonGarden.surface3.color : NeonGarden.surface.color,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(NeonGarden.border(increased: contrast == .increased), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}


/// A selection menu with a SwiftUI label so macOS does not substitute the small
/// native popup-button font. The inline picker keeps selection checkmarks and actions.
public struct GardenPicker<Selection: Hashable, Options: View>: View {
    let title: String
    let selectedTitle: String
    @Binding var selection: Selection
    let showsLabel: Bool
    let options: Options

    public init(_ title: String, selectedTitle: String, selection: Binding<Selection>,
                showsLabel: Bool = true, @ViewBuilder content: () -> Options) {
        self.title = title
        self.selectedTitle = selectedTitle
        _selection = selection
        self.showsLabel = showsLabel
        options = content()
    }

    public var body: some View {
        HStack {
            if showsLabel { Text(title); Spacer(minLength: 12) }
            Menu {
                Picker(title, selection: $selection) { options.font(GardenTypography.body) }
                    .font(GardenTypography.body)
                    .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text(selectedTitle).font(GardenTypography.body)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(GardenTypography.supporting)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(title)
            .accessibilityValue(selectedTitle)
        }
        .font(GardenTypography.body)
    }
}

/// The viewer's look: Neon Garden, the dark botanical system of Astrina. Near-black greens,
/// mint for what is chosen or on, a pale blue for facts and figures, and one chartreuse
/// "Signal" for the single action a screen exists for. Dark only, whatever the system's
/// appearance: the canvas is a dark room and the controls are tools on its bench.
public enum NeonGarden {
    /// A colour of the palette, kept as numbers so that the renderer can use it too.
    public struct Tone: Equatable, Sendable {
        public let red: Double, green: Double, blue: Double

        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xff) / 255
            green = Double((hex >> 8) & 0xff) / 255
            blue = Double(hex & 0xff) / 255
        }

        public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
        /// "#rrggbb", as the settings write colours.
        public var hex: String { String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())) }

        /// How bright the eye takes it to be, 0...1 (WCAG relative luminance).
        public var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        /// Contrast against another colour, 1...21.
        public func contrast(with other: Tone) -> Double {
            let a = max(luminance, other.luminance), b = min(luminance, other.luminance)
            return (a + 0.05) / (b + 0.05)
        }
    }

    // Surfaces
    public static let background = Tone(0x07110C)
    public static let surface = Tone(0x0E1C14)
    public static let surface2 = Tone(0x13251B)
    public static let surface3 = Tone(0x1A3024)
    // Text
    public static let text = Tone(0xF1F4F0)
    public static let text2 = Tone(0xAEB9B0)
    public static let text3 = Tone(0x8A978D)
    public static let borderStrong = Tone(0x6B776F)
    // Accents
    /// The one primary action of a screen; never text, a border or decoration.
    public static let signal = Tone(0xCFFF2E)
    public static let signalPressed = Tone(0xA6E800)
    public static let warm = Tone(0xFF6A3D)
    public static let warmInk = Tone(0xF7EFE8)
    /// Chosen, on, playing.
    public static let mint = Tone(0xA6E3A7)
    public static let mint2 = Tone(0x84BD6B)
    /// Rare and playful: tape.
    public static let warm2 = Tone(0xFF3D89)
    /// Facts and figures.
    public static let info = Tone(0xB8D3FF)
    public static let success = Tone(0x2DE08F)
    public static let danger = Tone(0xFF3D3D)

    /// The strengths (opacities, and one width) of what the controls draw, as a pure value:
    /// the usual set, and the stronger one for Increase Contrast.
    struct Strokes: Equatable {
        /// The picture of a control at rest.
        var restGlyph: Double
        /// The edge of a control that is on: its strength and its width.
        var onEdge: Double
        var onEdgeWidth: CGFloat
        /// The dashed edge of a control that cannot be used.
        var disabledEdge: Double
        /// A panel's edge, along its top and along its bottom.
        var panelEdgeTop: Double
        var panelEdgeBottom: Double
        /// Decorative lines.
        var border: Double
        /// The gizmo's far rings and its dashed back axes.
        var gizmoFarRing: Double
        var gizmoBackAxis: Double
        /// How much of the surface colour the glass is darkened with.
        var glassTint: Double
    }

    /// The usual strengths, or the stronger ones when the system asks for more contrast.
    static func strokes(increased: Bool) -> Strokes {
        increased
            ? Strokes(restGlyph: 1, onEdge: 1, onEdgeWidth: 1.5, disabledEdge: 1, panelEdgeTop: 0.5, panelEdgeBottom: 0.5,
                      border: 0.5, gizmoFarRing: 1, gizmoBackAxis: 1, glassTint: 0.7)
            : Strokes(restGlyph: 0.86, onEdge: 0.45, onEdgeWidth: 1, disabledEdge: 0.5, panelEdgeTop: 0.34, panelEdgeBottom: 0.10,
                      border: 0.22, gizmoFarRing: 0.9, gizmoBackAxis: 0.4, glassTint: 0.4)
    }

    /// Decorative edges: the text colour at 22%, at 50% with Increase Contrast.
    public static var border: Color { border(increased: false) }
    public static func border(increased: Bool) -> Color { text.color.opacity(strokes(increased: increased).border) }
    /// The edge of a panel, lit from above: brighter along the top than along the bottom.
    /// With Increase Contrast it is one even line of text at 50%.
    static var edge: LinearGradient { edge(increased: false) }
    static func edge(increased: Bool) -> LinearGradient {
        let s = strokes(increased: increased)
        return LinearGradient(colors: [text.color.opacity(s.panelEdgeTop), text.color.opacity(s.panelEdgeBottom)], startPoint: .top, endPoint: .bottom)
    }

    // Motion
    /// A press goes in at once.
    static let press: Animation = .easeOut(duration: 0.12)
    /// A light comes on, a choice moves over.
    static let turn: Animation = .snappy(duration: 0.28)
    /// A panel comes in.
    static let arrive: Animation = .easeOut(duration: 0.4)
    /// The Signal breathes.
    static let breathe: Animation = .easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    public static let radius: CGFloat = 12
    public static let controlRadius: CGFloat = 8
    public static let controlHeight: CGFloat = 28
    /// What the controls' glass is darkened with.
    static var glassTint: Color { glassTint(increased: false) }
    static func glassTint(increased: Bool) -> Color { surface.color.opacity(strokes(increased: increased).glassTint) }
    /// A panel of controls is as round as a control in it.
    public static let panelRadius: CGFloat = 24
    /// A sticker's height, and its width round a single picture.
    public static let stickerSize: CGFloat = 32
}

/// A panel of controls floating over the canvas: Liquid Glass, darkened with the palette's surface.
struct Pill<Content: View>: View {
    /// False for a panel that only shows facts: it is content, not a control, and glass
    /// is kept for controls.
    var glass = true
    @ViewBuilder var content: Content
    var body: some View {
        // Glass: a tool is kept plain, so that what it shows is not.
        let shape = RoundedRectangle(cornerRadius: NeonGarden.panelRadius, style: .continuous)
        if glass {
            content
                .padding(8)
                .neonGarden()
                .liquidGlass(in: shape)
                .modifier(Arrival())
        } else {
            content
                .padding(8)
                .neonGarden()
                .modifier(FlatPanel(shape: shape))
                .modifier(Arrival())
        }
    }
}

extension View {
    /// The system's Liquid Glass behind the view, in the given shape: it bends and blurs the
    /// model behind it and takes its light. Tinted with the palette's surface, so that
    /// the controls keep their contrast over a bright model.
    func liquidGlass(in shape: some InsettableShape) -> some View { modifier(LiquidGlass(shape: shape)) }
}

/// The palette's surface at 72% with its thin edge and a shadow, and no glass: what shows
/// facts rather than offering controls.
struct FlatPanel<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    /// How much of the surface colour the panel is made of.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    static func surfaceOpacity(reduceTransparency: Bool) -> Double { reduceTransparency ? 1 : 0.72 }

    func body(content: Content) -> some View {
        content
            .background(NeonGarden.surface.color.opacity(Self.surfaceOpacity(reduceTransparency: reduceTransparency)), in: shape)
            .overlay(shape.strokeBorder(NeonGarden.edge(increased: contrast == .increased), lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            .environment(\.colorScheme, .dark)
    }
}

extension EnvironmentValues {
    /// Set where the system's glass cannot be drawn (a picture made off the screen, as
    /// tests make): the panels are then solid, whatever the Mac's transparency setting.
    @Entry var glassIsOff = false
}

struct LiquidGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.glassIsOff) private var glassOff
    @Environment(\.colorSchemeContrast) private var contrast

    /// With Reduce Transparency on the system draws its glass as a flat grey: the panel is
    /// then the palette's own surface with its thin edge, as it was before there was glass.
    static func isSolid(reduceTransparency: Bool, glassOff: Bool = false) -> Bool { reduceTransparency || glassOff }

    func body(content: Content) -> some View {
        Group {
            if Self.isSolid(reduceTransparency: solid, glassOff: glassOff) {
                content
                    .background(NeonGarden.surface.color, in: shape)
                    .overlay(shape.strokeBorder(NeonGarden.edge(increased: contrast == .increased), lineWidth: 1).allowsHitTesting(false))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            } else {
                content.glassEffect(.regular.tint(NeonGarden.glassTint(increased: contrast == .increased)), in: shape)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// How a panel comes in when there is a model to show: it rises a little out of the dark.
/// Still, with Reduce Motion on.
struct Arrival: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var here = false

    func body(content: Content) -> some View {
        content
            .opacity(here ? 1 : 0)
            .offset(y: here || still ? 0 : 10)
            .blur(radius: here || still ? 0 : 6)
            .onAppear { withAnimation(still ? nil : NeonGarden.arrive) { here = true } }
    }
}

extension Shape {
    /// A neon tube along the shape: four blurred strokes of gas that add up to light, the
    /// lit glass, and a warm line of ink inside it. `lineWidth` is the gauge of the glass;
    /// the gas reaches `spread` times it.
    func neonTube(_ tone: NeonGarden.Tone, lineWidth: CGFloat, intensity: Double = 1, spread: CGFloat = 10) -> some View {
        let glow = min(max(intensity, 0), 1), color = tone.color
        let cap = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        return ZStack {
            stroke(color.opacity(0.22 * glow), style: cap).blur(radius: lineWidth * spread).blendMode(.plusLighter)
            stroke(color.opacity(0.34 * glow), style: cap).blur(radius: lineWidth * spread * 0.57).blendMode(.plusLighter)
            stroke(color.opacity(0.42 * glow), style: cap).blur(radius: lineWidth * spread * 0.32).blendMode(.plusLighter)
            stroke(color.opacity(0.55 * glow), style: cap).blur(radius: lineWidth * spread * 0.14)
            stroke(color.opacity(0.96), style: cap)
            stroke(NeonGarden.warmInk.color.opacity(0.9 * glow),
                   style: StrokeStyle(lineWidth: max(0.4, lineWidth * 0.3), lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// A button of the palette that acts at once. The keyboard's ring is the system's.
    public func gardenButton() -> some View { buttonStyle(GardenButtonStyle()) }
    /// The one Signal of a screen.
    public func signalButton() -> some View { buttonStyle(SignalButtonStyle()) }

    /// Dark, mint-tinted, in the palette's text colour: what every piece of the viewer's
    /// chrome starts from.
    public func neonGarden() -> some View {
        environment(\.colorScheme, .dark)
            .font(GardenTypography.body)
            .tint(NeonGarden.mint.color)
            .foregroundStyle(NeonGarden.text.color)
    }
}

/// The face of a small control: a quiet tile that turns mint when it is on. Off and on
/// differ by fill, edge and the colour of the glyph; a control that cannot be used keeps
/// its shape with a dashed edge.
private struct ControlFace: View {
    let on: Bool
    let pressed: Bool
    let label: AnyView
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    var body: some View {
        let strokes = NeonGarden.strokes(increased: contrast == .increased)
        // A disc round a picture, a pill round a word. At rest it is only its picture; one
        // that is on sits in a dark well with its picture lit in mint.
        let shape = Capsule(style: .continuous)
        let fill: Color = on ? NeonGarden.background.color.opacity(0.62)
            : (pressed || hovered) && enabled ? NeonGarden.surface3.color : .clear
        label
            .font(GardenTypography.action.weight(on ? .semibold : .regular))
            .foregroundStyle(!enabled ? NeonGarden.text3.color.opacity(0.55) : on ? NeonGarden.mint.color : hovered ? NeonGarden.text.color : NeonGarden.text.color.opacity(strokes.restGlyph))
            .shadow(color: NeonGarden.mint.color.opacity(on ? 0.9 : 0), radius: 6)
            .frame(minWidth: 18, minHeight: NeonGarden.stickerSize)
            .padding(.horizontal, 7)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(NeonGarden.mint.color.opacity(on ? strokes.onEdge : 0), lineWidth: strokes.onEdgeWidth))
            // Not to be had just now: a dashed edge says so in shape as well as in colour.
            .overlay(shape.strokeBorder(NeonGarden.text3.color.opacity(enabled ? 0 : strokes.disabledEdge), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .scaleEffect(pressed && !still ? 0.9 : 1)
            .animation(still ? nil : NeonGarden.press, value: pressed)
            .animation(still ? nil : NeonGarden.turn, value: on)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }
}

/// A button that does something at once (fit the view, open a panel).
public struct GardenButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ControlFace(on: false, pressed: configuration.isPressed, label: AnyView(configuration.label))
    }
}

/// A switch drawn as a button: mint while it is on.
struct GardenToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(Face(on: configuration.isOn))
            // To assistive technology this is a switch with an on and an off, not a button.
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }

    private struct Face: ButtonStyle {
        let on: Bool
        func makeBody(configuration: Configuration) -> some View {
            ControlFace(on: on, pressed: configuration.isPressed, label: AnyView(configuration.label))
        }
    }
}

/// The one action a screen exists for: chartreuse, with a warm ink line inside its edge.
public struct SignalButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SignalFace(pressed: configuration.isPressed, label: AnyView(configuration.label))
    }
}

/// The Signal: a sign of lit glass in a dark room. Its light breathes slowly, so that the
/// eye finds it; with Reduce Motion on it is steady.
private struct SignalFace: View {
    let pressed: Bool
    let label: AnyView
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var bright = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NeonGarden.controlRadius, style: .continuous)
        label
            .font(GardenTypography.action.weight(.heavy))
            .foregroundStyle(NeonGarden.background.color)
            .padding(.horizontal, 16)
            .frame(minHeight: NeonGarden.controlHeight + 4)
            .background((pressed ? NeonGarden.signalPressed : NeonGarden.signal).color.opacity(enabled ? 1 : 0.4), in: shape)
            .overlay(shape.inset(by: 2.5).strokeBorder(NeonGarden.warmInk.color.opacity(0.55), lineWidth: 1))
            .background(shape.neonTube(NeonGarden.signal, lineWidth: 2, intensity: enabled ? (still ? 0.8 : bright ? 1 : 0.55) : 0, spread: 8))
            .scaleEffect(pressed && !still ? 0.96 : 1)
            .animation(still ? nil : NeonGarden.press, value: pressed)
            .contentShape(shape)
            .onAppear { if !still { withAnimation(NeonGarden.breathe) { bright = true } } }
    }
}

/// One choice among a few, side by side. The chosen one is lifted, bold, and underlined in
/// mint, so that it is told by more than its fill.
struct GardenSegments<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var disabledOption: Value? = nil
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.title) { selection = option.value }
                    .buttonStyle(Segment(chosen: option.value == selection))
                    .disabled(option.value == disabledOption)
                    .opacity(option.value == disabledOption ? 0.5 : 1)
                    // The mark of the chosen one is one thing, which moves over to the next.
                    .background {
                        if option.value == selection { Chosen().matchedGeometryEffect(id: "chosen", in: space) }
                    }
            }
        }
        .animation(still ? nil : NeonGarden.turn, value: selection)
        // To assistive technology these are one segmented control, not a row of buttons.
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.title).tag(option.value).disabled(option.value == disabledOption)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private struct Segment: ButtonStyle {
        let chosen: Bool
        @State private var hovered = false
        @Environment(\.colorSchemeContrast) private var contrast

        func makeBody(configuration: Configuration) -> some View {
            let shape = Capsule(style: .continuous)
            configuration.label
                .font(GardenTypography.body.weight(chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? NeonGarden.mint.color : hovered ? NeonGarden.text.color : NeonGarden.text.color.opacity(NeonGarden.strokes(increased: contrast == .increased).restGlyph))
                .padding(.horizontal, 13)
                .frame(minHeight: NeonGarden.stickerSize)
                .background(!chosen && configuration.isPressed ? NeonGarden.surface3.color.opacity(0.6) : .clear, in: shape)
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}

/// What marks the chosen segment: a dark well, which slides over to the next choice. Its
/// word is lit in mint.
private struct Chosen: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let strokes = NeonGarden.strokes(increased: contrast == .increased)
        Capsule(style: .continuous).fill(NeonGarden.background.color.opacity(0.62))
            .overlay(Capsule(style: .continuous).strokeBorder(NeonGarden.mint.color.opacity(strokes.onEdge), lineWidth: strokes.onEdgeWidth))
    }
}

/// A slider of the system's in the palette: its focus ring is the system's.
struct GardenSliderFocus: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 2)
    }
}

extension View {
    func gardenSlider() -> some View { modifier(GardenSliderFocus()) }
}

/// The inside of a popover: the system's glass, darkened with the palette's surface; the
/// palette's solid surface when the system is asked for less transparency.
struct GardenPanel<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.glassIsOff) private var glassOff
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if LiquidGlass<Rectangle>.isSolid(reduceTransparency: solid, glassOff: glassOff) {
                content
                    .padding(14)
                    .background(NeonGarden.surface.color)
                    .presentationBackground(NeonGarden.surface.color)
            } else {
                content
                    .padding(14)
                    .presentationBackground(NeonGarden.glassTint(increased: contrast == .increased))
            }
        }
        .neonGarden()
        .environment(\.colorScheme, .dark)
    }
}
