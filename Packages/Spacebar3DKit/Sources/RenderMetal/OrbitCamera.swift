import Foundation
import simd

/// Where a model sits and how far the camera must be to see all of it.
public struct Framing: Equatable, Sendable {
    public var center: SIMD3<Float>
    public var size: SIMD3<Float>
    /// Camera distance from the centre that fits the whole model.
    public var distance: Float

    public static let verticalFOV: Float = 30 * .pi / 180

    public init(center: SIMD3<Float>, size: SIMD3<Float>, distance: Float) {
        self.center = center; self.size = size; self.distance = distance
    }

    public init(min: SIMD3<Float>, max: SIMD3<Float>, fov: Float = Framing.verticalFOV) {
        let size = max - min
        let largest = Swift.max(size.x, size.y, size.z, 1e-6)
        self.init(center: (min + max) / 2, size: size, distance: largest / 2 / tan(fov / 2) * 1.4)
    }

    /// Framing for a scene with nothing in it: a unit box.
    public static let unit = Framing(min: SIMD3(repeating: -0.5), max: SIMD3(repeating: 0.5))
}

/// The views the axis gizmo can snap to.
public enum ViewPreset: CaseIterable, Sendable {
    case front, back, left, right, top, bottom

    /// Unit vector from the model towards the camera.
    public var direction: SIMD3<Float> {
        switch self {
        case .front: return SIMD3(0, 0, 1)
        case .back: return SIMD3(0, 0, -1)
        case .right: return SIMD3(1, 0, 0)
        case .left: return SIMD3(-1, 0, 0)
        case .top: return SIMD3(0, 1, 0)
        case .bottom: return SIMD3(0, -1, 0)
        }
    }
}

/// Orbit camera around a target, Y up, looking at the target: drag to orbit, drag with a
/// modifier to pan, wheel to dolly, damped motion.
public struct OrbitCamera: Equatable, Sendable {
    public var target: SIMD3<Float>
    public var distance: Float
    /// Turn around the Y axis; 0 puts the camera on +Z.
    public var yaw: Float
    /// Elevation above the horizontal plane.
    public var pitch: Float
    public var fovY: Float = Framing.verticalFOV
    public var near: Float
    public var far: Float

    /// Motion still to be applied by `step`, so that releasing a drag glides to a stop.
    var pendingYaw: Float = 0, pendingPitch: Float = 0, pendingPan = SIMD2<Float>(0, 0), pendingDolly: Float = 0

    public static let maxPitch: Float = .pi / 2 - 0.001
    /// The damping factor: the share of the remaining motion applied per 1/60 s.
    static let damping: Float = 0.1

    public init(target: SIMD3<Float> = .zero, distance: Float = 3, yaw: Float = 0, pitch: Float = 0, near: Float = 0.03, far: Float = 300) {
        self.target = target; self.distance = distance; self.yaw = yaw; self.pitch = pitch; self.near = near; self.far = far
    }

    /// A model lower than this share of its longest side lies flat (a plate, a map).
    public static let flatShare: Float = 0.05
    /// How far above the horizon a flat model is first seen from.
    public static let flatPitch: Float = 35 * .pi / 180

    /// The camera a model is first shown with: in front, a little above the middle
    /// (5% of the height), at the fitting distance. A flat model would be edge-on from
    /// there, a line or nothing at all, so it is seen from above at an angle.
    public static func home(for framing: Framing, aspect: Float = 1) -> OrbitCamera {
        let rise = framing.size.y * 0.05
        let flat = framing.size.y < max(framing.size.x, framing.size.z) * flatShare
        var camera = OrbitCamera(
            target: framing.center,
            distance: hypot(framing.distance, rise),
            yaw: 0,
            pitch: flat ? flatPitch : atan2(rise, framing.distance),
            near: framing.distance / 100,
            far: framing.distance * 100).fitted(to: framing, aspect: aspect)
        camera.distance = max(camera.distance, hypot(framing.distance, rise))
        return camera
    }

    /// Fits every corner of the bounds in both dimensions at this viewing direction.
    /// The original distance remains a lower bound, retaining the familiar framing margin.
    public func fitted(to framing: Framing, aspect: Float) -> OrbitCamera {
        var result = self
        result.cancelMotion()
        result.target = framing.center
        let (right, up, back) = basis
        let tangent = tan(fovY / 2)
        let width = tangent * max(aspect.isFinite ? aspect : 1, 1e-4)
        var distance = framing.distance
        for x: Float in [-0.5, 0.5] { for y: Float in [-0.5, 0.5] { for z: Float in [-0.5, 0.5] {
            let corner = framing.size * SIMD3(x,y,z)
            let reach = max(abs(simd_dot(corner, right)) / width, abs(simd_dot(corner, up)) / tangent)
            distance = max(distance, simd_dot(corner, back) + reach * 1.1)
        } } }
        result.distance = distance
        result.near = framing.distance / 100
        result.far = max(distance, framing.distance) * 100
        return result
    }

    // MARK: Geometry

    public var offsetDirection: SIMD3<Float> {
        SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }
    public var position: SIMD3<Float> { target + offsetDirection * distance }

    /// Where drawing begins in front of the camera: at `near`, or a tenth of the way to what
    /// the camera looks at when that is nearer. Closing in on a surface would otherwise cut
    /// it open, the zoom going closer than `near` is set for the whole model.
    public var nearPlane: Float { min(near, distance / 10) }

    /// An angle within half a turn either way of none. An angle left to grow (a model
    /// turning by itself for days) ends up too large to tell one frame's turn from the next.
    private static func withinATurn(_ angle: Float) -> Float {
        let wrapped = angle.remainder(dividingBy: 2 * .pi)
        return wrapped.isFinite ? wrapped : 0
    }

    /// Camera axes in world space: `back` points from the target towards the camera.
    public var basis: (right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>) {
        let back = offsetDirection
        let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
        return (right, simd_cross(back, right), back)
    }

    public var viewMatrix: simd_float4x4 {
        let (right, up, back) = basis
        let p = position
        return simd_float4x4(columns: (
            SIMD4(right.x, up.x, back.x, 0),
            SIMD4(right.y, up.y, back.y, 0),
            SIMD4(right.z, up.z, back.z, 0),
            SIMD4(-simd_dot(right, p), -simd_dot(up, p), -simd_dot(back, p), 1)))
    }

    /// Perspective with reversed depth (near maps to 1, far to 0): float depth keeps its
    /// precision over a near/far ratio of 10^4 that way.
    public func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let f = 1 / tan(fovY / 2), near = nearPlane
        // depth = (A z + B) / -z with A = n/(f-n), B = f n/(f-n); z < 0 in view space.
        return simd_float4x4(columns: (
            SIMD4(f / max(aspect, 1e-4), 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, near / (far - near), -1),
            SIMD4(0, 0, far * near / (far - near), 0)))
    }

    // MARK: Interaction (pixel deltas, y pointing down)

    /// Turns the camera around the target. A drag across the view's height is one revolution.
    public mutating func orbit(dx: Float, dy: Float, viewHeight: Float) {
        let k = 2 * Float.pi / max(viewHeight, 1)
        pendingYaw -= dx * k
        pendingPitch += dy * k
    }

    /// Slides the camera and target in the view plane so the model follows the pointer.
    public mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let k = 2 * distance * tan(fovY / 2) / max(viewHeight, 1)
        pendingPan += SIMD2(-dx * k, dy * k)
    }

    /// Moves in (scale < 1) or out (scale > 1).
    public mutating func zoom(scale: Float) {
        pendingDolly += log(max(scale, 1e-3))
    }

    /// Moves in or out towards a point of the picture, `offset` points to the right of its
    /// middle and up from it, in a picture `viewHeight` points high: what is under that
    /// point stays under it. Inside `distanceLimits` the zoom stops at the limit, and the
    /// slide that goes with it stops there too.
    public mutating func zoom(scale: Float, toward offset: SIMD2<Float>, viewHeight: Float, distanceLimits: ClosedRange<Float>? = nil) {
        guard scale.isFinite, scale > 0, offset.x.isFinite, offset.y.isFinite else { return }
        // Where the moves already under way take the camera.
        let coming = distance * exp(pendingDolly)
        var s = max(scale, 1e-3)
        if let limits = distanceLimits, coming > 0 {
            s = s < 1 ? max(s, min(1, limits.lowerBound / coming)) : min(s, max(1, limits.upperBound / coming))
        }
        // A point of the plane through the target, `offset` from the middle, stays where it
        // is on the screen when the target moves towards it by the share the distance loses.
        let k = 2 * coming * tan(fovY / 2) / max(viewHeight, 1)
        pendingPan += offset * k * (1 - s)
        pendingDolly += log(s)
    }

    public var isMoving: Bool {
        abs(pendingYaw) > 1e-4 || abs(pendingPitch) > 1e-4 || abs(pendingDolly) > 1e-4 || simd_length(pendingPan) > 1e-6 * max(distance, 1e-3)
    }

    /// Applies the pending motion for a frame of `dt` seconds. `limits` bounds the distance.
    public mutating func step(dt: Float, distanceLimits: ClosedRange<Float>? = nil) {
        let share = 1 - pow(1 - Self.damping, min(max(dt, 0), 0.25) * 60)
        yaw = Self.withinATurn(yaw + pendingYaw * share)
        pitch = min(Self.maxPitch, max(-Self.maxPitch, pitch + pendingPitch * share))
        let (right, up, _) = basis
        let pan = pendingPan * share
        target += right * pan.x + up * pan.y
        distance *= exp(pendingDolly * share)
        if let limits = distanceLimits { distance = min(limits.upperBound, max(limits.lowerBound, distance)) }
        pendingYaw *= 1 - share; pendingPitch *= 1 - share; pendingPan *= 1 - share; pendingDolly *= 1 - share
        if !isMoving { pendingYaw = 0; pendingPitch = 0; pendingPan = .zero; pendingDolly = 0 }
    }

    /// Turns by the given angles at once (auto-rotate, the gizmo's own drag).
    public mutating func rotate(yaw dYaw: Float, pitch dPitch: Float) {
        yaw = Self.withinATurn(yaw + dYaw)
        pitch = min(Self.maxPitch, max(-Self.maxPitch, pitch + dPitch))
    }

    public mutating func cancelMotion() { pendingYaw = 0; pendingPitch = 0; pendingPan = .zero; pendingDolly = 0 }

    /// The camera that looks at the model from a preset direction at the fitting distance.
    public static func preset(_ preset: ViewPreset, framing: Framing, like base: OrbitCamera, aspect: Float = 1) -> OrbitCamera {
        var camera = base
        camera.cancelMotion()
        camera.target = framing.center
        camera.distance = framing.distance
        switch preset {
        case .top: camera.pitch = maxPitch
        case .bottom: camera.pitch = -maxPitch
        default:
            let d = preset.direction
            camera.pitch = 0
            camera.yaw = atan2(d.x, d.z)
        }
        // Looking down or up is a fixed view like the other four: turned as for the front.
        if preset == .top || preset == .bottom { camera.yaw = 0 }
        return camera.fitted(to: framing, aspect: aspect)
    }

    /// The camera part of the way through a 250 ms move; yaw takes the short way round.
    /// The distance goes by ratio, so that the model changes size on the screen evenly.
    public static func blend(_ a: OrbitCamera, _ b: OrbitCamera, _ t: Float) -> OrbitCamera {
        var out = b
        var delta = (b.yaw - a.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        out.yaw = a.yaw + delta * t
        out.pitch = a.pitch + (b.pitch - a.pitch) * t
        out.distance = a.distance > 0 && b.distance > 0 ? a.distance * pow(b.distance / a.distance, t) : a.distance + (b.distance - a.distance) * t
        out.target = a.target + (b.target - a.target) * t
        out.cancelMotion()
        return out
    }
}

/// Where the floor grid goes: under the model, sized to it, on round coordinates.
public struct GridPlacement: Equatable, Sendable {
    public static let divisions = 20
    /// Edge length of one cell.
    public var cell: Float
    /// Centre of the grid; y is the model's lowest point.
    public var center: SIMD3<Float>

    public init(cell: Float, center: SIMD3<Float>) { self.cell = cell; self.center = center }

    public init(framing: Framing) {
        let footprint = max(framing.size.x, framing.size.y, framing.size.z, 1e-6)
        let rough = footprint / 5
        let power = pow(10, floor(log10(rough)))
        let cell = [1, 2, 5, 10].map { Float($0) * power }.first { $0 >= rough * 0.999999 } ?? rough
        self.cell = cell
        center = SIMD3(
            (framing.center.x / cell).rounded() * cell,
            framing.center.y - framing.size.y / 2,
            (framing.center.z / cell).rounded() * cell)
    }
}
