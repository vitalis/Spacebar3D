import Foundation
import ModelCore
import simd

/// VRM's spring bones: the chains of hair, skirts and tails, and the balls and capsules
/// they are kept out of. Both the 1.0 extension and the older `secondaryAnimation` are read
/// into the same `ModelScene.SpringSystem`; every node of the scene is a joint of the one
/// skeleton with the same index (see `animate`).
extension Document {
    static let maxColliders = 4096

    /// `sceneNode` is, for each of the file's nodes in the scene, its index there.
    func springs(nodes: [Object], source: [Int], sceneNode: [Int: Int]) -> ModelScene.SpringSystem? {
        let extensions = root["extensions"] as? Object ?? [:]
        var system = ModelScene.SpringSystem(skeleton: 0)
        var world: [Int: simd_float4x4] = [:]
        func place(_ i: Int) -> simd_float4x4 {
            if let known = world[i] { return known }
            let made = out.worldTransform(of: i)
            world[i] = made
            return made
        }
        func vector(_ value: Any?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            // 1.0 writes [x, y, z]; 0.x writes {"x": , "y": , "z": }.
            if let v = Self.floats(value, count: 3) { return SIMD3(v[0], v[1], v[2]) }
            if let o = value as? Object, let x = Self.float(o["x"]), let y = Self.float(o["y"]), let z = Self.float(o["z"]) { return SIMD3(x, y, z) }
            return fallback
        }
        func number(_ value: Any?, _ fallback: Float) -> Float { Self.float(value) ?? fallback }
        /// The joint at scene node `head` whose tail is the point `tail` of the scene.
        func add(head: Int, tail: SIMD3<Float>, from j: Object, stiffness: String, hit: [Int]) {
            let local = simd_inverse(place(head)) * SIMD4(tail, 1)
            guard local.x.isFinite, local.y.isFinite, local.z.isFinite, system.joints.count < SpringSimulator.maxJoints else { return }
            system.joints.append(ModelScene.SpringSystem.Joint(
                joint: head, tail: SIMD3(local.x, local.y, local.z), hitRadius: number(j["hitRadius"], 0), stiffness: number(j[stiffness], 1),
                gravityPower: number(j["gravityPower"], 0), gravityDirection: vector(j["gravityDir"], SIMD3(0, -1, 0)),
                drag: number(j["dragForce"], 0.5), colliders: hit))
        }
        func position(_ i: Int) -> SIMD3<Float> { let c = place(i).columns.3; return SIMD3(c.x, c.y, c.z) }

        if let spring = extensions["VRMC_springBone"] as? Object {
            // A collider that cannot be used keeps its place, so that the others keep their numbers.
            var usable: [Int?] = []
            for c in (spring["colliders"] as? [Any] ?? []).prefix(Self.maxColliders) {
                let c = c as? Object ?? [:]
                let shape = c["shape"] as? Object ?? [:]
                guard let node = Self.int(c["node"]).flatMap({ sceneNode[$0] }) else { usable.append(nil); continue }
                if let sphere = shape["sphere"] as? Object {
                    system.colliders.append(.init(joint: node, offset: vector(sphere["offset"], .zero), radius: max(0, number(sphere["radius"], 0))))
                } else if let capsule = shape["capsule"] as? Object {
                    system.colliders.append(.init(joint: node, offset: vector(capsule["offset"], .zero), tail: vector(capsule["tail"], .zero), radius: max(0, number(capsule["radius"], 0))))
                } else { usable.append(nil); continue }
                usable.append(system.colliders.count - 1)
            }
            let groups = (spring["colliderGroups"] as? [Any] ?? []).map { group in
                (((group as? Object)?["colliders"] as? [Any]) ?? []).compactMap { Self.int($0).flatMap { usable.indices.contains($0) ? usable[$0] : nil } }
            }
            for s in spring["springs"] as? [Any] ?? [] {
                let s = s as? Object ?? [:]
                let hit = (s["colliderGroups"] as? [Any] ?? []).compactMap(Self.int).flatMap { groups.indices.contains($0) ? groups[$0] : [] }
                let list = (s["joints"] as? [Any] ?? []).compactMap { $0 as? Object }
                guard list.count > 1 else { continue }
                for i in 0..<(list.count - 1) {
                    guard let head = Self.int(list[i]["node"]).flatMap({ sceneNode[$0] }), let tail = Self.int(list[i + 1]["node"]).flatMap({ sceneNode[$0] }) else { continue }
                    add(head: head, tail: position(tail), from: list[i], stiffness: "stiffness", hit: hit)
                }
            }
        } else if let secondary = (extensions["VRM"] as? Object)?["secondaryAnimation"] as? Object {
            var groups: [[Int]] = []
            for g in secondary["colliderGroups"] as? [Any] ?? [] {
                let g = g as? Object ?? [:]
                var indices: [Int] = []
                if let node = Self.int(g["node"]).flatMap({ sceneNode[$0] }) {
                    for c in g["colliders"] as? [Any] ?? [] where system.colliders.count < Self.maxColliders {
                        let c = c as? Object ?? [:]
                        // 0.x keeps the offset in a left-handed space: z points the other way.
                        let o = vector(c["offset"], .zero)
                        indices.append(system.colliders.count)
                        system.colliders.append(.init(joint: node, offset: SIMD3(o.x, o.y, -o.z), radius: max(0, number(c["radius"], 0))))
                    }
                }
                groups.append(indices)
            }
            // The file's children of each node of the scene, in the file's order.
            func children(_ i: Int) -> [Int] {
                (nodes[source[i]]["children"] as? [Any] ?? []).compactMap { Self.int($0).flatMap { sceneNode[$0] } }.filter { out.nodes[$0].parent == i }
            }
            var seen = Set<Int>()
            for g in secondary["boneGroups"] as? [Any] ?? [] {
                var g = g as? Object ?? [:]
                let hit = (g["colliderGroups"] as? [Any] ?? []).compactMap(Self.int).flatMap { groups.indices.contains($0) ? groups[$0] : [] }
                // Gravity is a direction of that left-handed space too.
                let pull = vector(g["gravityDir"], SIMD3(0, -1, 0))
                g["gravityDir"] = [NSNumber(value: pull.x), NSNumber(value: pull.y), NSNumber(value: -pull.z)]
                // Every bone below a root is a joint. Its first child is its tail; a bone
                // with no child gets a tail 7 cm further along, the way it came.
                var pending = (g["bones"] as? [Any] ?? []).compactMap { Self.int($0).flatMap { sceneNode[$0] } }.reversed().map { $0 }
                while let i = pending.popLast() {
                    guard seen.insert(i).inserted else { continue }
                    let below = children(i)
                    if let child = below.first {
                        add(head: i, tail: position(child), from: g, stiffness: "stiffiness", hit: hit)   // sic: the key is misspelt in the format
                    } else if let parent = out.nodes[i].parent {
                        let along = position(i) - position(parent), length = simd_length(along)
                        if length > 1e-6, length.isFinite { add(head: i, tail: position(i) + along / length * 0.07, from: g, stiffness: "stiffiness", hit: hit) }
                    }
                    pending.append(contentsOf: below.reversed())
                }
            }
        }
        return system.joints.isEmpty ? nil : system
    }
}
