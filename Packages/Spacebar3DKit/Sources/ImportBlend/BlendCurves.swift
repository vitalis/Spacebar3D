import Foundation
import simd

/// One animation curve of a Blender file (an F-curve): keys with handles, and how each key
/// leads to the next. Values are worked out as Blender 5 does in `fcurve_eval_keyframes`
/// (the cubic is solved for the frame, then the value is taken; a handle may not reach
/// further than the next key in time), but are not copied from its source.
///
/// The file is not trusted: a curve is made only of keys that are numbers, in order, and
/// evaluating one cannot trap.
struct BlendCurve {
    struct Key {
        var frame: Double, value: Double
        var leftFrame: Double, leftValue: Double
        var rightFrame: Double, rightValue: Double
        /// 0 constant, 1 linear, 2 Bezier; the easing kinds (3 and up) are not read and run linearly.
        var interpolation: UInt8
    }

    /// Where the curve points, as the file says it: `location`, `pose.bones["Arm"].rotation_quaternion`.
    var path: String
    var index: Int
    /// In order of frame, one key a frame at most.
    var keys: [Key]

    /// The most keys a curve is read with.
    static let maxKeys = 1_000_000

    /// How far a handle may reach, and how close two frames count as one.
    private static let tiny = 1e-9

    /// The curve's value at `frame`: the first key's before it, the last key's after it.
    func value(at frame: Double) -> Float {
        guard let first = keys.first, let last = keys.last, frame.isFinite else { return 0 }
        if frame <= first.frame { return Float(first.value) }
        if frame >= last.frame { return Float(last.value) }
        // The last key at or before the frame.
        var low = 0, high = keys.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if keys[middle].frame <= frame { low = middle } else { high = middle }
        }
        let a = keys[low], b = keys[high]
        let span = b.frame - a.frame
        guard span > Self.tiny else { return Float(a.value) }
        switch a.interpolation {
        case 0: return Float(a.value)
        case 2: return Float(Self.bezier(frame, a, b))
        default: return Float(a.value + (b.value - a.value) * (frame - a.frame) / span)
        }
    }

    /// The frames at which the value jumps: where a constant key's hold ends at the next key.
    var jumps: [Double] {
        zip(keys, keys.dropFirst()).filter { $0.0.interpolation == 0 }.map { $0.1.frame }
    }

    /// The value of the cubic through keys `a` and `b` at `frame`: Blender solves the cubic
    /// in time for the position along the curve, then takes the value there.
    private static func bezier(_ frame: Double, _ a: Key, _ b: Key) -> Double {
        let x0 = a.frame, y0 = a.value, x3 = b.frame, y3 = b.value
        var x1 = a.rightFrame, y1 = a.rightValue, x2 = b.leftFrame, y2 = b.leftValue
        guard [x1, y1, x2, y2].allSatisfy(\.isFinite) else { return y0 }
        // Flat on both sides: the one value (and no cubic to solve).
        if abs(y0 - y3) < 1.2e-7, abs(y1 - y2) < 1.2e-7, abs(y2 - y3) < 1.2e-7 { return y0 }
        // A handle may not reach past the other key in time, or the curve would loop back.
        let length = x3 - x0
        let reach1 = abs(x0 - x1), reach2 = abs(x3 - x2)
        if reach1 + reach2 > 0 {
            if reach1 > length { let f = length / reach1; x1 = x0 - f * (x0 - x1); y1 = y0 - f * (y0 - y1) }
            if reach2 > length { let f = length / reach2; x2 = x3 - f * (x3 - x2); y2 = y3 - f * (y3 - y2) }
        }
        func cubic(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ s: Double) -> Double {
            let u = 1 - s
            return u * u * u * p0 + 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s * p3
        }
        // Where along the curve (0...1) is it at `frame`: the time runs forward, so halving finds it.
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if cubic(x0, x1, x2, x3, middle) < frame { low = middle } else { high = middle }
        }
        return cubic(y0, y1, y2, y3, (low + high) / 2)
    }

    // MARK: Reading

    /// The curve at an F-curve block, or nil when it is muted, has no keys, or its keys are not read.
    static func read(_ block: BlendFile.Block, in file: BlendFile) -> BlendCurve? {
        guard let pathField = file.offset("FCurve", "rna_path"), let indexField = file.offset("FCurve", "array_index"),
              let totalField = file.offset("FCurve", "totvert"), let keysField = file.offset("FCurve", "bezt"),
              let bezier = file.structure("BezTriple"), let vec = bezier.fields["vec"], let interpolation = bezier.fields["ipo"],
              bezier.size > 0, vec.offset + 36 <= bezier.size else { return nil }
        // Muted (bit 4) or disabled (bit 10) curves do nothing in Blender.
        if let flag = file.offset("FCurve", "flag"), file.i16(block.offset + flag) & (1 << 4 | 1 << 10) != 0 { return nil }
        guard let text = file.block(at: file.pointer(block.offset + pathField)), let held = file.block(at: file.pointer(block.offset + keysField)) else { return nil }
        let count = min(max(Int(file.i32(block.offset + totalField)), 0), held.length / bezier.size, maxKeys)
        guard count > 0 else { return nil }
        var keys: [Key] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            let at = held.offset + i * bezier.size
            let v = file.floats(at + vec.offset, 9).map(Double.init)
            guard v[1].isFinite, v[4].isFinite, v[3].isFinite, v[7].isFinite else { continue }
            keys.append(Key(frame: v[3], value: v[4], leftFrame: v[0], leftValue: v[1], rightFrame: v[6], rightValue: v[7],
                            interpolation: file.u8(at + interpolation.offset)))
        }
        // Frames are in order in a saved file; one that is not is put in order, and a twin dropped.
        if !keys.isEmpty, zip(keys, keys.dropFirst()).contains(where: { $0.frame >= $1.frame }) {
            keys.sort { $0.frame < $1.frame }
            keys = keys.enumerated().filter { $0.offset == 0 || $0.element.frame > keys[$0.offset - 1].frame }.map(\.element)
        }
        guard !keys.isEmpty else { return nil }
        return BlendCurve(path: file.text(text.offset, min(text.length, 1024)), index: Int(file.i32(block.offset + indexField)), keys: keys)
    }

    // MARK: Paths

    /// What a curve's path points at.
    enum Target: Equatable {
        /// The object's own property: `location`, `rotation_euler`, `rotation_quaternion`, `scale`.
        case object(String)
        /// A pose bone's, by its name.
        case bone(String, String)
        /// The value of a shape key, by its name.
        case shapeKey(String)
    }

    var target: Target? {
        func quoted(_ text: Substring) -> (name: String, rest: Substring)? {
            guard text.hasPrefix("[\"") else { return nil }
            var name = "", escaped = false
            var rest = text.dropFirst(2)
            while let c = rest.first {
                rest = rest.dropFirst()
                if escaped { name.append(c); escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                    guard rest.hasPrefix("]") else { return nil }
                    return (name, rest.dropFirst())
                } else { name.append(c) }
            }
            return nil
        }
        if path.hasPrefix("pose.bones"), let (name, rest) = quoted(Substring(path.dropFirst("pose.bones".count))), rest.hasPrefix(".") {
            return .bone(name, String(rest.dropFirst()))
        }
        if path.hasPrefix("key_blocks"), let (name, rest) = quoted(Substring(path.dropFirst("key_blocks".count))), rest == ".value" {
            return .shapeKey(name)
        }
        return path.contains(".") || path.contains("[") ? nil : .object(path)
    }
}

/// Turning curves into the keys of a straight-line animation, which is what the scene holds.
enum BlendSampling {
    /// A frame is this long after the frame a constant key holds until, so that the value
    /// jumps within a thousandth of a frame of the next key instead of ramping over a segment.
    static let jump = 0.001
    /// Frames closer than this are not told apart when a segment is cut in two.
    static let finest = 1.0 / 64

    /// The frames, and the values there, from which a straight-line playback follows `value`
    /// closely: every key frame in `from...to`, the ends, a frame just before each key a
    /// constant key leads up to, and as many frames between as the curve's bend asks for.
    ///
    /// - Parameters:
    ///   - keyFrames: the frames of the curves' keys, any order.
    ///   - steps: the key frames at which a value jumps to a new one (a constant key ends there).
    ///   - mix: the playback's own blend (slerp for rotations).
    ///   - error: how far apart two values are.
    ///   - budget: the most frames still to be spent on bends, shared by the tracks of a file.
    static func samples<Value>(from low: Double, to high: Double, keyFrames: [Double], steps: Set<Double>,
                               tolerance: Float, budget: inout Int,
                               value: (Double) -> Value, mix: (Value, Value, Float) -> Value,
                               error: (Value, Value) -> Float) -> [(frame: Double, value: Value)] {
        var frames = Set(keyFrames.filter { $0 > low && $0 < high && $0.isFinite })
        frames.insert(low); frames.insert(high)
        let ordered = frames.sorted()
        var out: [(frame: Double, value: Value)] = []
        func refine(_ t0: Double, _ v0: Value, _ t1: Double, _ v1: Value) {
            guard t1 - t0 > finest, budget > 0 else { return }
            var worst: Float = 0
            for f in [0.25, 0.5, 0.75] {
                worst = max(worst, error(value(t0 + (t1 - t0) * f), mix(v0, v1, Float(f))))
            }
            guard worst > tolerance else { return }
            let middle = (t0 + t1) / 2, v = value(middle)
            budget -= 1
            refine(t0, v0, middle, v)
            out.append((middle, v))
            refine(middle, v, t1, v1)
        }
        var previous: (frame: Double, value: Value)?
        for frame in ordered {
            let here = value(frame)
            if let (start, before) = previous {
                if steps.contains(frame), frame - start > 3 * jump {
                    // Bends up to just before the jump, then the jump.
                    let end = frame - jump, held = value(end)
                    refine(start, before, end, held)
                    out.append((end, held))
                } else {
                    refine(start, before, frame, here)
                }
            }
            out.append((frame, here))
            previous = (frame, here)
        }
        return out
    }
}
