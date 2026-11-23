import Foundation
import ModelCore
import simd

/// The animated parts of a Blender file, made into one skeleton: the file's objects that
/// move (or carry what moves) and the bones of its armatures, each a joint.
///
/// The skeleton is in the viewer's world (it has no node of its own): an object's joint is
/// where the object stands, a bone's joint where the bone stands as posed, and a mesh is
/// bound to the joints that move it. What is not animated costs nothing: a mesh that no
/// animation touches stays an ordinary node.
struct BlendRig {
    struct Armature {
        var object: Int
        /// The joint of each bone, by the bone's name.
        var bones: [String: Int]
        /// How far each bone reaches, for what is held by a bone's far end.
        var lengths: [String: Float]
    }

    var joints: [ModelScene.Skeleton.Joint] = []
    /// The keyed transform of each joint that has one.
    var motions: [Int: BlendMotion] = [:]
    /// The joint of each object, by the object's block (-1: none could be made).
    var objectJoints: [Int: Int] = [:]
    var armatures: [Int: Armature?] = [:]
    var curves: [Int: [BlendCurve]] = [:]
    /// The shape keys that move, by the mesh they are given to.
    var shapes: [(mesh: Int, key: BlendShapes)] = []
    var actionName: String?
    /// The most joints a skin can name.
    static let maxJoints = 65_535
}

/// The shape keys of a mesh: the shapes beside the first, each as what it adds to the reference.
struct BlendShapes {
    struct Target {
        var name: String
        var data: BlendFile.Block?
        /// The shape this one is measured from.
        var base: BlendFile.Block?
        /// The vertex group that scales this shape, by its index in the mesh's groups.
        var group: String
        var weight: Float
        var muted: Bool
        var range: ClosedRange<Float>
        var curve: BlendCurve?
    }
    var key: Int
    var targets: [Target]
}

/// What an object needs to move as the file's animation says.
struct BlendAnimationPlan {
    enum Skinning {
        case none
        /// The whole mesh follows one joint.
        case object(joint: Int)
        /// The mesh is deformed by the bones of an armature; `bind` takes the mesh into the armature's space.
        case armature(BlendRig.Armature, bind: simd_float4x4)
    }
    var skinning = Skinning.none
    var shapes: BlendShapes?

    var isActive: Bool { if case .none = skinning { return false } else { return true } }
}

extension Builder {
    // MARK: The clock

    /// The frame range and speed of the scene the file was saved on.
    func readTiming(of scene: (index: Int, block: BlendFile.Block)) -> BlendTiming {
        var timing = BlendTiming()
        guard let render = file.offset("Scene", "r") else { return timing }
        let base = scene.block.offset + render
        if let first = file.offset("RenderData", "sfra"), let last = file.offset("RenderData", "efra") {
            timing.start = Double(file.i32(base + first)); timing.end = Double(file.i32(base + last))
        }
        if let rate = file.offset("RenderData", "frs_sec"), let scale = file.offset("RenderData", "frs_sec_base") {
            let seconds = Double(file.i16(base + rate)), divisor = Double(file.f32(base + scale))
            let fps = divisor.isFinite && divisor > 0 ? seconds / divisor : 24
            if fps.isFinite, fps >= 1, fps <= 1000 { timing.framesPerSecond = fps }
        }
        return timing
    }

    // MARK: What a file says an object or a bone holds

    private func finite(_ v: SIMD3<Float>) -> SIMD3<Float> { v.x.isFinite && v.y.isFinite && v.z.isFinite ? v : .zero }

    private func transform(ofObject block: BlendFile.Block) -> BlendTransform {
        var t = BlendTransform()
        let base = block.offset
        func at(_ names: String...) -> Int? { names.compactMap { file.offset("Object", $0) }.first }
        t.mode = at("rotmode").map { Int(file.i16(base + $0)) } ?? 1
        if let o = at("loc") { t.location = finite(file.vector(base + o)) }
        if let o = at("dloc") { t.deltaLocation = finite(file.vector(base + o)) }
        if let o = at("rot") { t.euler = finite(file.vector(base + o)) }
        if let o = at("drot") { t.deltaEuler = finite(file.vector(base + o)) }
        if let o = at("quat") { let q = file.floats(base + o, 4); t.quaternion = SIMD4(q[0], q[1], q[2], q[3]) }
        if let o = at("dquat") { let q = file.floats(base + o, 4); t.deltaQuaternion = SIMD4(q[0], q[1], q[2], q[3]) }
        if let o = at("rotAxis") { t.axis = finite(file.vector(base + o)) }
        if let o = at("rotAngle") { t.angle = file.f32(base + o).isFinite ? file.f32(base + o) : 0 }
        if let o = at("scale", "size") { t.scale = finite(file.vector(base + o)) }
        if let o = at("dscale") { t.deltaScale = finite(file.vector(base + o)) }
        return t
    }

    private func transform(ofChannel block: BlendFile.Block) -> BlendTransform {
        var t = BlendTransform()
        let base = block.offset
        func at(_ name: String) -> Int? { file.offset("bPoseChannel", name) }
        t.mode = at("rotmode").map { Int(file.i16(base + $0)) } ?? 0
        if let o = at("loc") { t.location = finite(file.vector(base + o)) }
        if let o = at("eul") { t.euler = finite(file.vector(base + o)) }
        if let o = at("quat") { let q = file.floats(base + o, 4); t.quaternion = SIMD4(q[0], q[1], q[2], q[3]) }
        if let o = at("rotAxis") { t.axis = finite(file.vector(base + o)) }
        if let o = at("rotAngle") { t.angle = file.f32(base + o).isFinite ? file.f32(base + o) : 0 }
        if let o = at("size") { t.scale = finite(file.vector(base + o)) }
        return t
    }

    private func sound(_ m: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { c in (0..<4).allSatisfy { r in m[c][r].isFinite } } && abs(simd_determinant(m)) > 1e-12
    }

    // MARK: Curves

    /// The curves of an object (or of a shape-key set), read once.
    private mutating func curves(of index: Int) -> [BlendCurve] {
        if let known = rig.curves[index] { return known }
        let found = file.animationCurves(ofBlockAt: index)
        rig.curves[index] = found
        if !found.isEmpty, rig.actionName == nil { rig.actionName = file.actionName(ofBlockAt: index) }
        return found
    }

    /// The object's parent, and how it is held (0 an object, 4 an armature, 7 one of its bones).
    private func parent(of block: BlendFile.Block) -> (index: Int, block: BlendFile.Block, kind: Int)? {
        guard let field = file.offset("Object", "parent"), let found = file.dataBlock(at: file.pointer(block.offset + field)),
              found.block.code == BlendFile.code("OB") else { return nil }
        let kind = file.offset("Object", "partype").map { Int(file.i16(block.offset + $0)) & 15 } ?? 0
        return (found.index, found.block, kind)
    }

    /// Whether the object, or one it stands under, has keyed transforms.
    private mutating func movesByAnimation(_ index: Int, depth: Int = 0) -> Bool {
        guard depth < 64 else { return false }
        let moving = curves(of: index).contains { curve in
            switch curve.target { case .object?, .bone?: return true; default: return false }
        }
        if moving { return true }
        guard let held = parent(of: file.blocks[index]) else { return false }
        return movesByAnimation(held.index, depth: depth + 1)
    }

    // MARK: Joints

    /// The joint an object's placement is: its own transform under its parent's.
    mutating func objectJoint(_ index: Int, depth: Int = 0) -> Int? {
        if let known = rig.objectJoints[index] { return known >= 0 ? known : nil }
        guard depth < 64, rig.joints.count < BlendRig.maxJoints, file.blocks.indices.contains(index) else { return nil }
        let block = file.blocks[index]
        rig.objectJoints[index] = -1   // a parent that leads back here ends there
        let stored = transform(ofObject: block)
        let local = ModelScene.Skeleton.compose(stored.location + stored.deltaLocation, stored.rotation, stored.scale * stored.deltaScale)
        var parentJoint: Int?
        var prefix = Builder.upright
        if let held = parent(of: block) {
            let inverse = file.offset("Object", "parentinv").map { file.matrix(block.offset + $0) } ?? matrix_identity_float4x4
            if held.kind == 0 || held.kind == 4, let joint = objectJoint(held.index, depth: depth + 1) {
                parentJoint = joint; prefix = inverse
            } else if held.kind == 7, let named = file.structure("Object")?.fields["parsubstr"],
                      let bones = armature(held.index), let joint = bones.bones[file.text(block.offset + named.offset, named.size)] {
                // Held by a bone: at its far end, as the bone stands.
                var tail = matrix_identity_float4x4
                tail.columns.3 = SIMD4(0, bones.lengths[file.text(block.offset + named.offset, named.size)] ?? 0, 0, 1)
                parentJoint = joint; prefix = tail * inverse
            } else {
                // Held some other way (a vertex, a curve): it stands where it did, and no further.
                let world = worldMatrix(index)
                prefix = Builder.upright * (sound(local) ? world * simd_inverse(local) : matrix_identity_float4x4)
            }
        }
        var joint = ModelScene.Skeleton.Joint(name: file.name(of: block), parent: parentJoint, rest: prefix * local)
        joint.animationPrefix = prefix
        joint.restComponents = (stored.location + stored.deltaLocation, stored.rotation, stored.scale * stored.deltaScale)
        rig.joints.append(joint)
        let made = rig.joints.count - 1
        rig.objectJoints[index] = made
        var motion = BlendMotion(stored: stored)
        for curve in curves(of: index) { if case .object(let property)? = curve.target { motion.add(property, curve) } }
        if motion.isAnimated { rig.motions[made] = motion }
        return made
    }

    /// The bones of an armature object as joints, standing as posed; nil when the object
    /// is not an armature or its bones cannot be read.
    mutating func armature(_ index: Int) -> BlendRig.Armature? {
        if let known = rig.armatures[index] { return known }
        rig.armatures[index] = .some(nil)
        let object = file.blocks[index]
        guard let dataField = file.offset("Object", "data"), let data = file.dataBlock(at: file.pointer(object.offset + dataField)),
              data.block.code == BlendFile.code("AR"), let rootsField = file.offset("bArmature", "bonebase"),
              let bone = file.structure("Bone"), let nameField = bone.fields["name"], let matrixField = bone.fields["arm_mat"],
              let childrenField = bone.fields["childbase"], let placed = objectJoint(index) else { return nil }
        // The pose the file was saved in: each bone's own values by its name.
        var channels: [String: BlendFile.Block] = [:]
        file.currentOwner = index
        if let pose = file.offset("Object", "pose"), let held = file.block(at: file.pointer(object.offset + pose)),
           let chain = file.offset("bPose", "chanbase"), let name = file.structure("bPoseChannel")?.fields["name"] {
            for one in file.list(file.pointer(held.offset + chain)) { channels[file.text(one.block.offset + name.offset, name.size)] = one.block }
        }
        var keyed: [String: [(String, BlendCurve)]] = [:]
        for curve in curves(of: index) { if case .bone(let name, let property)? = curve.target { keyed[name, default: []].append((property, curve)) } }
        file.currentOwner = data.index
        var queue: [(block: BlendFile.Block, parent: Int, parentArm: simd_float4x4?)] = file.list(file.pointer(data.block.offset + rootsField)).map { ($0.block, placed, nil) }
        var made = BlendRig.Armature(object: index, bones: [:], lengths: [:])
        var head = 0
        let first = rig.joints.count
        var seen = Set<Int>()   // a Bone block is one joint, however many bones name it as a child
        while head < queue.count {
            let (block, parentJoint, parentArm) = queue[head]
            head += 1
            guard seen.insert(block.offset).inserted else { continue }
            guard rig.joints.count < BlendRig.maxJoints else { break }
            let name = file.text(block.offset + nameField.offset, nameField.size)
            let arm = file.matrix(block.offset + matrixField.offset)
            guard sound(arm) else {
                rig.joints.removeSubrange(first...)
                rig.motions = rig.motions.filter { $0.key < first }
                return nil
            }
            let stored = channels[name].map { transform(ofChannel: $0) } ?? { var t = BlendTransform(); t.mode = 0; return t }()
            let local = parentArm.map { simd_inverse($0) * arm } ?? arm
            let pose = ModelScene.Skeleton.compose(stored.location, stored.rotation, stored.scale)
            var joint = ModelScene.Skeleton.Joint(name: name, parent: parentJoint, rest: local * pose, inverseBind: simd_inverse(arm))
            joint.animationPrefix = local
            joint.restComponents = (stored.location, stored.rotation, stored.scale)
            rig.joints.append(joint)
            let id = rig.joints.count - 1
            // A bone's name stands for the first of that name.
            if made.bones[name] == nil { made.bones[name] = id; made.lengths[name] = file.f32(block.offset + (bone.fields["length"]?.offset ?? 0)) }
            var motion = BlendMotion(stored: stored)
            for (property, curve) in keyed[name] ?? [] { motion.add(property, curve) }
            if motion.isAnimated { rig.motions[id] = motion }
            if queue.count < BlendFile.maxListLength {
                queue += file.list(file.pointer(block.offset + childrenField.offset)).map { ($0.block, id, arm) }
            }
        }
        guard !made.bones.isEmpty else { return nil }
        rig.armatures[index] = .some(made)
        return made
    }

    // MARK: Which meshes move

    /// The armature the object's first working Armature modifier names.
    private func armatureOfModifiers(_ object: (index: Int, block: BlendFile.Block)) -> Int? {
        guard let list = file.offset("Object", "modifiers") else { return nil }
        let before = file.currentOwner
        defer { file.currentOwner = before }
        file.currentOwner = object.index
        for held in file.list(file.pointer(object.block.offset + list)) {
            guard let kind = file.structure(of: held.block), kind.name == "ArmatureModifierData", let target = kind.fields["object"] else { continue }
            // Bit 0: at work in the viewport; the modifier's own bit 0: deforms by vertex groups.
            if let mode = file.offset("ModifierData", "mode"), file.i32(held.block.offset + mode) & 1 == 0 { continue }
            if let flags = kind.fields["deformflag"], file.i16(held.block.offset + flags.offset) & 1 == 0 { continue }
            guard let found = file.dataBlock(at: file.pointer(held.block.offset + target.offset)), found.block.code == BlendFile.code("OB") else { return nil }
            return found.index
        }
        return nil
    }

    /// How an object has to be bound for its animation to show, when it has any: bound to the
    /// bones of the armature that deforms it, or whole to its own joint.
    mutating func animationPlan(object: (index: Int, block: BlendFile.Block), mesh: (index: Int, block: BlendFile.Block), hasMirror: Bool) -> BlendAnimationPlan {
        var plan = BlendAnimationPlan()
        let armatureIndex = armatureOfModifiers(object)
        let shapes = animatedShapes(of: mesh)
        let moves = movesByAnimation(object.index)
        guard armatureIndex != nil || shapes != nil || moves else { return plan }
        // A mirror copies vertices the file's weights and shapes do not number.
        if hasMirror {
            if !scene.diagnostics.skippedFeatures.contains("animation of mirrored meshes") { scene.diagnostics.skippedFeatures.append("animation of mirrored meshes") }
            return plan
        }
        if let armatureIndex, let bones = armature(armatureIndex) {
            let across = worldMatrix(armatureIndex), here = worldMatrix(object.index)
            if sound(across) { plan.skinning = .armature(bones, bind: simd_inverse(across) * here) }
        }
        if !plan.isActive, (moves || shapes != nil), let joint = objectJoint(object.index) { plan.skinning = .object(joint: joint) }
        if plan.isActive { plan.shapes = shapes }
        return plan
    }

    // MARK: Shape keys

    /// The mesh's shape keys when any of their values is keyed (the others are left as they are drawn).
    private mutating func animatedShapes(of mesh: (index: Int, block: BlendFile.Block)) -> BlendShapes? {
        guard let keyField = file.offset("Mesh", "key"), let key = file.dataBlock(at: file.pointer(mesh.block.offset + keyField)),
              key.block.code == BlendFile.code("KE"), let first = file.offset("Key", "block"), let reference = file.offset("Key", "refkey"),
              let kind = file.offset("Key", "type"), file.u8(key.block.offset + kind) == 1,
              let block = file.structure("KeyBlock"), let name = block.fields["name"], let data = block.fields["data"], let rel = block.fields["relative"],
              let flag = block.fields["flag"], let value = block.fields["curval"] else { return nil }
        let keyed = curves(of: key.index).compactMap { curve -> (String, BlendCurve)? in
            if case .shapeKey(let n)? = curve.target, curve.index == 0 { return (n, curve) } else { return nil }
        }
        guard !keyed.isEmpty else { return nil }
        let before = file.currentOwner
        defer { file.currentOwner = before }
        file.currentOwner = key.index
        let all = file.list(file.pointer(key.block.offset + first))
        let skipped = file.pointer(key.block.offset + reference)
        var targets: [BlendShapes.Target] = []
        for one in all where one.address != skipped {
            let b = one.block.offset
            let relative = Int(file.i16(b + rel.offset))
            let base = all.indices.contains(relative) ? all[relative].block : all.first { $0.address == skipped }?.block
            let low = block.fields["slidermin"].map { file.f32(b + $0.offset) } ?? 0, high = block.fields["slidermax"].map { file.f32(b + $0.offset) } ?? 1
            let range = low.isFinite && high.isFinite && low <= high ? low...high : 0...1
            let stored = file.f32(b + value.offset)
            let label = file.text(b + name.offset, name.size)
            targets.append(BlendShapes.Target(
                name: label, data: file.block(at: file.pointer(b + data.offset)), base: base.flatMap { file.block(at: file.pointer($0.offset + data.offset)) },
                group: block.fields["vgroup"].map { file.text(b + $0.offset, $0.size) } ?? "",
                weight: stored.isFinite ? min(max(stored, range.lowerBound), range.upperBound) : 0, muted: file.i16(b + flag.offset) & 1 != 0, range: range,
                curve: keyed.first { $0.0 == label }?.1))
        }
        guard !targets.isEmpty else { return nil }
        return BlendShapes(key: key.index, targets: targets)
    }

    // MARK: Binding the mesh

    /// Gives the parts of a mesh made for `plan` the skin and the shapes it calls for.
    /// `sources` is, for each part and each of its vertices, the file's vertex it came from.
    mutating func attachAnimation(plan: BlendAnimationPlan, mesh meshIndex: Int, source mesh: (index: Int, block: BlendFile.Block), sources: [[UInt32]]) {
        guard plan.isActive, scene.meshes.indices.contains(meshIndex), sources.count == scene.meshes[meshIndex].parts.count,
              let totalField = file.offset("Mesh", "verts_num", "totvert") else { return }
        let vertexCount = max(0, Int(file.i32(mesh.block.offset + totalField)))
        guard vertexCount > 0 else { return }
        // What each vertex of the file follows.
        var bound: (joints: [SIMD4<UInt16>], weights: [SIMD4<Float>])?
        var bind = matrix_identity_float4x4
        var wholeJoint = 0
        var winding: Int?
        switch plan.skinning {
        case .none: return
        case .object(let joint): wholeJoint = joint; winding = joint
        case .armature(let bones, let matrix):
            bound = boneWeights(mesh: mesh, armature: bones, vertexCount: vertexCount)
            bind = matrix
            winding = rig.joints.indices.contains(bones.object) ? bones.object : nil
            if bound == nil { wholeJoint = objectJointOf(bones) }
        }
        for p in scene.meshes[meshIndex].parts.indices {
            let source = sources[p]
            let count = scene.meshes[meshIndex].parts[p].positions.count
            guard source.count == count else { continue }
            var skin = ModelScene.Skin(skeleton: 0, geometryBind: bind)
            skin.windingJoint = winding
            skin.joints.reserveCapacity(count); skin.weights.reserveCapacity(count)
            for v in source {
                if let bound {
                    let at = Int(min(v, UInt32(vertexCount - 1)))
                    skin.joints.append(bound.joints[at]); skin.weights.append(bound.weights[at])
                } else {
                    skin.joints.append(SIMD4(UInt16(wholeJoint), 0, 0, 0)); skin.weights.append(SIMD4(1, 0, 0, 0))
                }
            }
            scene.meshes[meshIndex].parts[p].skin = skin
        }
        if let shapes = plan.shapes { attach(shapes, to: meshIndex, source: mesh, vertexCount: vertexCount, sources: sources) }
    }

    private func objectJointOf(_ armature: BlendRig.Armature) -> Int { max(0, rig.objectJoints[armature.object] ?? 0) }

    /// A mesh's vertex groups: their names in order, and the weights of each vertex.
    private struct Deform {
        var names: [String]
        var verts: BlendFile.Block
        var vertex: BlendFile.Structure
        var weight: BlendFile.Structure
        var count: Int, number: Int, amount: Int, list: Int
    }

    /// The mesh's weights, or nil when it has none. The file's current owner must be the mesh.
    private func deform(of mesh: (index: Int, block: BlendFile.Block), vertexCount: Int) -> Deform? {
        let base = mesh.block.offset
        guard let vertex = file.structure("MDeformVert"), let dw = vertex.fields["dw"], let total = vertex.fields["totweight"],
              let weight = file.structure("MDeformWeight"), let number = weight.fields["def_nr"], let amount = weight.fields["weight"],
              vertex.size > 0, weight.size > 0 else { return nil }
        var names: [String] = []
        if let list = file.offset("Mesh", "vertex_group_names"), let at = file.offset("bDeformGroup", "name") {
            for one in file.list(file.pointer(base + list)).prefix(65_536) { names.append(file.text(one.block.offset + at, 64)) }
        }
        guard !names.isEmpty else { return nil }
        // The weights are a list of vertices of their own: the mesh's own, or a layer of its vertex data.
        var held = file.offset("Mesh", "dvert").flatMap { file.block(at: file.pointer(base + $0)) }
        if held == nil { held = layers(base, ["vert_data", "vdata"]).first { $0.type == 2 }.flatMap { file.block(at: $0.data) } }
        guard let held, held.length / vertex.size >= vertexCount else { return nil }
        return Deform(names: names, verts: held, vertex: vertex, weight: weight, count: total.offset, number: number.offset, amount: amount.offset, list: dw.offset)
    }

    /// Calls `body` with each (group, weight) of a vertex.
    private func forEachWeight(of v: Int, in d: Deform, _ body: (Int, Float) -> Void) {
        let at = d.verts.offset + v * d.vertex.size
        let n = min(max(Int(file.i32(at + d.count)), 0), 4096)
        guard n > 0, let list = file.block(at: file.pointer(at + d.list)) else { return }
        for k in 0..<min(n, list.length / d.weight.size) {
            let entry = list.offset + k * d.weight.size
            body(Int(file.i32(entry + d.number)), file.f32(entry + d.amount))
        }
    }

    /// For each vertex, the (up to four) bones that move it, by its vertex groups, their weights
    /// made to add up to one (as Blender's armature deform does); a vertex in none of the
    /// armature's bones' groups stays with the armature itself.
    private func boneWeights(mesh: (index: Int, block: BlendFile.Block), armature: BlendRig.Armature, vertexCount: Int) -> (joints: [SIMD4<UInt16>], weights: [SIMD4<Float>])? {
        let before = file.currentOwner
        defer { file.currentOwner = before }
        file.currentOwner = mesh.index
        guard let d = deform(of: mesh, vertexCount: vertexCount) else { return nil }
        let groups = d.names.map { armature.bones[$0].map { UInt16($0) } }
        guard groups.contains(where: { $0 != nil }) else { return nil }
        let unbound = UInt16(objectJointOf(armature))
        var joints = [SIMD4<UInt16>](repeating: SIMD4(unbound, 0, 0, 0), count: vertexCount)
        var weights = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: vertexCount)
        for v in 0..<vertexCount {
            var found: [(UInt16, Float)] = []
            forEachWeight(of: v, in: d) { group, w in
                guard groups.indices.contains(group), let joint = groups[group], w.isFinite, w > 0 else { return }
                if let existing = found.firstIndex(where: { $0.0 == joint }) { found[existing].1 += w } else { found.append((joint, w)) }
            }
            guard !found.isEmpty else { continue }
            if found.count > 4 { found = Array(found.sorted { $0.1 > $1.1 }.prefix(4)) }
            let sum = found.reduce(0) { $0 + $1.1 }
            var j = SIMD4<UInt16>(repeating: 0), w = SIMD4<Float>(repeating: 0)
            for (k, one) in found.enumerated() { j[k] = one.0; w[k] = one.1 / sum }
            joints[v] = j; weights[v] = w
        }
        return (joints, weights)
    }

    /// The most numbers the shapes of one mesh may add up to.
    static let maxShapeValues = 60_000_000

    /// Gives each part of the mesh its shapes: for each vertex of the part, what the shape
    /// adds to the one of the file it came from.
    private mutating func attach(_ shapes: BlendShapes, to meshIndex: Int, source mesh: (index: Int, block: BlendFile.Block), vertexCount: Int, sources: [[UInt32]]) {
        let total = scene.meshes[meshIndex].parts.reduce(0) { $0 + $1.positions.count }
        guard total <= Self.maxShapeValues / (3 * max(shapes.targets.count, 1)) else {
            if !scene.diagnostics.skippedFeatures.contains("shape keys of large meshes") { scene.diagnostics.skippedFeatures.append("shape keys of large meshes") }
            return
        }
        // A shape that a vertex group scales: the weight of each vertex in that group.
        var scales: [[Float]?] = shapes.targets.map { _ in nil }
        if shapes.targets.contains(where: { !$0.group.isEmpty }) {
            let before = file.currentOwner
            file.currentOwner = mesh.index
            if let d = deform(of: mesh, vertexCount: vertexCount) {
                for (t, target) in shapes.targets.enumerated() where !target.group.isEmpty {
                    guard let wanted = d.names.firstIndex(of: target.group) else { continue }
                    var each = [Float](repeating: 0, count: vertexCount)
                    for v in 0..<vertexCount { forEachWeight(of: v, in: d) { group, w in if group == wanted, w.isFinite { each[v] += w } } }
                    scales[t] = each
                }
            }
            file.currentOwner = before
        }
        for p in scene.meshes[meshIndex].parts.indices where sources[p].count == scene.meshes[meshIndex].parts[p].positions.count {
            var made: [ModelScene.MorphTarget] = []
            for (t, target) in shapes.targets.enumerated() {
                var shape = ModelScene.MorphTarget()
                shape.positions.reserveCapacity(sources[p].count)
                guard let a = target.data, let b = target.base, a.length >= vertexCount * 12, b.length >= vertexCount * 12 else {
                    shape.positions = [SIMD3<Float>](repeating: .zero, count: sources[p].count)
                    made.append(shape)
                    continue
                }
                for v in sources[p] {
                    let at = Int(min(v, UInt32(vertexCount - 1)))
                    var delta = file.vector(a.offset + at * 12) - file.vector(b.offset + at * 12)
                    // A shape with a vertex group moves only the vertices in it.
                    if !target.group.isEmpty { delta *= scales[t]?[at] ?? 0 }
                    shape.positions.append(delta.x.isFinite && delta.y.isFinite && delta.z.isFinite ? delta : .zero)
                }
                made.append(shape)
            }
            scene.meshes[meshIndex].parts[p].morphTargets = made
        }
        scene.meshes[meshIndex].morphWeights = shapes.targets.map { $0.muted ? 0 : $0.weight }
        rig.shapes.append((meshIndex, shapes))
    }

    // MARK: The clip

    /// The skeleton and the animation, once every mesh has been bound.
    mutating func finishAnimation() {
        guard !rig.joints.isEmpty else { return }
        scene.skeletons = [ModelScene.Skeleton(joints: rig.joints, node: nil)]
        guard !rig.motions.isEmpty || !rig.shapes.isEmpty else { return }

        // The frames the clip covers: the scene's, or when it has none, those of the keys.
        var low = timing.start, high = timing.end
        if !(high > low) {
            let keys = rig.curves.values.flatMap { $0 }.flatMap { $0.keys.map(\.frame) }
            guard let first = keys.min(), let last = keys.max() else { return }
            low = first; high = last
        }
        var clip = ModelScene.AnimationClip(name: rig.actionName ?? "Animation", skeleton: 0, start: 0, end: max(0, timing.seconds(high)))
        var budget = BlendAnimationLimits.refinements

        func channel<Value>(_ frames: (keys: [Double], jumps: Set<Double>), tolerance: Float, value: (Double) -> Value, mix: (Value, Value, Float) -> Value,
                            error: (Value, Value) -> Float) -> ModelScene.Channel<Value> {
            let points = BlendSampling.samples(from: low, to: high, keyFrames: frames.keys, steps: frames.jumps, tolerance: tolerance, budget: &budget,
                                               value: value, mix: mix, error: error)
            var out = ModelScene.Channel<Value>()
            for point in points {
                let time = timing.seconds(point.frame)
                // Times must run forward; one that does not (too close, after rounding) is dropped.
                if let last = out.times.last, !(time > last) { continue }
                out.times.append(time); out.values.append(point.value)
            }
            return out
        }
        func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            simd_reduce_max(simd_abs(a - b)) / max(1, simd_reduce_max(simd_abs(a)), simd_reduce_max(simd_abs(b)))
        }
        for (joint, motion) in rig.motions.sorted(by: { $0.key < $1.key }) {
            if motion.hasLocation {
                clip.linearTranslations[joint] = channel(motion.locationFrames, tolerance: 2e-5, value: motion.translation(at:),
                                                         mix: { simd_mix($0, $1, SIMD3(repeating: $2)) }, error: distance)
            }
            if motion.hasRotation {
                clip.linearRotations[joint] = channel(motion.rotationFrames, tolerance: 1e-5, value: motion.rotation(at:),
                                                      mix: { simd_slerp($0, $1, $2) }, error: { a, b in
                    // The two ends of a short turn, the near way round.
                    let flip: Float = simd_dot(a.vector, b.vector) < 0 ? -1 : 1
                    return simd_length(a.vector - b.vector * flip)
                })
            }
            if motion.hasScale {
                clip.linearScales[joint] = channel(motion.scaleFrames, tolerance: 2e-5, value: motion.scale(at:),
                                                   mix: { simd_mix($0, $1, SIMD3(repeating: $2)) }, error: distance)
            }
        }
        for (mesh, shapes) in rig.shapes {
            let curves = shapes.targets.map(\.curve)
            guard curves.contains(where: { $0 != nil }) else { continue }
            let keys = curves.compactMap { $0 }.flatMap { $0.keys.map(\.frame) }
            let jumps = Set(curves.compactMap { $0 }.flatMap(\.jumps))
            func weights(_ frame: Double) -> [Float] {
                shapes.targets.map { target in
                    guard !target.muted else { return 0 }
                    let v = target.curve?.value(at: frame) ?? target.weight
                    return v.isFinite ? min(max(v, target.range.lowerBound), target.range.upperBound) : 0
                }
            }
            let made = channel((keys, jumps), tolerance: 1e-5, value: weights, mix: { a, b, f in zip(a, b).map { $0 + ($1 - $0) * f } },
                               error: { a, b in zip(a, b).map { abs($0 - $1) }.max() ?? 0 })
            var morph = ModelScene.MorphChannel(mesh: mesh, targetCount: shapes.targets.count, times: made.times)
            morph.values = made.values.flatMap { $0 }
            clip.morphs.append(morph)
        }
        scene.clips.append(clip)
    }
}

enum BlendAnimationLimits {
    /// Frames added between keys over a whole file, where the curves bend.
    static let refinements = 400_000
}
