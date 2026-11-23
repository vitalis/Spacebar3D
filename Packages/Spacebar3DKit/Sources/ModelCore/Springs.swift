import simd

extension ModelScene {
    /// Chains of joints that trail behind the skeleton and settle under gravity: hair,
    /// skirts, tails (VRM's spring bones). The simulation is `SpringSimulator`.
    public struct SpringSystem: Sendable {
        /// A ball, or with `tail` a capsule, that spring joints are kept out of; it moves
        /// with a joint of the skeleton.
        public struct Collider: Sendable {
            public var joint: Int
            public var offset: SIMD3<Float>
            public var tail: SIMD3<Float>?
            public var radius: Float

            public init(joint: Int, offset: SIMD3<Float> = .zero, tail: SIMD3<Float>? = nil, radius: Float = 0) {
                self.joint = joint; self.offset = offset; self.tail = tail; self.radius = radius
            }
        }

        /// One joint of a chain: it turns so that its tail (a point in its own space, where
        /// the next joint sits) follows where the simulation puts it.
        public struct Joint: Sendable {
            public var joint: Int
            public var tail: SIMD3<Float>
            public var hitRadius: Float
            public var stiffness: Float
            public var gravityPower: Float
            public var gravityDirection: SIMD3<Float>
            public var drag: Float
            /// Indices into `colliders`.
            public var colliders: [Int]

            public init(joint: Int, tail: SIMD3<Float>, hitRadius: Float = 0, stiffness: Float = 1, gravityPower: Float = 0,
                        gravityDirection: SIMD3<Float> = SIMD3(0, -1, 0), drag: Float = 0.5, colliders: [Int] = []) {
                self.joint = joint; self.tail = tail; self.hitRadius = hitRadius; self.stiffness = stiffness
                self.gravityPower = gravityPower; self.gravityDirection = gravityDirection; self.drag = drag; self.colliders = colliders
            }
        }

        /// Index into `ModelScene.skeletons`.
        public var skeleton: Int
        public var colliders: [Collider]
        public var joints: [Joint]

        public init(skeleton: Int, colliders: [Collider] = [], joints: [Joint] = []) {
            self.skeleton = skeleton; self.colliders = colliders; self.joints = joints
        }
    }
}

/// Moves a skeleton's spring joints, one small step of time after another (the algorithm
/// of VRM 1.0's spring bones, in the scene's space). Each joint remembers where its tail
/// was; the tail keeps some of its motion, is pulled back towards where the skeleton would
/// have it and down by gravity, stays at the bone's length from its head, and is pushed out
/// of the colliders. The joint then turns to point at it.
public struct SpringSimulator: Sendable {
    private struct State {
        var joint: ModelScene.SpringSystem.Joint
        var axis: SIMD3<Float>
        var length: Float
        var current: SIMD3<Float>
        var previous: SIMD3<Float>
    }

    private let parents: [Int?]
    private let colliders: [ModelScene.SpringSystem.Collider]
    private var states: [State] = []
    /// For each joint of the skeleton, its place in `states`.
    private var stateOf: [Int: Int] = [:]

    public static let maxJoints = 20_000

    public var isEmpty: Bool { states.isEmpty }

    /// Starts with every chain where the skeleton's rest pose has it.
    public init(_ system: ModelScene.SpringSystem, skeleton: ModelScene.Skeleton) {
        parents = skeleton.joints.map(\.parent)
        let count = skeleton.joints.count
        colliders = system.colliders.filter { $0.joint >= 0 && $0.joint < count && $0.radius.isFinite && $0.radius >= 0 }
            .count == system.colliders.count ? system.colliders : []
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: count)
        for j in 0..<count {
            if let p = skeleton.joints[j].parent, p >= 0, p < j { world[j] = world[p] * skeleton.joints[j].rest } else { world[j] = skeleton.joints[j].rest }
        }
        for joint in system.joints.prefix(Self.maxJoints) where joint.joint >= 0 && joint.joint < count && stateOf[joint.joint] == nil {
            let tail = world[joint.joint] * SIMD4(joint.tail, 1)
            let head = world[joint.joint].columns.3
            let length = simd_length(SIMD3(tail.x - head.x, tail.y - head.y, tail.z - head.z))
            guard length > 1e-6, length.isFinite, simd_length(joint.tail) > 1e-6 else { continue }
            var kept = joint
            kept.colliders = joint.colliders.filter { colliders.indices.contains($0) }
            if !(kept.stiffness.isFinite && kept.drag.isFinite && kept.gravityPower.isFinite && kept.hitRadius.isFinite) { continue }
            kept.drag = min(1, max(0, kept.drag))
            let direction = simd_length(kept.gravityDirection)
            kept.gravityDirection = direction > 1e-6 && direction.isFinite ? kept.gravityDirection / direction : SIMD3(0, -1, 0)
            stateOf[joint.joint] = states.count
            let at = SIMD3(tail.x, tail.y, tail.z)
            states.append(State(joint: kept, axis: simd_normalize(joint.tail), length: length, current: at, previous: at))
        }
    }

    /// The springs are moved in steps of this length, however far apart the pictures are:
    /// a tail keeps a share of its motion each step, so steps of the pictures' own length
    /// had it swing differently on a screen that shows more of them, or fewer.
    public static let tick: Float = 1.0 / 60
    /// Time passed that has not been stepped through yet.
    private var owed: Float = 0

    /// Advances the springs by `dt` seconds. `locals` holds every joint's placement in its
    /// parent as the skeleton has it now (at rest, or in a clip); the spring joints' turns
    /// are replaced. With no time passed, or not yet a step's worth, the chains are only
    /// put where they were left. Returns how far the fastest tail moved in a step, as a
    /// share of its bone's length.
    public mutating func step(_ dt: Float, locals: inout [simd_float4x4]) -> Float {
        guard !states.isEmpty, locals.count == parents.count, dt >= 0, dt.isFinite else { return 0 }
        owed += dt
        // A picture that comes a little early still gets its step, so that a screen at
        // sixty a second is not left without one now and given two the next time. No
        // more than four at once: a long gap is not caught up with.
        let steps = dt > 0 ? min(Int((owed + Self.tick / 4) / Self.tick), 4) : 0
        guard steps > 0 else { return move(0, locals: &locals) }
        owed = min(owed - Float(steps) * Self.tick, Self.tick)
        let given = locals
        var fastest: Float = 0
        for _ in 0..<steps {
            locals = given
            fastest = max(fastest, move(Self.tick, locals: &locals))
        }
        return fastest
    }

    private mutating func move(_ dt: Float, locals: inout [simd_float4x4]) -> Float {
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: locals.count)
        var fastest: Float = 0
        for j in 0..<locals.count {
            let parentWorld = parents[j].flatMap { $0 >= 0 && $0 < j ? world[$0] : nil } ?? matrix_identity_float4x4
            world[j] = parentWorld * locals[j]
            guard let index = stateOf[j] else { continue }
            var s = states[index]
            let rest = ModelScene.Skeleton.decompose(locals[j])
            let standing = parentWorld * locals[j]
            let head = SIMD3(standing.columns.3.x, standing.columns.3.y, standing.columns.3.z)

            let inertia = dt > 0 ? (s.current - s.previous) * (1 - s.joint.drag) : .zero
            let parentTurn = ModelScene.Skeleton.decompose(parentWorld).rotation
            let stiffness = simd_act(parentTurn * rest.rotation, s.axis) * (s.joint.stiffness * dt)
            let gravity = s.joint.gravityDirection * (s.joint.gravityPower * dt)
            var next = s.current + inertia + stiffness + gravity
            next = Self.atLength(next, from: head, s.length, fallback: s.current)

            for c in s.joint.colliders {
                let collider = colliders[c]
                // Earlier joints have their current pose, including spring motion. A later
                // collider follows its local chain back to an already computed ancestor.
                // This also handles a collider on this joint, before its new spring turn.
                var at = collider.joint
                var place = matrix_identity_float4x4
                while at > j {
                    place = locals[at] * place
                    guard let parent = parents[at], parent >= 0, parent < at else { at = -1; break }
                    at = parent
                }
                if at >= 0 { place = world[at] * place }
                var centre = Self.point(place, collider.offset)
                if let tail = collider.tail {
                    let end = Self.point(place, tail)
                    let axis = end - centre, squared = simd_length_squared(axis)
                    centre += axis * (squared > 0 ? max(0, min(1, simd_dot(next - centre, axis) / squared)) : 0)
                }
                let away = next - centre, distance = simd_length(away)
                let inside = collider.radius + s.joint.hitRadius - distance
                if inside > 0, distance > 1e-8 {
                    next += away / distance * inside
                    next = Self.atLength(next, from: head, s.length, fallback: s.current)
                }
            }
            if !(next.x.isFinite && next.y.isFinite && next.z.isFinite) { next = s.current }
            fastest = max(fastest, simd_length(next - s.current) / s.length)
            if dt > 0 { s.previous = s.current }
            s.current = next
            states[index] = s

            let inverse = simd_inverse(standing)
            let towards = Self.point(inverse, next)
            if simd_length(towards) > 1e-8, inverse.columns.0.x.isFinite {
                locals[j] = ModelScene.Skeleton.compose(rest.translation, rest.rotation * simd_quatf(from: s.axis, to: simd_normalize(towards)), rest.scale)
            }
            world[j] = parentWorld * locals[j]
        }
        return fastest
    }

    private static func point(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    private static func atLength(_ p: SIMD3<Float>, from head: SIMD3<Float>, _ length: Float, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let d = p - head, l = simd_length(d)
        return l > 1e-8 && l.isFinite ? head + d / l * length : fallback
    }
}
