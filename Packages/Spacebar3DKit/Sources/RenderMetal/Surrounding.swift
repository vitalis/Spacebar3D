import ModelCore
import simd

/// The mood of the light a model stands in: the glasshouse it opens in, a dawn, a moonlit
/// night, neon. Each is a few colours and two lights, worked out here and not read from a
/// photograph, so they cost nothing to carry and nothing to load.
public enum Surrounding: String, CaseIterable, Sendable {
    case glasshouse, dawn, noon, goldenHour, overcast, moonlit, neon

    public var title: String {
        switch self {
        case .glasshouse: return L10n.text("Glasshouse")
        case .dawn: return L10n.text("Dawn")
        case .noon: return L10n.text("Noon")
        case .goldenHour: return L10n.text("Golden Hour")
        case .overcast: return L10n.text("Overcast")
        case .moonlit: return L10n.text("Moonlit")
        case .neon: return L10n.text("Neon")
        }
    }

    /// The light of a surrounding. Colours are linear.
    public struct Light: Equatable, Sendable {
        /// The main light: where it comes from, and its colour times its strength.
        public var sun: SIMD3<Float>, sunColor: SIMD3<Float>
        /// The light that softens the shadows.
        public var fill: SIMD3<Float>, fillColor: SIMD3<Float>
        /// Light from all round: from above, from below, and the same from everywhere.
        public var sky: SIMD3<Float>, ground: SIMD3<Float>, even: SIMD3<Float>
        /// What a mirror shows: looking down, looking up, and how bright the sun is in it.
        public var low: SIMD3<Float>, high: SIMD3<Float>, glow: Float
    }

    public var light: Light {
        func n(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { simd_normalize(SIMD3(x, y, z)) }
        switch self {
        case .glasshouse:
            // White light through glass from two sides: neutral, as a model is first shown.
            return Light(sun: n(1, 2, 1.5), sunColor: SIMD3(repeating: 2), fill: n(-1.5, 1, -1), fillColor: SIMD3(repeating: 0.6),
                         sky: SIMD3(repeating: 1), ground: SIMD3(0.058, 0.058, 0.091), even: SIMD3(repeating: 1),
                         low: SIMD3(0.10, 0.10, 0.12), high: SIMD3(0.95, 0.95, 0.98), glow: 0)
        case .dawn:
            // A low pink sun, and the cool blue of the sky it has not yet reached.
            return Light(sun: n(1.4, 0.45, 0.6), sunColor: SIMD3(2.3, 1.45, 1.25), fill: n(-1, 0.9, -0.6), fillColor: SIMD3(0.3, 0.4, 0.7),
                         sky: SIMD3(0.55, 0.6, 0.95), ground: SIMD3(0.2, 0.14, 0.16), even: SIMD3(0.6, 0.52, 0.6),
                         low: SIMD3(0.16, 0.1, 0.12), high: SIMD3(0.75, 0.6, 0.85), glow: 3)
        case .noon:
            // The sun overhead, hard and white, under a blue sky.
            return Light(sun: n(0.25, 2.4, 0.4), sunColor: SIMD3(2.9, 2.8, 2.6), fill: n(-1, 0.4, -0.8), fillColor: SIMD3(0.25, 0.35, 0.55),
                         sky: SIMD3(0.5, 0.72, 1.2), ground: SIMD3(0.4, 0.38, 0.32), even: SIMD3(0.6, 0.66, 0.75),
                         low: SIMD3(0.3, 0.28, 0.24), high: SIMD3(0.55, 0.8, 1.25), glow: 3.5)
        case .goldenHour:
            // The last hour of sun: amber from the side, violet in the shade.
            return Light(sun: n(-1.5, 0.5, 0.7), sunColor: SIMD3(2.8, 1.75, 0.8), fill: n(1, 0.8, -0.6), fillColor: SIMD3(0.4, 0.3, 0.65),
                         sky: SIMD3(0.75, 0.55, 0.7), ground: SIMD3(0.32, 0.18, 0.1), even: SIMD3(0.75, 0.55, 0.42),
                         low: SIMD3(0.24, 0.13, 0.08), high: SIMD3(0.95, 0.65, 0.6), glow: 3.5)
        case .overcast:
            // No sun to speak of: soft grey light from the whole sky.
            return Light(sun: n(0.3, 2, 0.6), sunColor: SIMD3(0.8, 0.82, 0.86), fill: n(-0.6, 1.5, -0.8), fillColor: SIMD3(0.5, 0.52, 0.56),
                         sky: SIMD3(1.5, 1.55, 1.65), ground: SIMD3(0.3, 0.3, 0.32), even: SIMD3(1.25, 1.28, 1.34),
                         low: SIMD3(0.22, 0.22, 0.24), high: SIMD3(0.85, 0.87, 0.92), glow: 0)
        case .moonlit:
            // A blue moon high up, and a little warm light from a window somewhere.
            return Light(sun: n(0.3, 1.5, -0.6), sunColor: SIMD3(0.55, 0.7, 1.15), fill: n(-1, 0.3, 0.8), fillColor: SIMD3(0.28, 0.2, 0.12),
                         sky: SIMD3(0.06, 0.1, 0.28), ground: SIMD3(0.01, 0.015, 0.035), even: SIMD3(0.1, 0.13, 0.24),
                         low: SIMD3(0.01, 0.015, 0.04), high: SIMD3(0.08, 0.14, 0.4), glow: 2)
        case .neon:
            // The garden's own signs: chartreuse from one side, magenta from the other.
            return Light(sun: n(1.3, 0.9, 0.9), sunColor: SIMD3(1.5, 2.3, 0.35), fill: n(-1.3, 0.6, -0.5), fillColor: SIMD3(1.9, 0.25, 0.75),
                         sky: SIMD3(0.12, 0.3, 0.22), ground: SIMD3(0.02, 0.05, 0.035), even: SIMD3(0.14, 0.2, 0.18),
                         low: SIMD3(0.02, 0.05, 0.035), high: SIMD3(0.15, 0.4, 0.28), glow: 3)
        }
    }

    /// The light turned round the upright axis by `angle` (radians): what the renderer uses.
    public func light(turned angle: Float) -> Light {
        var l = light
        let c = cos(angle), s = sin(angle)
        func turn(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x * c + v.z * s, v.y, v.z * c - v.x * s) }
        l.sun = turn(l.sun); l.fill = turn(l.fill)
        return l
    }

    /// The surrounding as a panorama, for a picture of it: the colour (sRGB, 0...1) seen at
    /// `u` round the horizon (0...1) and `v` from straight up (0) to straight down (1).
    public func panorama(u: Float, v: Float, turned angle: Float = 0) -> SIMD3<Float> {
        let l = light(turned: angle)
        let azimuth = (u - 0.5) * 2 * Float.pi, elevation = (0.5 - v) * Float.pi
        let d = SIMD3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
        var t = min(max((d.y * 0.5 + 0.5 - 0.15) / 0.7, 0), 1)
        t = t * t * (3 - 2 * t)
        var c = l.low + (l.high - l.low) * t
        // The lights themselves are drawn, so that turning them can be seen.
        c += l.sunColor * pow(max(simd_dot(d, l.sun), 0), 90) * 1.4
        c += l.fillColor * pow(max(simd_dot(d, l.fill), 0), 40) * 1.2
        func srgb(_ x: Float) -> Float { let y = min(max(x, 0), 1); return y <= 0.0031308 ? y * 12.92 : 1.055 * pow(y, 1 / 2.4) - 0.055 }
        return SIMD3(srgb(c.x), srgb(c.y), srgb(c.z))
    }
}
