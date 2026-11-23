import SwiftUI

// The hand in the look: things that seem made and stuck down rather than generated. A
// frame of neon cord that wanders a little, tape, squared paper with gaps in its lines. All of it decoration: none of it takes a click or says anything to
// VoiceOver.

/// A rounded rectangle whose sides wander in and out like cord laid down by hand. Each side
/// holds a whole number of waves, so the corners are met smoothly.
public struct WavyFrame: InsettableShape {
    var radius: CGFloat = 18
    var amplitude: CGFloat = 2
    var wavelength: CGFloat = 46
    /// Where along its wave the cord starts, in turns: two rails with different phases do
    /// not run parallel.
    var phase: CGFloat = 0
    var inset: CGFloat = 0

    public init(radius: CGFloat = 18, amplitude: CGFloat = 2, wavelength: CGFloat = 46, phase: CGFloat = 0) {
        self.radius = radius; self.amplitude = amplitude; self.wavelength = wavelength; self.phase = phase
    }

    public func inset(by amount: CGFloat) -> WavyFrame { var copy = self; copy.inset += amount; return copy }

    public func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        guard box.width > 4, box.height > 4 else { return Path() }
        let r = max(0, min(radius - inset, box.width / 2, box.height / 2))
        var path = Path()
        // A side from `a` to `b`, pushed out along `normal` by the wave.
        func side(_ a: CGPoint, _ b: CGPoint, _ normal: CGVector, first: Bool) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let waves = max(1, (length / max(wavelength, 1)).rounded())
            let steps = max(2, Int(length / 3))
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                // Fades to nothing at both ends, whatever the phase.
                let lift = amplitude * sin((t * waves + phase) * 2 * .pi) * sin(t * .pi)
                let p = CGPoint(x: a.x + (b.x - a.x) * t + normal.dx * lift, y: a.y + (b.y - a.y) * t + normal.dy * lift)
                if first && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        side(CGPoint(x: box.minX + r, y: box.minY), CGPoint(x: box.maxX - r, y: box.minY), CGVector(dx: 0, dy: -1), first: true)
        path.addArc(center: CGPoint(x: box.maxX - r, y: box.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        side(CGPoint(x: box.maxX, y: box.minY + r), CGPoint(x: box.maxX, y: box.maxY - r), CGVector(dx: 1, dy: 0), first: false)
        path.addArc(center: CGPoint(x: box.maxX - r, y: box.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        side(CGPoint(x: box.maxX - r, y: box.maxY), CGPoint(x: box.minX + r, y: box.maxY), CGVector(dx: 0, dy: 1), first: false)
        path.addArc(center: CGPoint(x: box.minX + r, y: box.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        side(CGPoint(x: box.minX, y: box.maxY - r), CGPoint(x: box.minX, y: box.minY + r), CGVector(dx: -1, dy: 0), first: false)
        path.addArc(center: CGPoint(x: box.minX + r, y: box.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The frame of a postcard: two rails of neon cord, one inside the other, not quite
/// parallel. In the colour of the hand (warm) unless told otherwise.
public struct NeonCordFrame: View {
    /// How much of the cord has been laid, 0...1: the frame can draw itself.
    var drawn: CGFloat = 1
    var tone: NeonGarden.Tone
    var gauge: CGFloat
    var gap: CGFloat
    var radius: CGFloat
    var intensity: Double

    public init(drawn: CGFloat = 1, tone: NeonGarden.Tone = NeonGarden.warm, gauge: CGFloat = 1.4, gap: CGFloat = 5, radius: CGFloat = 18, intensity: Double = 0.85) {
        self.drawn = drawn; self.tone = tone; self.gauge = gauge; self.gap = gap; self.radius = radius; self.intensity = intensity
    }

    public var body: some View {
        ZStack {
            WavyFrame(radius: radius, amplitude: 2.2, wavelength: 58).trim(from: 0, to: drawn)
                .neonTube(tone, lineWidth: gauge, intensity: intensity, spread: 9)
            // The inner rail is laid the other way round, so the two meet.
            WavyFrame(radius: radius, amplitude: 1.8, wavelength: 44, phase: 0.31).inset(by: gap).trim(from: 1 - drawn, to: 1)
                .neonTube(tone, lineWidth: gauge * 0.8, intensity: intensity * 0.8, spread: 7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A strip of paper tape, torn at both ends, stuck down a little askew.
public struct TapeStrip: View {
    var tone: NeonGarden.Tone
    var angle: Double

    public init(tone: NeonGarden.Tone = NeonGarden.warm2, angle: Double = -4) { self.tone = tone; self.angle = angle }

    /// The strip's outline: straight along its length, torn in small teeth at its ends.
    struct Torn: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let teeth = max(3, Int(rect.height / 3.5)), depth: CGFloat = min(3.2, max(2.2, rect.height / 9))
            path.move(to: CGPoint(x: rect.minX + depth, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - depth, y: rect.minY))
            for i in 1...teeth {
                let y = rect.minY + rect.height * CGFloat(i) / CGFloat(teeth)
                path.addLine(to: CGPoint(x: rect.maxX - (i % 2 == 0 ? depth : 0), y: y - rect.height / CGFloat(teeth) / 2))
                path.addLine(to: CGPoint(x: rect.maxX - depth, y: y))
            }
            path.addLine(to: CGPoint(x: rect.minX + depth, y: rect.maxY))
            for i in 1...teeth {
                let y = rect.maxY - rect.height * CGFloat(i) / CGFloat(teeth)
                path.addLine(to: CGPoint(x: rect.minX + (i % 2 == 0 ? depth : 0), y: y + rect.height / CGFloat(teeth) / 2))
                path.addLine(to: CGPoint(x: rect.minX + depth, y: y))
            }
            path.closeSubpath()
            return path
        }
    }

    public var body: some View {
        Torn()
            .fill(tone.color.opacity(0.88))
            // The sheen of tape: lighter along one edge.
            .overlay(Torn().fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1.5)
            .rotationEffect(.degrees(angle))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A small generator of numbers that are the same every time for the same seed, so that
/// what looks random does not jump about between redraws.
struct Seeded {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    /// 0..<1
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// Squared paper seen in the dark: faint lines, each only partly there.
public struct GraphPaper: View {
    var spacing: CGFloat
    public init(spacing: CGFloat = 44) { self.spacing = spacing }

    /// The pieces of line on a sheet of `size`: from, to.
    static func strokes(size: CGSize, spacing: CGFloat) -> [(CGPoint, CGPoint)] {
        var random = Seeded(7), out: [(CGPoint, CGPoint)] = []
        guard spacing > 4 else { return out }
        var x = spacing / 2
        while x < size.width {
            let from = random.next() * 0.5, length = 0.25 + random.next() * 0.6
            out.append((CGPoint(x: x, y: size.height * from), CGPoint(x: x, y: size.height * min(1, from + length))))
            x += spacing
        }
        var y = spacing / 2
        while y < size.height {
            let from = random.next() * 0.5, length = 0.25 + random.next() * 0.6
            out.append((CGPoint(x: size.width * from, y: y), CGPoint(x: size.width * min(1, from + length), y: y)))
            y += spacing
        }
        return out
    }

    public var body: some View {
        Canvas { context, size in
            for (from, to) in GraphPaper.strokes(size: size, spacing: spacing) {
                var line = Path(); line.move(to: from); line.addLine(to: to)
                context.stroke(line, with: .color(NeonGarden.mint.color.opacity(0.09)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What happens when a model has been read: a breath of light opens behind it and fades.
/// Nothing, with Reduce Motion on. (The viewer has no frame of its own: the model has the
/// whole view.)
struct OpeningLight: View {
    @ObservedObject var model: NativeViewerModel
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var bloom = false

    var body: some View {
        let ready = model.statistics != nil || model.message != nil
        ZStack {
            if model.visibility.controls && !still {
                Circle()
                    .fill(RadialGradient(colors: [NeonGarden.mint.color.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 220))
                    .frame(width: 440, height: 440)
                    .scaleEffect(bloom ? 1.5 : 0.3)
                    // Nothing before there is a model to open on.
                    .opacity(!ready || bloom ? 0 : 0.9)
                    .blendMode(.plusLighter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if ready { open() } }
        .onChange(of: ready) { _, now in if now { open() } }
    }

    private func open() { withAnimation(still ? nil : .easeOut(duration: 0.9)) { bloom = true } }
}

/// A heading written on a piece of tape.
public struct TapeLabel: View {
    let text: String
    var tone: NeonGarden.Tone
    var angle: Double

    public init(_ text: String, tone: NeonGarden.Tone = NeonGarden.mint2, angle: Double = -1.5) {
        self.text = text; self.tone = tone; self.angle = angle
    }

    public var body: some View {
        Text(text).textCase(.uppercase)
            .font(GardenTypography.heading.weight(.heavy)).tracking(1.4)
            .foregroundStyle(NeonGarden.background.color)
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(TapeStrip(tone: tone, angle: 0))
            .rotationEffect(.degrees(angle))
            .accessibilityAddTraits(.isHeader)
    }
}
