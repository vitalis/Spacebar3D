import SwiftUI

/// The mark of the app, as on its icon: a chameleon stepping out of a file drawn in two
/// rails of neon, taped at the top. While it waits, it comes forward out of the dark, its
/// light breathes, and a bead of light runs round the rails. With Reduce Motion on it
/// stands still.
public struct NeonMark: View {
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var began = Date()

    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still)) { time in
            let seconds = still ? NeonMark.arrival : time.date.timeIntervalSince(began)
            // The picture is larger than the mark by a margin, for its light to fade out in.
            Canvas { context, size in NeonMark.draw(&context, size: size, time: seconds, still: still) }
                .padding(-NeonMark.margin)
        }
        .accessibilityHidden(true)
    }

    static let margin: CGFloat = 56

    /// The picture: the icon's artwork about its subject, its dark made clear
    /// (`scripts/make-mark.swift`).
    static let picture: Image = {
        guard let url = Bundle.module.url(forResource: "Mark", withExtension: "png"), let image = NSImage(contentsOf: url) else { return Image(systemName: "cube") }
        return Image(nsImage: image)
    }()

    /// Seconds the mark takes to come forward.
    static let arrival = 0.45

    /// How far it has come at `time` since the start: 0 not yet, 1 there.
    static func arrived(at time: Double) -> Double {
        let x = min(1, max(0, time / arrival))
        return 1 - (1 - x) * (1 - x) * (1 - x)
    }

    /// The line midway between the file's two rails, on the picture taken as a unit square:
    /// from the top left corner round by the folded corner and back.
    static let rail: [CGPoint] = [
        CGPoint(x: 0.180, y: 0.158), CGPoint(x: 0.690, y: 0.158), CGPoint(x: 0.868, y: 0.330),
        CGPoint(x: 0.880, y: 0.905), CGPoint(x: 0.866, y: 0.928), CGPoint(x: 0.176, y: 0.922),
        CGPoint(x: 0.154, y: 0.900), CGPoint(x: 0.146, y: 0.185),
    ]

    /// Seconds for the bead of light to go once round the rails.
    static let lap: Double = 2.8

    /// The point `part` of the way round the rails (0...1, and on round).
    static func onRail(_ part: Double) -> CGPoint {
        let closed = rail + [rail[0]]
        let lengths = zip(closed, closed.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var left = (part - part.rounded(.down)) * lengths.reduce(0, +)
        for (index, length) in lengths.enumerated() {
            if left <= length || index == lengths.count - 1 {
                let t = length > 0 ? min(1, left / length) : 0
                return CGPoint(x: closed[index].x + (closed[index + 1].x - closed[index].x) * t,
                               y: closed[index].y + (closed[index + 1].y - closed[index].y) * t)
            }
            left -= length
        }
        return closed[0]
    }

    // MARK: Drawing

    static func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, still: Bool = false) {
        let side = max(1, min(size.width, size.height) - 2 * margin)
        let come = arrived(at: time), breath = still ? 0.5 : 0.5 + 0.5 * sin(time * 1.7)
        // The picture is wider than the mark, so that its glow has room: the file stands
        // in the square, the light spills into the margin.
        let reach = side * 1.34 * (0.92 + 0.08 * come)
        let lift = still ? 0 : CGFloat(sin(time * 1.1)) * side * 0.008
        let frame = CGRect(x: (size.width - reach) / 2, y: (size.height - reach) / 2 - side * 0.03 + lift, width: reach, height: reach)
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height) }

        // Its neon shadow: the chameleon's own light on the dark behind it, breathing.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: side * 0.12)); layer.blendMode = .plusLighter
            let pool = CGRect(x: frame.minX + frame.width * 0.22, y: frame.minY + frame.height * 0.42, width: frame.width * 0.56, height: frame.height * 0.46)
            layer.fill(Path(ellipseIn: pool), with: .color(NeonGarden.signal.color.opacity((0.10 + 0.10 * breath) * come)))
        }

        // Keep the moving light behind the artwork so it cannot cover the face or tape.
        if !still, come >= 1 {
            let head = (time - arrival) / lap, gauge = side / 60
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                let steps = 110
                for step in 0..<steps {
                    let glow = Double(step + 1) / Double(steps)
                    var piece = Path()
                    piece.move(to: at(onRail(head - 0.22 * (1 - Double(step) / Double(steps)))))
                    piece.addLine(to: at(onRail(head - 0.22 * (1 - Double(step + 1) / Double(steps)))))
                    layer.stroke(piece, with: .color(NeonGarden.info.color.opacity(glow * glow * 0.9)), style: StrokeStyle(lineWidth: gauge * (1.6 + 1.6 * glow), lineCap: .round))
                    layer.stroke(piece, with: .color(.white.opacity(glow * glow)), style: StrokeStyle(lineWidth: gauge * 0.9, lineCap: .round))
                }
            }
            let bead = at(onRail(head))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: gauge * 4)); layer.blendMode = .plusLighter
                layer.fill(Path(ellipseIn: CGRect(x: bead.x - gauge * 5, y: bead.y - gauge * 5, width: gauge * 10, height: gauge * 10)), with: .color(NeonGarden.info.color.opacity(0.9)))
            }
            context.fill(Path(ellipseIn: CGRect(x: bead.x - gauge * 1.3, y: bead.y - gauge * 1.3, width: gauge * 2.6, height: gauge * 2.6)), with: .color(.white))
        }

        // The picture, its edges fading away.
        context.drawLayer { layer in
            layer.opacity = come
            layer.clipToLayer { mask in
                mask.fill(Path(frame), with: .radialGradient(
                    Gradient(stops: [.init(color: .white, location: 0.82), .init(color: .clear, location: 1)]),
                    center: CGPoint(x: frame.midX, y: frame.midY), startRadius: 0, endRadius: reach * 0.62))
            }
            layer.draw(picture, in: frame)
        }
    }
}
