import ModelCore
import simd

/// Interval arithmetic bounds every authored key and the motion between keys. Work is
/// proportional to channel data plus geometry, rather than vertices times keyframes.
struct AnimationBounds {
    struct Box {
        var low: SIMD3<Float>
        var high: SIMD3<Float>
        init(_ point: SIMD3<Float>) { low = point; high = point }
        init(low: SIMD3<Float>, high: SIMD3<Float>) { self.low = low; self.high = high }
        mutating func include(_ other: Box) {
            low = simd_min(low, other.low); high = simd_max(high, other.high)
        }
        mutating func add(_ other: Box, weight: Float) {
            low += simd_min(other.low * weight, other.high * weight)
            high += simd_max(other.low * weight, other.high * weight)
        }
    }

    struct Transform {
        var low: simd_float4x4
        var high: simd_float4x4
        init(_ matrix: simd_float4x4) { low = matrix; high = matrix }
        mutating func include(_ other: Transform) {
            for c in 0..<4 { low[c] = simd_min(low[c], other.low[c]); high[c] = simd_max(high[c], other.high[c]) }
        }
        static func * (a: Transform, b: Transform) -> Transform {
            var result = Transform(simd_float4x4(diagonal: .zero))
            for c in 0..<4 { for r in 0..<4 { for k in 0..<4 {
                let v = product(a.low[k][r], a.high[k][r], b.low[c][k], b.high[c][k])
                result.low[c][r] += v.0; result.high[c][r] += v.1
            } } }
            return result
        }
        func apply(_ box: Box) -> Box {
            let lo = SIMD4(box.low, 1), hi = SIMD4(box.high, 1)
            var result = Box(.zero)
            for r in 0..<3 { for c in 0..<4 {
                let v = product(low[c][r], high[c][r], lo[c], hi[c])
                result.low[r] += v.0; result.high[r] += v.1
            } }
            return result
        }
    }

    private static func product(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> (Float, Float) {
        let v = SIMD4(a * c, a * d, b * c, b * d)
        return (v.min(), v.max())
    }

    private static func values<T>(_ step: ModelScene.Channel<T>?, _ linear: ModelScene.Channel<T>?,
                                  _ dense: ModelScene.Channel<T>, joint: Int, count: Int) -> [T] {
        for channel in [step, linear] {
            if let channel, !channel.times.isEmpty, channel.values.count >= channel.times.count {
                return Array(channel.values.prefix(channel.times.count))
            }
        }
        guard dense.values.count >= dense.times.count * count else { return [] }
        return dense.times.indices.map { dense.values[$0 * count + joint] }
    }

    private static func range(_ values: [SIMD3<Float>], rest: SIMD3<Float>) -> Box {
        guard let first = values.first else { return Box(rest) }
        return values.dropFirst().reduce(into: Box(first)) { $0.include(Box($1)) }
    }

    /// Each rotation-matrix entry along a shortest quaternion arc is A cos(x) +
    /// B sin(x) + C. Include its interior extrema as well as both endpoints.
    private static func rotation(_ values: [simd_quatf], rest: simd_quatf, step: Bool) -> Transform {
        let quaternions = values.isEmpty ? [rest] : values
        var result = Transform(simd_float4x4(simd_normalize(quaternions[0])))
        for index in quaternions.indices.dropFirst() {
            let q0 = simd_normalize(quaternions[index - 1])
            var q1 = simd_normalize(quaternions[index])
            if simd_dot(q0.vector, q1.vector) < 0 { q1 = simd_quatf(vector: -q1.vector) }
            result.include(Transform(simd_float4x4(q1)))
            if step { continue }
            let delta = q0.inverse * q1
            let sine = simd_length(delta.imag)
            guard sine > 1e-7 else { continue }
            let axis = delta.imag / sine, angle = 2 * atan2(sine, delta.real)
            let r0 = simd_float3x3(q0)
            let outer = simd_float3x3(axis * axis.x, axis * axis.y, axis * axis.z)
            let cross = simd_float3x3(simd_cross(axis, SIMD3(1,0,0)), simd_cross(axis, SIMD3(0,1,0)), simd_cross(axis, SIMD3(0,0,1)))
            let a = r0 * (matrix_identity_float3x3 - outer), b = r0 * cross, c = r0 * outer
            for column in 0..<3 { for row in 0..<3 {
                let phase = atan2(b[column][row], a[column][row])
                for k in -1...2 {
                    let x = phase + Float(k) * .pi
                    guard x > 0, x < angle else { continue }
                    let value = a[column][row] * cos(x) + b[column][row] * sin(x) + c[column][row]
                    result.low[column][row] = min(result.low[column][row], value)
                    result.high[column][row] = max(result.high[column][row], value)
                }
            } }
        }
        return result
    }

    /// Upper bound on the linear operator norm; exact for rotations and axis scales.
    /// It prevents interval dependency from growing exponentially down a rotating rig.
    private static func norm(_ matrix: simd_float4x4) -> Float {
        let linear = simd_float3x3(SIMD3(matrix[0].x, matrix[0].y, matrix[0].z), SIMD3(matrix[1].x, matrix[1].y, matrix[1].z), SIMD3(matrix[2].x, matrix[2].y, matrix[2].z))
        let gram = linear.transpose * linear
        return sqrt(max(abs(gram[0]).sum(), max(abs(gram[1]).sum(), abs(gram[2]).sum())))
    }

    static func worldTransforms(_ skeleton: ModelScene.Skeleton, clips: [ModelScene.AnimationClip]) -> [Transform] {
        var restWorld: [simd_float4x4] = []
        for (j, joint) in skeleton.joints.enumerated() {
            if let parent = joint.parent, parent >= 0, parent < j { restWorld.append(restWorld[parent] * joint.rest) }
            else { restWorld.append(joint.rest) }
        }
        var result = restWorld.map(Transform.init)
        let count = skeleton.joints.count
        for clip in clips {
            var world: [Transform] = [], norms: [Float] = []
            world.reserveCapacity(count); norms.reserveCapacity(count)
            for (j, joint) in skeleton.joints.enumerated() {
                let t = values(clip.stepTranslations[j], clip.linearTranslations[j], clip.translations, joint: j, count: count)
                let r = values(clip.stepRotations[j], clip.linearRotations[j], clip.rotations, joint: j, count: count)
                let s = values(clip.stepScales[j], clip.linearScales[j], clip.scales, joint: j, count: count)
                var local = Transform(joint.rest), bound = norm(joint.rest)
                let hasTrack = clip.stepTranslations[j] != nil || clip.linearTranslations[j] != nil
                    || clip.stepRotations[j] != nil || clip.linearRotations[j] != nil
                    || clip.stepScales[j] != nil || clip.linearScales[j] != nil
                if !t.isEmpty || !r.isEmpty || !s.isEmpty || hasTrack {
                    let rest = joint.restComponents ?? ModelScene.Skeleton.decompose(joint.rest)
                    let translation = range(t, rest: rest.translation), scale = range(s, rest: rest.scale)
                    local = rotation(r, rest: rest.rotation, step: clip.stepRotations[j]?.heldValue(at: clip.start) != nil)
                    for c in 0..<3 { for row in 0..<3 {
                        let v = product(local.low[c][row], local.high[c][row], scale.low[c], scale.high[c])
                        local.low[c][row] = v.0; local.high[c][row] = v.1
                    } }
                    local.low[3] = SIMD4(translation.low, 1); local.high[3] = SIMD4(translation.high, 1)
                    local = Transform(joint.animationPrefix) * local
                    bound = norm(joint.animationPrefix) * max(abs(scale.low).max(), abs(scale.high).max())
                }
                if let parent = joint.parent, parent >= 0, parent < j {
                    local = world[parent] * local; bound *= norms[parent]
                }
                for c in 0..<3 { for row in 0..<3 {
                    local.low[c][row] = max(local.low[c][row], -bound)
                    local.high[c][row] = min(local.high[c][row], bound)
                } }
                world.append(local); norms.append(bound)
                result[j].include(local)
            }
        }
        return result
    }

    /// The most moments of one clip that are looked at.
    private static let mostMoments = 512

    /// Where each joint is, moment by moment: at rest, then through every clip at each of
    /// its keys and at even steps between them (a joint turning from one key to the next
    /// swings out past both, and a value that is held shows only between two keys).
    static func poses(_ skeleton: ModelScene.Skeleton, clips: [ModelScene.AnimationClip]) -> [[simd_float4x4]] {
        func world(_ locals: [simd_float4x4]) -> [simd_float4x4] {
            var world = locals
            for (j, joint) in skeleton.joints.enumerated() { if let p = joint.parent, p >= 0, p < j { world[j] = world[p] * locals[j] } }
            return world
        }
        var poses = [world(skeleton.localMatrices())]
        for clip in clips {
            var moments = Set((0...64).map { clip.duration * Float($0) / 64 })
            func keys(_ times: [Float]) { for time in times where time >= clip.start && time <= clip.end { moments.insert(time - clip.start) } }
            keys(clip.translations.times); keys(clip.rotations.times); keys(clip.scales.times)
            for channel in clip.stepTranslations.values { keys(channel.times) }
            for channel in clip.linearTranslations.values { keys(channel.times) }
            for channel in clip.stepRotations.values { keys(channel.times) }
            for channel in clip.linearRotations.values { keys(channel.times) }
            for channel in clip.stepScales.values { keys(channel.times) }
            for channel in clip.linearScales.values { keys(channel.times) }
            var times = moments.sorted()
            if times.count * 2 <= mostMoments {
                times += zip(times, times.dropFirst()).map { ($0 + $1) / 2 }
            } else if times.count > mostMoments {
                times = (0..<mostMoments).map { times[$0 * (times.count - 1) / (mostMoments - 1)] }
            }
            for time in times { poses.append(world(skeleton.localMatrices(clip: clip, time: time))) }
        }
        return poses
    }

    static func framing(parts: [GPUScene.Part], skeletons: [ModelScene.Skeleton], clips: [ModelScene.AnimationClip]) -> Framing {
        var matrices: [Int: [Transform]] = [:]
        var moments: [Int: [[simd_float4x4]]] = [:]
        var bounds = Box(low: SIMD3(repeating: .infinity), high: SIMD3(repeating: -.infinity))
        for part in parts {
            let placement = Transform(part.model)
            guard let skin = part.skin else {
                let floats = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
                part.forEachDrawnVertex { i in
                    bounds.include(placement.apply(Box(SIMD3(floats[i * 6], floats[i * 6 + 1], floats[i * 6 + 2]))))
                }
                continue
            }
            if matrices[skin.skeleton] == nil {
                matrices[skin.skeleton] = worldTransforms(skeletons[skin.skeleton], clips: clips.filter { $0.skeleton == skin.skeleton })
            }
            guard let transforms = matrices[skin.skeleton], !transforms.isEmpty else { continue }
            let shape = skin.morph?.base ?? skin.rest
            var morphRanges: [(Float, Float)] = []
            if let morph = skin.morph {
                morphRanges = morph.defaults.map { let w = min(8, max(-8, $0)); return (w, w) }
                for clip in clips {
                    guard let channel = clip.morphs.first(where: { $0.mesh == morph.mesh }), channel.targetCount > 0,
                          !channel.times.isEmpty, channel.values.count >= channel.times.count * channel.targetCount else { continue }
                    for target in morph.targets.indices {
                        // Missing targets are zeroed by show(_:on:).
                        if target >= channel.targetCount {
                            morphRanges[target].0 = min(morphRanges[target].0, 0)
                            morphRanges[target].1 = max(morphRanges[target].1, 0)
                            continue
                        }
                        for key in channel.times.indices {
                            let value = channel.values[key * channel.targetCount + target]
                            let w = value.isFinite ? min(8, max(-8, value)) : 0
                            morphRanges[target].0 = min(morphRanges[target].0, w)
                            morphRanges[target].1 = max(morphRanges[target].1, w)
                        }
                    }
                }
            }
            // Two answers. The wide one takes every joint's widest turn at once: nothing
            // gets outside it, and it grows with the length of the chain. The close one
            // carries the box of what each joint holds through the poses the clips take.
            // What is framed is the close one with a little to spare, inside the wide one.
            var wide = Box(low: SIMD3(repeating: .infinity), high: SIMD3(repeating: -.infinity))
            var held = [Box?](repeating: nil, count: transforms.count)
            // A corner goes where its joints carry it only while its weights add up to one.
            var blended = true
            part.forEachDrawnVertex { i in
                var input = Box(SIMD3(shape[i * 6], shape[i * 6 + 1], shape[i * 6 + 2]))
                if let morph = skin.morph {
                    for (target, range) in morphRanges.enumerated() {
                        let delta = morph.targets[target]
                        let p = SIMD3(delta[i * 6], delta[i * 6 + 1], delta[i * 6 + 2])
                        input.includeDisplacement(p, range: range)
                    }
                }
                var posed = Box(.zero)
                for k in 0..<4 where k == 0 || skin.weights[i][k] > 0 {
                    let joint = min(Int(skin.joints[i][k]), transforms.count - 1)
                    // Bind first, before applying the varying transform. Combining these
                    // matrices as intervals loses the shared rotation of pivot offsets.
                    let bound = Transform(skeletons[skin.skeleton].joints[joint].inverseBind).apply(input)
                    posed.add(transforms[joint].apply(bound), weight: skin.weights[i][k])
                    if held[joint] == nil { held[joint] = bound } else { held[joint]!.include(bound) }
                }
                let weights = skin.weights[i]
                if abs(weights[0] + max(0, weights[1]) + max(0, weights[2]) + max(0, weights[3]) - 1) > 0.01 { blended = false }
                let world = placement.apply(posed)
                if (0..<3).allSatisfy({ world.low[$0].isFinite && world.high[$0].isFinite }) { wide.include(world) }
            }
            guard wide.low.x <= wide.high.x else { continue }
            if moments[skin.skeleton] == nil {
                moments[skin.skeleton] = poses(skeletons[skin.skeleton], clips: clips.filter { $0.skeleton == skin.skeleton })
            }
            var close = Box(low: SIMD3(repeating: .infinity), high: SIMD3(repeating: -.infinity))
            for pose in moments[skin.skeleton] ?? [] where pose.count == held.count {
                for (joint, box) in held.enumerated() { if let box { close.include(placement.apply(Transform(pose[joint]).apply(box))) } }
            }
            guard blended, (0..<3).allSatisfy({ close.low[$0].isFinite && close.high[$0].isFinite }) else { bounds.include(wide); continue }
            let spare = simd_reduce_max(close.high - close.low) * 0.02
            bounds.include(Box(low: simd_max(wide.low, close.low - spare), high: simd_min(wide.high, close.high + spare)))
        }
        return bounds.low.x.isFinite && bounds.high.x.isFinite ? Framing(min: bounds.low, max: bounds.high) : .unit
    }
}

private extension AnimationBounds.Box {
    mutating func includeDisplacement(_ delta: SIMD3<Float>, range: (Float, Float)) {
        low += simd_min(delta * range.0, delta * range.1)
        high += simd_max(delta * range.0, delta * range.1)
    }
}
