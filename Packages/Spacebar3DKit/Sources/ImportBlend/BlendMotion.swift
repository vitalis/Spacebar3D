import Foundation
import simd

/// The scene's clock: clip time 0 is the scene's first frame.
struct BlendTiming {
    var start = 1.0
    var end = 250.0
    var framesPerSecond = 24.0

    /// Seconds into the clip that `frame` is.
    func seconds(_ frame: Double) -> Float { Float((frame - start) / framesPerSecond) }
}

/// What an object or a pose bone holds as its placement when the file was saved: the
/// values the animation leaves alone, and the start of the ones it moves.
struct BlendTransform {
    var location = SIMD3<Float>.zero
    /// 0 is a quaternion, 1 to 6 are Euler turns (XYZ, XZY, YXZ, YZX, ZXY, ZYX), below 0 an axis and an angle.
    var mode = 1
    var euler = SIMD3<Float>.zero
    /// w, x, y, z, as Blender keeps them.
    var quaternion = SIMD4<Float>(1, 0, 0, 0)
    var axis = SIMD3<Float>(0, 1, 0)
    var angle: Float = 0
    var scale = SIMD3<Float>(repeating: 1)
    /// An object's delta transforms, added under its own.
    var deltaLocation = SIMD3<Float>.zero
    var deltaEuler = SIMD3<Float>.zero
    var deltaQuaternion = SIMD4<Float>(1, 0, 0, 0)
    var deltaScale = SIMD3<Float>(repeating: 1)

    /// The turn of `euler` in the order `mode` names: about the first axis first, as Blender does.
    static func turn(euler e: SIMD3<Float>, mode: Int) -> simd_quatf {
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        var result = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        for axis in orders[min(max(mode, 1), 6) - 1] {
            var v = SIMD3<Float>(repeating: 0); v[axis] = 1
            result = simd_quatf(angle: e[axis], axis: v) * result
        }
        return result
    }

    /// A quaternion kept as w, x, y, z, made a unit one (Blender uses none at all as no turn).
    static func unit(_ q: SIMD4<Float>) -> simd_quatf {
        let length = simd_length(q)
        guard length.isFinite, length > 0 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let n = q / length
        return simd_quatf(ix: n.y, iy: n.z, iz: n.w, r: n.x)
    }

    static func turn(mode: Int, euler: SIMD3<Float>, quaternion: SIMD4<Float>, axis: SIMD3<Float>, angle: Float) -> simd_quatf {
        if mode > 0 { return turn(euler: euler, mode: mode) }
        if mode < 0 {
            let length = simd_length(axis)
            return length > 0 && length.isFinite ? simd_quatf(angle: angle, axis: axis / length) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return unit(quaternion)
    }

    var rotation: simd_quatf {
        Self.turn(mode: mode, euler: deltaEuler, quaternion: deltaQuaternion, axis: SIMD3(0, 1, 0), angle: 0)
            * Self.turn(mode: mode, euler: euler, quaternion: quaternion, axis: axis, angle: angle)
    }
}

/// A joint's keyed transform: its saved values, and the curves that replace some of them.
struct BlendMotion {
    var stored: BlendTransform
    private(set) var location = [BlendCurve?](repeating: nil, count: 3)
    private(set) var euler = [BlendCurve?](repeating: nil, count: 3)
    private(set) var quaternion = [BlendCurve?](repeating: nil, count: 4)
    private(set) var scale = [BlendCurve?](repeating: nil, count: 3)

    init(stored: BlendTransform) { self.stored = stored }

    var hasLocation: Bool { location.contains { $0 != nil } }
    var hasRotation: Bool { stored.mode > 0 ? euler.contains { $0 != nil } : stored.mode == 0 && quaternion.contains { $0 != nil } }
    var hasScale: Bool { scale.contains { $0 != nil } }
    var isAnimated: Bool { hasLocation || hasRotation || hasScale }

    /// Takes a curve of a property (`location`, `rotation_euler`, `rotation_quaternion`, `scale`)
    /// that the joint has: a rotation property the rotation mode does not use is not shown.
    mutating func add(_ property: String, _ curve: BlendCurve) {
        let k = curve.index
        switch property {
        case "location" where location.indices.contains(k): location[k] = curve
        case "rotation_euler" where euler.indices.contains(k): euler[k] = curve
        case "rotation_quaternion" where quaternion.indices.contains(k): quaternion[k] = curve
        case "scale" where scale.indices.contains(k): scale[k] = curve
        default: break
        }
    }

    func translation(at frame: Double) -> SIMD3<Float> {
        var v = stored.location
        for k in 0..<3 { if let c = location[k] { v[k] = c.value(at: frame) } }
        return v + stored.deltaLocation
    }

    func rotation(at frame: Double) -> simd_quatf {
        var e = stored.euler, q = stored.quaternion
        for k in 0..<3 { if let c = euler[k] { e[k] = c.value(at: frame) } }
        for k in 0..<4 { if let c = quaternion[k] { q[k] = c.value(at: frame) } }
        return BlendTransform.turn(mode: stored.mode, euler: stored.deltaEuler, quaternion: stored.deltaQuaternion, axis: SIMD3(0, 1, 0), angle: 0)
            * BlendTransform.turn(mode: stored.mode, euler: e, quaternion: q, axis: stored.axis, angle: stored.angle)
    }

    func scale(at frame: Double) -> SIMD3<Float> {
        var v = stored.scale
        for k in 0..<3 { if let c = scale[k] { v[k] = c.value(at: frame) } }
        return v * stored.deltaScale
    }

    /// The frames of the keys of a group of curves, and those at which one of them jumps.
    private static func frames(_ curves: [BlendCurve?]) -> (keys: [Double], jumps: Set<Double>) {
        let present = curves.compactMap { $0 }
        return (present.flatMap { $0.keys.map(\.frame) }, Set(present.flatMap(\.jumps)))
    }
    var locationFrames: (keys: [Double], jumps: Set<Double>) { Self.frames(location) }
    var rotationFrames: (keys: [Double], jumps: Set<Double>) { Self.frames(stored.mode > 0 ? euler : quaternion) }
    var scaleFrames: (keys: [Double], jumps: Set<Double>) { Self.frames(scale) }
}
