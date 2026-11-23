import simd

extension ModelScene {
    /// Joints that move the vertices bound to them.
    public struct Skeleton: Sendable {
        public struct Joint: Sendable {
            public var name: String
            /// Index into `joints`, lower than this joint's own; nil for a root.
            public var parent: Int?
            /// Placement relative to the parent when nothing is animated.
            public var rest: simd_float4x4
            /// Authored components, before any coordinate conversion. Matrix decomposition
            /// cannot recover which scale axes were negative.
            public var restComponents: (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)?
            /// Coordinate conversion applied after composing animated components.
            public var animationPrefix = matrix_identity_float4x4
            /// Takes a point from the skeleton's space, in the pose the mesh was bound in,
            /// into this joint's space.
            public var inverseBind: simd_float4x4

            public init(name: String = "", parent: Int? = nil, rest: simd_float4x4 = matrix_identity_float4x4, inverseBind: simd_float4x4 = matrix_identity_float4x4) {
                self.name = name; self.parent = parent; self.rest = rest; self.inverseBind = inverseBind
            }
        }

        public var joints: [Joint]
        /// The node that places the skeleton (and with it the skinned meshes) in the scene.
        public var node: Int?

        public init(joints: [Joint] = [], node: Int? = nil) { self.joints = joints; self.node = node }
    }

    /// How a mesh part follows a skeleton: up to four joints per vertex.
    public struct Skin: Sendable {
        /// Index into `ModelScene.skeletons`.
        public var skeleton: Int
        /// Per vertex, indices into the skeleton's joints; unused slots have weight 0.
        public var joints: [SIMD4<UInt16>]
        public var weights: [SIMD4<Float>]
        /// Takes the part's vertices into the skeleton's space, in the bind pose.
        public var geometryBind: simd_float4x4
        /// Scene-node joint whose global transform defines the front-face winding.
        /// Nil leaves winding to the skeleton's placement node.
        public var windingJoint: Int?

        public init(skeleton: Int, joints: [SIMD4<UInt16>] = [], weights: [SIMD4<Float>] = [], geometryBind: simd_float4x4 = matrix_identity_float4x4) {
            self.skeleton = skeleton; self.joints = joints; self.weights = weights; self.geometryBind = geometryBind
        }
    }

    /// Values over time for every joint of a skeleton: `values[key * jointCount + joint]`.
    /// Empty when the clip leaves this property at rest.
    public struct Channel<Value: Sendable>: Sendable {
        public var times: [Float]
        public var values: [Value]

        public init(times: [Float] = [], values: [Value] = []) { self.times = times; self.values = values }

        /// A single-joint STEP track holds its preceding authored key.
        public func heldValue(at time: Float) -> Value? {
            guard values.count >= times.count, let (key, _, _) = bracket(time) else { return nil }
            return values[key]
        }

        func interpolatedValue(at time: Float, interpolate: (Value, Value, Float) -> Value) -> Value? {
            guard values.count >= times.count, let (a, b, f) = bracket(time) else { return nil }
            return interpolate(values[a], values[b], f)
        }

        /// The two keys around `time` and how far between them it lies.
        func bracket(_ time: Float) -> (Int, Int, Float)? {
            guard !times.isEmpty else { return nil }
            if time <= times[0] { return (0, 0, 0) }
            if time >= times[times.count - 1] { return (times.count - 1, times.count - 1, 0) }
            var lo = 0, hi = times.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if times[mid] <= time { lo = mid } else { hi = mid }
            }
            let span = times[hi] - times[lo]
            return (lo, hi, span > 0 ? (time - times[lo]) / span : 0)
        }
    }

    /// Another shape of a mesh part: what it adds to each vertex's position and, when the
    /// file says, to its normal (`normals` is empty otherwise).
    public struct MorphTarget: Sendable {
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]

        public init(positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []) { self.positions = positions; self.normals = normals }
    }

    /// The morph weights of one mesh over time: `values[key * targetCount + target]`.
    public struct MorphChannel: Sendable {
        /// Index into `ModelScene.meshes`.
        public var mesh: Int
        public var targetCount: Int
        public var times: [Float]
        public var values: [Float]

        public var step: Bool

        public init(mesh: Int, targetCount: Int, times: [Float] = [], values: [Float] = [], step: Bool = false) {
            self.mesh = mesh; self.targetCount = targetCount; self.times = times; self.values = values; self.step = step
        }

        /// The weights `time` seconds from the clip's start; nil when the channel is empty or damaged.
        public func weights(at time: Float) -> [Float]? {
            guard targetCount > 0, !times.isEmpty, values.count >= times.count * targetCount else { return nil }
            var lo = 0, hi = times.count - 1
            if time <= times[0] { hi = 0 } else if time >= times[hi] { lo = hi } else {
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if times[mid] <= time { lo = mid } else { hi = mid }
                }
            }
            let span = times[hi] - times[lo]
            let f = !step && span > 0 ? min(1, max(0, (time - times[lo]) / span)) : 0
            return (0..<targetCount).map { values[lo * targetCount + $0] + (values[hi * targetCount + $0] - values[lo * targetCount + $0]) * f }
        }
    }

    /// One animation of one skeleton.
    public struct AnimationClip: Sendable {
        public var name: String
        /// Index into `ModelScene.skeletons`.
        public var skeleton: Int
        /// Seconds; the clip runs from `start` to `end`.
        public var start: Float
        public var end: Float
        public var translations: Channel<SIMD3<Float>>
        public var rotations: Channel<simd_quatf>
        public var scales: Channel<SIMD3<Float>>
        /// STEP tracks retain authored times independently for each joint.
        /// They override the corresponding sampled property for that joint.
        public var stepTranslations: [Int: Channel<SIMD3<Float>>] = [:]
        public var stepRotations: [Int: Channel<simd_quatf>] = [:]
        public var stepScales: [Int: Channel<SIMD3<Float>>] = [:]
        /// Authored LINEAR tracks retain each joint's own key times, independently of
        /// the sampled channels used by other importers and cubic approximations.
        public var linearTranslations: [Int: Channel<SIMD3<Float>>] = [:]
        public var linearRotations: [Int: Channel<simd_quatf>] = [:]
        public var linearScales: [Int: Channel<SIMD3<Float>>] = [:]
        /// The morph weights the clip animates, by mesh.
        public var morphs: [MorphChannel] = []

        public init(name: String = "", skeleton: Int, start: Float = 0, end: Float = 0,
                    translations: Channel<SIMD3<Float>> = .init(), rotations: Channel<simd_quatf> = .init(), scales: Channel<SIMD3<Float>> = .init()) {
            self.name = name; self.skeleton = skeleton; self.start = start; self.end = end
            self.translations = translations; self.rotations = rotations; self.scales = scales
        }

        public var duration: Float { max(0, end - start) }
    }
}

extension ModelScene.Skeleton {
    /// For each joint, the matrix that moves a bound point (in the skeleton's space) to
    /// where the joint carries it: in the rest pose when `clip` is nil, otherwise at `time`
    /// seconds into the clip.
    public func skinMatrices(clip: ModelScene.AnimationClip? = nil, time: Float = 0) -> [simd_float4x4] {
        skinMatrices(locals: localMatrices(clip: clip, time: time))
    }

    /// The same from each joint's placement in its parent (as `localMatrices` gives them,
    /// or as something else, the springs, has changed them).
    public func skinMatrices(locals: [simd_float4x4]) -> [simd_float4x4] {
        let count = joints.count
        guard locals.count == count else { return skinMatrices(locals: joints.map(\.rest)) }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: count)
        for j in 0..<count {
            // Parents come before their children; anything else is treated as a root.
            if let p = joints[j].parent, p >= 0, p < j { world[j] = world[p] * locals[j] } else { world[j] = locals[j] }
        }
        return (0..<count).map { world[$0] * joints[$0].inverseBind }
    }

    /// Each joint's placement in its parent: at rest when `clip` is nil, otherwise at
    /// `time` seconds into the clip.
    public func localMatrices(clip: ModelScene.AnimationClip? = nil, time: Float = 0) -> [simd_float4x4] {
        let count = joints.count
        var locals = [simd_float4x4](repeating: matrix_identity_float4x4, count: count)
        let at = (clip?.start ?? 0) + time
        let t = clip.flatMap { $0.translations.values.count >= $0.translations.times.count * count ? $0.translations.bracket(at) : nil }
        let r = clip.flatMap { $0.rotations.values.count >= $0.rotations.times.count * count ? $0.rotations.bracket(at) : nil }
        let s = clip.flatMap { $0.scales.values.count >= $0.scales.times.count * count ? $0.scales.bracket(at) : nil }
        for j in 0..<count {
            var local = joints[j].rest
            if let clip, t != nil || r != nil || s != nil || clip.stepTranslations[j] != nil || clip.stepRotations[j] != nil || clip.stepScales[j] != nil
                || clip.linearTranslations[j] != nil || clip.linearRotations[j] != nil || clip.linearScales[j] != nil {
                // What the clip does not animate is taken from the rest placement.
                let rest = joints[j].restComponents ?? Self.decompose(local)
                var translation = rest.translation, rotation = rest.rotation, scale = rest.scale
                if let (a, b, f) = t { translation = simd_mix(clip.translations.values[a * count + j], clip.translations.values[b * count + j], SIMD3(repeating: f)) }
                if let (a, b, f) = r { rotation = simd_slerp(clip.rotations.values[a * count + j], clip.rotations.values[b * count + j], f) }
                if let (a, b, f) = s { scale = simd_mix(clip.scales.values[a * count + j], clip.scales.values[b * count + j], SIMD3(repeating: f)) }
                translation = clip.linearTranslations[j]?.interpolatedValue(at: at) { simd_mix($0, $1, SIMD3(repeating: $2)) } ?? translation
                rotation = clip.linearRotations[j]?.interpolatedValue(at: at, interpolate: simd_slerp) ?? rotation
                scale = clip.linearScales[j]?.interpolatedValue(at: at) { simd_mix($0, $1, SIMD3(repeating: $2)) } ?? scale
                translation = clip.stepTranslations[j]?.heldValue(at: at) ?? translation
                rotation = clip.stepRotations[j]?.heldValue(at: at) ?? rotation
                scale = clip.stepScales[j]?.heldValue(at: at) ?? scale
                local = joints[j].animationPrefix * Self.compose(translation, rotation, scale)
            }
            locals[j] = local
        }
        return locals
    }

    public static func compose(_ t: SIMD3<Float>, _ r: simd_quatf, _ s: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(simd_normalize(r))
        m.columns.0 *= s.x; m.columns.1 *= s.y; m.columns.2 *= s.z
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    public static func decompose(_ m: simd_float4x4) -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        let x = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), y = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), z = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        var scale = SIMD3(simd_length(x), simd_length(y), simd_length(z))
        if simd_dot(simd_cross(x, y), z) < 0 { scale.x = -scale.x }
        let safe = SIMD3(scale.x == 0 ? 1 : scale.x, scale.y == 0 ? 1 : scale.y, scale.z == 0 ? 1 : scale.z)
        let rotation = simd_quatf(simd_float3x3(x / safe.x, y / safe.y, z / safe.z))
        return (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), rotation, scale)
    }
}
