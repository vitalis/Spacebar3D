import Foundation
import ModelCore
import simd

/// Skins and animations.
///
/// The scene model moves vertices with one kind of thing, a skeleton, so everything in the
/// file that moves is brought to one skeleton:
///
/// - Every node of the scene is a joint, with the node's parent and placement.
/// - Every joint of a skin is one more joint under the node it names, carrying that
///   skin's inverse bind matrix (a node can be a joint of two skins with different ones).
/// - A mesh under an animated node that has no skin is bound whole to its node's joint.
///
/// An animation then is a clip of that skeleton. The file's samplers each have their own
/// key times and three ways of going from key to key. Cubic tracks are sampled at a
/// steady rate; LINEAR and STEP tracks retain their authored keys.
extension Document {
    static let samplesPerSecond: Float = 30
    static let maxKeys = 3600
    /// Keys times joints a clip may hold for each of translation, rotation and scale.
    static let maxClipValues = 4_000_000
    static let maxClips = 256

    mutating func animate(nodes: [Object], source: [Int]) throws {
        let skins = root["skins"] as? [Object] ?? []
        let animations = root["animations"] as? [Object] ?? []
        let usesSkin = source.contains { Self.int(nodes[$0]["skin"]) != nil && Self.int(nodes[$0]["mesh"]) != nil }
        // Other shapes are shown through a skin too (see `ModelScene.MeshPart.morphTargets`).
        let morphs = out.meshes.contains { $0.parts.contains { !$0.morphTargets.isEmpty } }
        guard usesSkin || morphs || !animations.isEmpty else { return }

        var sceneNode: [Int: Int] = [:]
        for (i, n) in source.enumerated() { sceneNode[n] = i }

        // Which nodes an animation moves, and everything below them.
        var moved = [Bool](repeating: false, count: source.count)
        for animation in animations {
            for channel in animation["channels"] as? [Object] ?? [] {
                guard let target = channel["target"] as? Object, let node = Self.int(target["node"]), let i = sceneNode[node],
                      let path = target["path"] as? String, ["translation", "rotation", "scale"].contains(path) else { continue }
                moved[i] = true
            }
        }
        // Parents come before their children in the scene's nodes.
        for i in source.indices { if let p = out.nodes[i].parent, moved[p] { moved[i] = true } }

        let facesAway = (root["extensions"] as? Object)?["VRM"] != nil
        var joints = source.indices.map { i -> ModelScene.Skeleton.Joint in
            var joint = ModelScene.Skeleton.Joint(name: out.nodes[i].name, parent: out.nodes[i].parent, rest: out.nodes[i].transform)
            let node = nodes[source[i]]
            if node["matrix"] == nil {
                let t = Self.floats(node["translation"], count: 3) ?? [0, 0, 0]
                let r = Self.floats(node["rotation"], count: 4) ?? [0, 0, 0, 1]
                let s = Self.floats(node["scale"], count: 3) ?? [1, 1, 1]
                let q = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
                joint.restComponents = (SIMD3(t[0], t[1], t[2]), simd_length(q.vector) > 0 ? simd_normalize(q) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), SIMD3(s[0], s[1], s[2]))
                if joint.parent == nil, facesAway { joint.animationPrefix = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))) }
            }
            return joint
        }
        // For each skin, where its joints are in the skeleton.
        var skinJoints: [Int: [UInt16]] = [:]
        func jointsOfSkin(_ index: Int) throws -> [UInt16]? {
            if let known = skinJoints[index] { return known }
            guard skins.indices.contains(index) else { return nil }
            let named = (skins[index]["joints"] as? [Any] ?? []).map { Self.int($0).flatMap { sceneNode[$0] } }
            guard !named.isEmpty, joints.count + named.count <= 65535 else { return nil }
            var inverse: [Float] = []
            if let accessor = Self.int(skins[index]["inverseBindMatrices"]) {
                let (values, _, count) = try floats(accessor, components: 16)
                if count >= named.count { inverse = values }
            }
            var made: [UInt16] = []
            for (k, node) in named.enumerated() {
                var bind = matrix_identity_float4x4
                if !inverse.isEmpty {
                    let m = Array(inverse[(k * 16)..<(k * 16 + 16)])
                    bind = simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
                }
                // A joint outside the scene stands still at the scene's origin.
                joints.append(ModelScene.Skeleton.Joint(name: node.map { out.nodes[$0].name } ?? "", parent: node, inverseBind: bind))
                made.append(UInt16(joints.count - 1))
            }
            skinJoints[index] = made
            return made
        }

        func windingJoint(of index: Int) -> Int? {
            guard skins.indices.contains(index) else { return nil }
            if let node = Self.int(skins[index]["skeleton"]), let joint = sceneNode[node] { return joint }
            let named = (skins[index]["joints"] as? [Any] ?? []).compactMap { Self.int($0).flatMap { sceneNode[$0] } }
            func ancestors(_ node: Int) -> [Int] {
                var path = [node], at = node
                while let parent = out.nodes[at].parent { path.append(parent); at = parent }
                return path
            }
            guard let first = named.first else { return nil }
            var common = Set(ancestors(first))
            for node in named.dropFirst() { common.formIntersection(ancestors(node)) }
            return ancestors(first).first { common.contains($0) }
        }

        // Give the meshes that move a skin of their own (a mesh can stand in several places).
        var changed = false
        for i in source.indices {
            // (A skeleton's bones are a mesh the file does not have.)
            guard let shared = out.nodes[i].mesh else { continue }
            var mesh = out.meshes[shared]
            let bound = Self.int(nodes[source[i]]["mesh"]).flatMap { influences[$0] } ?? []
            var skinned = false
            if let skinIndex = Self.int(nodes[source[i]]["skin"]), let map = try jointsOfSkin(skinIndex) {
                for p in mesh.parts.indices {
                    guard bound.indices.contains(p), let influence = bound[p], influence.joints.count == mesh.parts[p].positions.count else { continue }
                    var skin = ModelScene.Skin(skeleton: 0)
                    skin.windingJoint = windingJoint(of: skinIndex)
                    skin.joints.reserveCapacity(influence.joints.count)
                    skin.weights.reserveCapacity(influence.joints.count)
                    for v in influence.joints.indices {
                        var w = simd_max(influence.weights[v], SIMD4(repeating: 0))
                        if !(w.x.isFinite && w.y.isFinite && w.z.isFinite && w.w.isFinite) { w = SIMD4(1, 0, 0, 0) }
                        let sum = w.x + w.y + w.z + w.w
                        w = sum > 0 ? w / sum : SIMD4(1, 0, 0, 0)
                        let j = influence.joints[v]
                        func at(_ k: UInt16) -> UInt16 { Int(k) < map.count ? map[Int(k)] : map[0] }
                        skin.joints.append(SIMD4(at(j.x), at(j.y), at(j.z), at(j.w)))
                        skin.weights.append(w)
                    }
                    mesh.parts[p].skin = skin
                    skinned = true
                }
            }
            let shaped = mesh.parts.contains { !$0.morphTargets.isEmpty }
            // The weights a node sets replace its mesh's own.
            if shaped, let own = nodes[source[i]]["weights"] as? [Any] { mesh.morphWeights = own.map { Self.float($0) ?? 0 } }
            if !skinned, moved[i] || shaped, joints.count <= 65535 {
                // No skin, but the node moves or the mesh changes shape: the whole mesh follows its node.
                for p in mesh.parts.indices {
                    let count = mesh.parts[p].positions.count
                    mesh.parts[p].skin = ModelScene.Skin(skeleton: 0, joints: [SIMD4<UInt16>](repeating: SIMD4(UInt16(i), 0, 0, 0), count: count),
                                                         weights: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: count))
                    mesh.parts[p].skin?.windingJoint = i
                }
                skinned = true
            }
            if skinned {
                out.meshes.append(mesh)
                out.nodes[i].mesh = out.meshes.count - 1
                changed = true
            }
        }
        guard changed else { return }
        out.skeletons = [ModelScene.Skeleton(joints: joints, node: nil)]
        out.springs = springs(nodes: nodes, source: source, sceneNode: sceneNode)

        for animation in animations.prefix(Self.maxClips) {
            if let clip = try clip(animation, joints: joints, sceneNode: sceneNode) { out.clips.append(clip) }
        }
    }

    // MARK: Clips

    /// One of the file's samplers: values at key times, and how to go between keys.
    private struct Track {
        var joint: Int
        var times: [Float]
        var values: [Float]
        var components: Int
        var cubic: Bool
        var step: Bool

        /// The value at `time`, `components` numbers.
        func sample(_ time: Float, rotation: Bool) -> [Float] {
            let n = components, width = cubic ? n * 3 : n
            func key(_ k: Int) -> ArraySlice<Float> { values[(k * width + (cubic ? n : 0))..<(k * width + (cubic ? n : 0) + n)] }
            guard times.count > 1, time > times[0] else { return Array(key(0)) }
            guard time < times[times.count - 1] else { return Array(key(times.count - 1)) }
            var lo = 0, hi = times.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if times[mid] <= time { lo = mid } else { hi = mid }
            }
            let span = times[hi] - times[lo]
            let s = span > 0 ? (time - times[lo]) / span : 0
            if step { return Array(key(lo)) }
            let a = Array(key(lo)), b = Array(key(hi))
            if cubic {
                // Hermite: each key carries the slope it is arrived at and left with.
                let leave = Array(values[(lo * width + 2 * n)..<(lo * width + 3 * n)]), arrive = Array(values[(hi * width)..<(hi * width + n)])
                let s2 = s * s, s3 = s2 * s
                return (0..<n).map { (2 * s3 - 3 * s2 + 1) * a[$0] + (s3 - 2 * s2 + s) * span * leave[$0] + (-2 * s3 + 3 * s2) * b[$0] + (s3 - s2) * span * arrive[$0] }
            }
            if rotation, n == 4 {
                let q = simd_slerp(simd_normalize(simd_quatf(ix: a[0], iy: a[1], iz: a[2], r: a[3])), simd_normalize(simd_quatf(ix: b[0], iy: b[1], iz: b[2], r: b[3])), s)
                return [q.imag.x, q.imag.y, q.imag.z, q.real]
            }
            return (0..<n).map { a[$0] + (b[$0] - a[$0]) * s }
        }
    }

    private mutating func clip(_ animation: Object, joints: [ModelScene.Skeleton.Joint], sceneNode: [Int: Int]) throws -> ModelScene.AnimationClip? {
        let samplers = animation["samplers"] as? [Object] ?? []
        var tracks: [String: [Track]] = [:]
        var end: Float = 0
        // Morph weights: for each mesh, its sampler.
        var shapes: [(mesh: Int, track: Track)] = []
        for channel in animation["channels"] as? [Object] ?? [] {
            guard let target = channel["target"] as? Object, let path = target["path"] as? String else { continue }
            if path == "weights" {
                guard let node = Self.int(target["node"]), let i = sceneNode[node], let mesh = out.nodes[i].mesh,
                      let count = out.meshes[mesh].parts.first?.morphTargets.count, count > 0,
                      let samplerIndex = Self.int(channel["sampler"]), samplers.indices.contains(samplerIndex),
                      let input = Self.int(samplers[samplerIndex]["input"]), let output = Self.int(samplers[samplerIndex]["output"]) else { continue }
                let (times, _, keys) = try floats(input, components: 1)
                let (values, _, found) = try floats(output, components: 1)
                let interpolation = samplers[samplerIndex]["interpolation"] as? String ?? "LINEAR"
                let cubic = interpolation == "CUBICSPLINE"
                guard keys > 0, found >= keys * count * (cubic ? 3 : 1), times.allSatisfy({ $0.isFinite }), values.allSatisfy({ $0.isFinite }) else { continue }
                end = max(end, times[keys - 1])
                shapes.append((mesh, Track(joint: 0, times: times, values: values, components: count, cubic: cubic, step: interpolation == "STEP")))
                continue
            }
            guard let node = Self.int(target["node"]), let joint = sceneNode[node], let components = ["translation": 3, "rotation": 4, "scale": 3][path],
                  let samplerIndex = Self.int(channel["sampler"]), samplers.indices.contains(samplerIndex),
                  let input = Self.int(samplers[samplerIndex]["input"]), let output = Self.int(samplers[samplerIndex]["output"]) else { continue }
            let (times, _, keys) = try floats(input, components: 1)
            let (values, _, found) = try floats(output, components: components)
            let interpolation = samplers[samplerIndex]["interpolation"] as? String ?? "LINEAR"
            let cubic = interpolation == "CUBICSPLINE"
            guard keys > 0, found >= keys * (cubic ? 3 : 1), times.allSatisfy({ $0.isFinite }), values.allSatisfy({ $0.isFinite }) else { continue }
            end = max(end, times[keys - 1])
            tracks[path, default: []].append(Track(joint: joint, times: times, values: values, components: components, cubic: cubic, step: interpolation == "STEP"))
        }
        guard !tracks.isEmpty || !shapes.isEmpty, end.isFinite, end >= 0 else { return nil }

        // A steady rate, lowered for a clip too long or a skeleton too large to hold at it.
        let count = joints.count
        // Clamp before converting: even a finite duration can exceed the integer range.
        let intervals = min(Float(Self.maxKeys - 1), (end * Self.samplesPerSecond).rounded(.up))
        var keys = max(2, Int(intervals) + 1)
        keys = max(2, min(keys, Self.maxClipValues / max(count, 1)))
        let times = (0..<keys).map { end * (Float($0) / Float(keys - 1)) }
        let rest = joints.map { $0.restComponents ?? ModelScene.Skeleton.decompose($0.rest) }

        var clip = ModelScene.AnimationClip(name: animation["name"] as? String ?? "", skeleton: 0, start: 0, end: end)
        // Keep authored LINEAR and STEP keys, including peaks between cubic sample times.
        var authoredValues = 0
        for (path, moving) in tracks {
            for track in moving where !track.cubic {
                authoredValues += track.times.count
                guard authoredValues <= Self.maxClipValues else { throw Failure.unsupported(L10n.text("the animation has too many authored keys")) }
                if path == "rotation" {
                    let values = stride(from: 0, to: track.times.count * 4, by: 4).map { i -> simd_quatf in
                        let q = simd_quatf(ix: track.values[i], iy: track.values[i + 1], iz: track.values[i + 2], r: track.values[i + 3])
                        return simd_length(q.vector) > 1e-8 ? simd_normalize(q) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    }
                    if track.step { clip.stepRotations[track.joint] = .init(times: track.times, values: values) }
                    else { clip.linearRotations[track.joint] = .init(times: track.times, values: values) }
                } else {
                    let values = stride(from: 0, to: track.times.count * 3, by: 3).map { SIMD3(track.values[$0], track.values[$0 + 1], track.values[$0 + 2]) }
                    let channel = ModelScene.Channel(times: track.times, values: values)
                    if path == "translation" {
                        if track.step { clip.stepTranslations[track.joint] = channel } else { clip.linearTranslations[track.joint] = channel }
                    } else {
                        if track.step { clip.stepScales[track.joint] = channel } else { clip.linearScales[track.joint] = channel }
                    }
                }
            }
        }
        if let moving = tracks["translation"]?.filter({ $0.cubic }), !moving.isEmpty {
            var values = [SIMD3<Float>](repeating: .zero, count: keys * count)
            for k in 0..<keys { for j in 0..<count { values[k * count + j] = rest[j].translation } }
            for track in moving {
                for k in 0..<keys { let v = track.sample(times[k], rotation: false); values[k * count + track.joint] = SIMD3(v[0], v[1], v[2]) }
            }
            clip.translations = .init(times: times, values: values)
        }
        if let moving = tracks["scale"]?.filter({ $0.cubic }), !moving.isEmpty {
            var values = [SIMD3<Float>](repeating: .zero, count: keys * count)
            for k in 0..<keys { for j in 0..<count { values[k * count + j] = rest[j].scale } }
            for track in moving {
                for k in 0..<keys { let v = track.sample(times[k], rotation: false); values[k * count + track.joint] = SIMD3(v[0], v[1], v[2]) }
            }
            clip.scales = .init(times: times, values: values)
        }
        if let moving = tracks["rotation"]?.filter({ $0.cubic }), !moving.isEmpty {
            var values = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: keys * count)
            for k in 0..<keys { for j in 0..<count { values[k * count + j] = rest[j].rotation } }
            for track in moving {
                for k in 0..<keys {
                    let v = track.sample(times[k], rotation: true)
                    let q = simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3])
                    values[k * count + track.joint] = simd_length(q.vector) > 1e-8 ? simd_normalize(q) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                }
            }
            clip.rotations = .init(times: times, values: values)
        }
        for (mesh, track) in shapes {
            if !track.cubic {
                authoredValues += track.times.count * track.components
                guard authoredValues <= Self.maxClipValues else { throw Failure.unsupported(L10n.text("the animation has too many authored keys")) }
                clip.morphs.append(.init(mesh: mesh, targetCount: track.components, times: track.times,
                                        values: Array(track.values.prefix(track.times.count * track.components)), step: track.step))
                continue
            }
            var channel = ModelScene.MorphChannel(mesh: mesh, targetCount: track.components, times: times)
            channel.values.reserveCapacity(keys * track.components)
            for k in 0..<keys { channel.values.append(contentsOf: track.sample(times[k], rotation: false)) }
            clip.morphs.append(channel)
        }
        return clip
    }
}
