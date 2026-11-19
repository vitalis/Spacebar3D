import Foundation
import ModelCore
import simd

/// Reads Blender files (2.80 and later) into a `ModelScene`: the scene as saved, before
/// anything Blender works out when it opens the file.
///
/// - the visible mesh objects of the scene the file was saved on, where they stand;
/// - faces as modelled, with their corners (modifiers such as Subdivision or Mirror are
///   not applied), smooth or flat as each face is marked;
/// - for each material the Principled BSDF's plain colour, metallic, roughness, alpha and
///   emission, and its base-colour image when that image is packed into the file.
///
/// Curves, text, armatures and their animation, node-built materials and images kept in
/// separate files are not shown.
public enum BlendReader {
    public enum Failure: Error, LocalizedError, Equatable {
        case notBlend
        case tooLarge
        case damaged
        case unsupported(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .notBlend: return L10n.text("This is not a Blender file.")
            case .tooLarge: return L10n.text("The file is too large to show.")
            case .damaged: return L10n.text("The Blender file is damaged.")
            case .unsupported(let why): return L10n.format("This Blender file cannot be shown: %@.", String(describing: why))
            case .empty: return L10n.text("The Blender file has no visible mesh objects.")
            }
        }
    }

    /// The whole file is held in memory, twice over when it is compressed.
    public static let maxBytes = 1024 * 1024 * 1024
    /// Corners a mesh may have (a corner becomes a vertex to draw).
    public static let maxCorners = 40_000_000
    public static let maxObjects = 200_000

    public static func load(_ url: URL) throws -> ModelScene {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw Failure.tooLarge }
        return try scene(from: try Data(contentsOf: url, options: .mappedIfSafe), sidecars: SidecarFolder(modelURL: url))
    }

    public static func scene(from data: Data, sidecars: SidecarSource? = nil) throws -> ModelScene {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let file = try BlendFile(try BlendFile.unpacked(data))
        guard file.version >= 280 else { throw Failure.unsupported(L10n.text("it was saved by a Blender older than 2.80")) }
        var builder = Builder(file: file, sidecars: sidecars)
        try builder.build()
        return builder.scene
    }
}

private struct Builder {
    let file: BlendFile
    var scene = ModelScene()
    /// Blender's world has Z up; the viewer's has Y up.
    static let upright = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1))
    private var materialIndex: [Int: Int] = [:]
    private var plainMaterial: Int?
    private var imageIndex: [Int: Int?] = [:]
    private var world: [Int: simd_float4x4] = [:]

    let sidecars: SidecarSource?

    init(file: BlendFile, sidecars: SidecarSource?) { self.file = file; self.sidecars = sidecars }

    // MARK: The scene and its objects

    mutating func build() throws {
        scene.nodes.append(ModelScene.Node(name: "up", transform: Self.upright))
        var shown = 0
        for (index, block, visible) in try objects().prefix(BlendReader.maxObjects) where visible {
            guard let type = file.offset("Object", "type"), file.i16(block.offset + type) == 1,
                  let data = file.offset("Object", "data"), let found = file.dataBlock(at: file.pointer(block.offset + data)), found.block.code == BlendFile.code("ME")
            else { continue }
            let slots = materialSlots(object: (index, block), mesh: found)
            guard let made = try readMesh(found.index, found.block, slots: slots) else { continue }
            scene.meshes.append(made)
            scene.nodes.append(ModelScene.Node(name: file.name(of: block), parent: 0, transform: worldMatrix(index), mesh: scene.meshes.count - 1))
            shown += 1
        }
        guard shown > 0 else { throw BlendReader.Failure.empty }
    }

    /// The objects of the scene the file was saved on (the first scene when the file does
    /// not say), each with whether it shows in the viewport.
    private func objects() throws -> [(index: Int, block: BlendFile.Block, visible: Bool)] {
        var chosen = file.dataBlocks("SC").first
        if let global = file.dataBlocks("GLOB").first, let current = file.offset("FileGlobal", "curscene"),
           let named = file.dataBlock(at: file.pointer(global.block.offset + current)), named.block.code == BlendFile.code("SC") { chosen = named }
        guard let chosen, let layers = file.offset("Scene", "view_layers"), let bases = file.offset("ViewLayer", "object_bases"),
              let objectField = file.offset("Base", "object"), let flagField = file.offset("Base", "flag") else { throw BlendReader.Failure.empty }
        file.currentOwner = chosen.index
        // The first view layer is the one a viewport shows.
        guard let layer = file.list(file.pointer(chosen.block.offset + layers)).first else { throw BlendReader.Failure.empty }
        let hidden = file.offset("Object", "visibility_flag", "restrictflag")
        let inShownCollection = shownObjects(scene: chosen, layer: layer.block)
        file.currentOwner = chosen.index
        var out: [(Int, BlendFile.Block, Bool)] = []
        var seen = Set<Int>()
        for base in file.list(file.pointer(layer.block.offset + bases)) {
            guard let object = file.dataBlock(at: file.pointer(base.block.offset + objectField)), object.block.code == BlendFile.code("OB"), seen.insert(object.index).inserted else { continue }
            let flag = Int(file.i16(base.block.offset + flagField))
            // In a collection that shows (or, when those cannot be read, bit 1: what Blender
            // last worked out). Bit 8: hidden by hand. On the object, bit 0: disabled in viewports.
            var visible = (inShownCollection?.contains(object.index) ?? (flag & (1 << 1) != 0)) && flag & (1 << 8) == 0
            if let hidden, file.i16(object.block.offset + hidden) & 1 != 0 { visible = false }
            out.append((object.index, object.block, visible))
        }
        return out
    }

    /// The objects that are in some collection the view layer shows: one that is not
    /// excluded or hidden there, nor disabled for viewports, under ancestors of which the
    /// same is true. Nil when the file's collections cannot be followed.
    private func shownObjects(scene: (index: Int, block: BlendFile.Block), layer: BlendFile.Block) -> Set<Int>? {
        guard let roots = file.offset("ViewLayer", "layer_collections"), let entry = file.structure("LayerCollection"),
              let collectionField = entry.fields["collection"], let flagField = entry.fields["flag"], let childrenField = entry.fields["layer_collections"],
              let members = file.offset("Collection", "gobject"), let collectionFlag = file.offset("Collection", "flag"),
              let member = file.offset("CollectionObject", "ob") else { return nil }
        var shown = Set<Int>()
        var pending = file.list(file.pointer(layer.offset + roots)).map(\.block)
        guard !pending.isEmpty else { return nil }
        var visited = 0
        while let one = pending.popLast(), visited < BlendFile.maxListLength {
            visited += 1
            file.currentOwner = scene.index
            // Bit 4: left out of the view layer. Bit 7: hidden in it.
            guard Int(file.i16(one.offset + flagField.offset)) & (1 << 4 | 1 << 7) == 0 else { continue }
            let address = file.pointer(one.offset + collectionField.offset)
            // The scene's own collection is part of the scene; the others are data-blocks.
            var collection: (owner: Int, block: BlendFile.Block)?
            if let named = file.dataBlock(at: address) { collection = (named.index, named.block) } else if let own = file.block(at: address) { collection = (scene.index, own) }
            guard let collection, Int(file.i16(collection.block.offset + collectionFlag)) & 1 == 0 else { continue }
            pending += file.list(file.pointer(one.offset + childrenField.offset)).map(\.block)
            file.currentOwner = collection.owner
            for held in file.list(file.pointer(collection.block.offset + members)) {
                if let object = file.dataBlock(at: file.pointer(held.block.offset + member)) { shown.insert(object.index) }
            }
        }
        return shown
    }

    // MARK: Where an object stands

    private func rotation(_ base: Int, mode: Int, euler: Int?, quaternion: Int?, axis: Int?, angle: Int?) -> simd_float3x3 {
        if mode > 0, let euler {
            let e = file.floats(base + euler, 3)
            let order = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]][min(mode, 6) - 1]
            var result = matrix_identity_float3x3
            for axisIndex in order {
                var v = SIMD3<Float>(repeating: 0); v[axisIndex] = 1
                result = simd_float3x3(simd_quatf(angle: e[axisIndex], axis: v)) * result
            }
            return result
        }
        if mode < 0, let axis, let angle {
            let a = file.vector(base + axis), length = simd_length(a)
            return length > 0 ? simd_float3x3(simd_quatf(angle: file.f32(base + angle), axis: a / length)) : matrix_identity_float3x3
        }
        guard let quaternion else { return matrix_identity_float3x3 }
        let q = file.floats(base + quaternion, 4), v = SIMD4(q[1], q[2], q[3], q[0]), length = simd_length(v)
        return length > 0 ? simd_float3x3(simd_quatf(vector: v / length)) : matrix_identity_float3x3
    }

    /// An object's placement in the world: its own location, rotation and scale, under its parent's.
    private mutating func worldMatrix(_ index: Int, depth: Int = 0) -> simd_float4x4 {
        if let known = world[index] { return known }
        let base = file.blocks[index].offset
        let file = self.file
        // Up to 4.1 the file keeps where Blender last had the object, with its constraints
        // and animation counted in. Later files do not, and the placement is worked out
        // from the object's own values and its parent's.
        if let stored = file.offset("Object", "object_to_world", "obmat") {
            let m = file.matrix(base + stored)
            let sound = (0..<4).allSatisfy { c in (0..<4).allSatisfy { r in m[c][r].isFinite } }
            if sound, m.columns.3.w == 1, abs(simd_determinant(m)) > 1e-12 { world[index] = m; return m }
        }
        func at(_ names: String...) -> Int? { names.compactMap { file.offset("Object", $0) }.first }
        let mode = at("rotmode").map { Int(file.i16(base + $0)) } ?? 1
        let turn = rotation(base, mode: mode, euler: at("drot"), quaternion: at("dquat"), axis: at("drotAxis"), angle: at("drotAngle"))
            * rotation(base, mode: mode, euler: at("rot"), quaternion: at("quat"), axis: at("rotAxis"), angle: at("rotAngle"))
        let s = at("scale", "size").map { file.vector(base + $0) } ?? SIMD3(1, 1, 1)
        let ds = at("dscale").map { file.vector(base + $0) } ?? SIMD3(1, 1, 1)
        let l = (at("loc").map { file.vector(base + $0) } ?? .zero) + (at("dloc").map { file.vector(base + $0) } ?? .zero)
        let rs = turn * simd_float3x3(diagonal: s * ds)
        var local = simd_float4x4(SIMD4(rs.columns.0, 0), SIMD4(rs.columns.1, 0), SIMD4(rs.columns.2, 0), SIMD4(l, 1))
        world[index] = local   // a parent that leads back here ends there
        if depth < 256, let parentField = at("parent"), let parent = file.dataBlock(at: file.pointer(base + parentField)), parent.block.code == BlendFile.code("OB") {
            let inverse = at("parentinv").map { file.matrix(base + $0) } ?? matrix_identity_float4x4
            var carried = matrix_identity_float4x4
            // Held by one bone of an armature: it stands at that bone's far end, as posed.
            if let kind = at("partype"), file.i16(base + kind) & 15 == 7, let named = file.structure("Object")?.fields["parsubstr"] {
                carried = boneMatrix(of: parent, named: file.text(base + named.offset, named.size)) ?? carried
            }
            local = worldMatrix(parent.index, depth: depth + 1) * carried * inverse * local
        }
        let sound = (0..<4).allSatisfy { c in (0..<4).allSatisfy { r in local[c][r].isFinite } }
        world[index] = sound ? local : matrix_identity_float4x4
        return world[index]!
    }

    /// Where a bone of an armature object carries what is attached to it: the bone as
    /// posed when the file was saved (or as it rests, when no pose was saved), moved to its far end.
    private func boneMatrix(of armature: (index: Int, block: BlendFile.Block), named name: String) -> simd_float4x4? {
        let before = file.currentOwner
        defer { file.currentOwner = before }
        file.currentOwner = armature.index
        if let pose = file.offset("Object", "pose"), let held = file.block(at: file.pointer(armature.block.offset + pose)),
           let channels = file.offset("bPose", "chanbase"), let channel = file.structure("bPoseChannel"),
           let nameField = channel.fields["name"], let matrix = channel.fields["pose_mat"], let tail = channel.fields["pose_tail"] {
            for one in file.list(file.pointer(held.offset + channels)) where file.text(one.block.offset + nameField.offset, nameField.size) == name {
                var m = file.matrix(one.block.offset + matrix.offset)
                m.columns.3 = SIMD4(file.vector(one.block.offset + tail.offset), 1)
                return m
            }
        }
        // The bones as they rest, a tree under the armature's own data.
        guard let data = file.offset("Object", "data"), let rig = file.dataBlock(at: file.pointer(armature.block.offset + data)), rig.block.code == BlendFile.code("AR"),
              let roots = file.offset("bArmature", "bonebase"), let bone = file.structure("Bone"), let nameField = bone.fields["name"],
              let matrix = bone.fields["arm_mat"], let tail = bone.fields["arm_tail"], let children = bone.fields["childbase"] else { return nil }
        file.currentOwner = rig.index
        var pending = file.list(file.pointer(rig.block.offset + roots)).map(\.block)
        var visited = 0
        while let one = pending.popLast(), visited < BlendFile.maxListLength {
            visited += 1
            if file.text(one.offset + nameField.offset, nameField.size) == name {
                var m = file.matrix(one.offset + matrix.offset)
                m.columns.3 = SIMD4(file.vector(one.offset + tail.offset), 1)
                return m
            }
            pending += file.list(file.pointer(one.offset + children.offset)).map(\.block)
        }
        return nil
    }

    // MARK: Meshes

    /// One layer of a mesh's data: its kind, its name and where its values are.
    private func layers(_ base: Int, _ names: [String]) -> [(type: Int, name: String, data: UInt64, activeRender: Int)] {
        guard let mesh = file.structure("Mesh"), let field = names.lazy.compactMap({ mesh.fields[$0] }).first,
              let list = file.offset("CustomData", "layers"), let total = file.offset("CustomData", "totlayer"),
              let layer = file.structure("CustomDataLayer"), let type = layer.fields["type"], let name = layer.fields["name"], let data = layer.fields["data"],
              let block = file.block(at: file.pointer(base + field.offset + list)), layer.size > 0 else { return [] }
        let count = min(max(Int(file.i32(base + field.offset + total)), 0), block.length / layer.size)
        return (0..<count).map {
            let at = block.offset + $0 * layer.size
            return (Int(file.i32(at + type.offset)), file.text(at + name.offset, name.size), file.pointer(at + data.offset), layer.fields["active_rnd"].map { Int(file.i32(at + $0.offset)) } ?? 0)
        }
    }

    /// One attribute of a mesh as Blender 5 stores them.
    private struct Attribute { let name: String; let domain: Int; let type: Int; let single: Bool; let values: BlendFile.Block?; let count: Int }

    private func attributes(_ base: Int) -> [Attribute] {
        guard let storage = file.offset("Mesh", "attribute_storage"), let list = file.offset("AttributeStorage", "dna_attributes"),
              let listCount = file.offset("AttributeStorage", "dna_attributes_num"), let attribute = file.structure("Attribute"),
              let name = attribute.fields["name"], let data = attribute.fields["data"], let type = attribute.fields["data_type"],
              let domain = attribute.fields["domain"], let storageType = attribute.fields["storage_type"],
              let arrayData = file.offset("AttributeArray", "data"), let arraySize = file.offset("AttributeArray", "size"),
              let block = file.block(at: file.pointer(base + storage + list)), attribute.size > 0 else { return [] }
        var out: [Attribute] = []
        for i in 0..<min(max(Int(file.i32(base + storage + listCount)), 0), block.length / attribute.size) {
            let at = block.offset + i * attribute.size
            guard let nameBlock = file.block(at: file.pointer(at + name.offset)), let holder = file.block(at: file.pointer(at + data.offset)) else { continue }
            let single = file.u8(at + storageType.offset) != 0
            // The holder points to the values: an array of them, or the one value all share.
            let values = file.block(at: file.pointer(holder.offset + (single ? (file.offset("AttributeSingle", "data") ?? arrayData) : arrayData)))
            out.append(Attribute(name: file.text(nameBlock.offset, nameBlock.length), domain: Int(Int8(bitPattern: file.u8(at + domain.offset))),
                                 type: Int(file.i16(at + type.offset)), single: single, values: values, count: single ? 1 : Int(max(0, min(file.i64(holder.offset + arraySize), Int64(Int32.max))))))
        }
        return out
    }

    private mutating func readMesh(_ index: Int, _ block: BlendFile.Block, slots: [Int?]) throws -> ModelScene.Mesh? {
        guard let structure = file.structure("Mesh") else { return nil }
        file.currentOwner = index
        let base = block.offset
        func count(_ names: String...) -> Int { names.lazy.compactMap { structure.fields[$0] }.first.map { max(0, Int(file.i32(base + $0.offset))) } ?? 0 }
        let vertexCount = count("verts_num", "totvert"), faceCount = count("faces_num", "totpoly"), cornerCount = count("corners_num", "totloop")
        guard vertexCount > 0, faceCount > 0, cornerCount >= 3 else { return nil }
        guard cornerCount <= BlendReader.maxCorners, faceCount <= cornerCount else { throw BlendReader.Failure.tooLarge }
        let stored = attributes(base)
        let vertexLayers = layers(base, ["vert_data", "vdata"]), cornerLayers = layers(base, ["corner_data", "ldata"]), faceLayers = layers(base, ["face_data", "pdata"])
        func fits(_ b: BlendFile.Block, _ count: Int, _ stride: Int) -> Bool { stride > 0 && b.length / stride >= count }

        // Positions: the vertex records of older files, the "position" layer, or the attribute.
        var positions: (offset: Int, stride: Int)?
        if let s = file.structure("MVert"), let co = s.fields["co"] {
            var b = structure.fields["mvert"].flatMap { file.block(at: file.pointer(base + $0.offset)) }
            if b == nil, let layer = vertexLayers.first(where: { $0.type == 0 }) { b = file.block(at: layer.data) }
            if let b, fits(b, vertexCount, s.size) { positions = (b.offset + co.offset, s.size) }
        }
        if positions == nil, let layer = vertexLayers.first(where: { $0.name == "position" && $0.type == 48 }), let b = file.block(at: layer.data), fits(b, vertexCount, 12) { positions = (b.offset, 12) }
        if positions == nil, let a = stored.first(where: { $0.name == "position" && $0.domain == 0 && !$0.single }), let b = a.values, fits(b, vertexCount, 12) { positions = (b.offset, 12) }
        guard let positions else { return nil }

        // Which vertex each corner is at.
        var corners: (offset: Int, stride: Int)?
        if let s = file.structure("MLoop"), let v = s.fields["v"] {
            var b = structure.fields["mloop"].flatMap { file.block(at: file.pointer(base + $0.offset)) }
            if b == nil, let layer = cornerLayers.first(where: { $0.type == 26 }) { b = file.block(at: layer.data) }
            if let b, fits(b, cornerCount, s.size) { corners = (b.offset + v.offset, s.size) }
        }
        if corners == nil, let layer = cornerLayers.first(where: { $0.name == ".corner_vert" && $0.type == 11 }), let b = file.block(at: layer.data), fits(b, cornerCount, 4) { corners = (b.offset, 4) }
        if corners == nil, let a = stored.first(where: { $0.name == ".corner_vert" && !$0.single }), let b = a.values, fits(b, cornerCount, 4) { corners = (b.offset, 4) }
        guard let corners else { return nil }

        // Where each face's corners begin, and for older files its flags and material beside that.
        var starts = [Int](repeating: 0, count: faceCount + 1)
        var polygons: (offset: Int, size: Int, flag: Int?, material: Int?)?
        if let field = structure.fields["face_offset_indices"] ?? structure.fields["poly_offset_indices"],
           let b = file.block(at: file.pointer(base + field.offset)), fits(b, faceCount + 1, 4) {
            for i in 0...faceCount { starts[i] = Int(file.i32(b.offset + i * 4)) }
        } else if let s = file.structure("MPoly"), let start = s.fields["loopstart"], let total = s.fields["totloop"] {
            var b = structure.fields["mpoly"].flatMap { file.block(at: file.pointer(base + $0.offset)) }
            if b == nil, let layer = faceLayers.first(where: { $0.type == 25 }) { b = file.block(at: layer.data) }
            guard let b, fits(b, faceCount, s.size) else { return nil }
            polygons = (b.offset, s.size, s.fields["flag"]?.offset, s.fields["mat_nr"]?.offset)
            // Faces are kept in order; one that is not where the last ended is taken as it says.
            for i in 0..<faceCount {
                starts[i] = Int(file.i32(b.offset + i * s.size + start.offset))
                starts[i + 1] = starts[i] + Int(file.i32(b.offset + i * s.size + total.offset))
            }
        } else {
            return nil
        }

        // Smooth or flat, and the material slot, face by face.
        func perFace(_ name: String) -> (offset: Int, width: Int, single: Bool)? {
            if let layer = faceLayers.first(where: { $0.name == name }), let b = file.block(at: layer.data) {
                let width = layer.type == 50 ? 1 : 4
                return fits(b, faceCount, width) ? (b.offset, width, false) : nil
            }
            if let a = stored.first(where: { $0.name == name && $0.domain == 2 }), let b = a.values {
                let width = a.single ? b.length : b.length / max(a.count, 1)
                guard [1, 2, 4].contains(width), a.single || fits(b, faceCount, width) else { return nil }
                return (b.offset, width, a.single)
            }
            return nil
        }
        func value(_ source: (offset: Int, width: Int, single: Bool), _ face: Int) -> Int {
            let at = source.offset + (source.single ? 0 : face * source.width)
            return source.width == 4 ? Int(file.i32(at)) : source.width == 2 ? Int(file.i16(at)) : Int(Int8(bitPattern: file.u8(at)))
        }
        let sharp = perFace("sharp_face"), slotOf = perFace("material_index")

        // Texture coordinates: the map used for rendering, or the first.
        var uvs: (offset: Int, stride: Int)?
        let maps = cornerLayers.filter { $0.type == 16 || $0.type == 49 }
        if let first = maps.first {
            let same = maps.filter { $0.type == first.type }
            let chosen = same.indices.contains(first.activeRender) ? same[first.activeRender] : first
            let stride = chosen.type == 16 ? (file.structure("MLoopUV")?.size ?? 12) : 8
            if let b = file.block(at: chosen.data), fits(b, cornerCount, stride) { uvs = (b.offset, stride) }
        }
        if uvs == nil {
            let maps = stored.filter { $0.domain == 3 && $0.type == 6 && !$0.single }
            var wanted: String?
            if let field = structure.fields["default_uv_map_attribute"] ?? structure.fields["active_uv_map_attribute"], let b = file.block(at: file.pointer(base + field.offset)) { wanted = file.text(b.offset, b.length) }
            if let chosen = maps.first(where: { $0.name == wanted }) ?? maps.first, let b = chosen.values, fits(b, cornerCount, 8) { uvs = (b.offset, 8) }
        }

        // Smooth faces share a direction at each vertex: the sum of their faces' own, by area.
        var points = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for i in 0..<vertexCount {
            let p = file.vector(positions.offset + i * positions.stride)
            points[i] = p.x.isFinite && p.y.isFinite && p.z.isFinite ? p : .zero
        }
        var vertexOf = [Int](repeating: 0, count: cornerCount)
        for i in 0..<cornerCount { vertexOf[i] = min(max(Int(file.i32(corners.offset + i * corners.stride)), 0), vertexCount - 1) }
        var faceNormals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: faceCount)
        var vertexNormals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var usable = [Bool](repeating: false, count: faceCount)
        for f in 0..<faceCount {
            let start = starts[f], size = starts[f + 1] - start
            guard start >= 0, size >= 3, start + size <= cornerCount else { continue }
            usable[f] = true
            // Newell's sum: twice the face's area, along its direction, whatever its shape.
            var n = SIMD3<Float>.zero
            for k in 0..<size {
                let a = points[vertexOf[start + k]], b = points[vertexOf[start + (k + 1) % size]]
                n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
            }
            for k in 0..<size { vertexNormals[vertexOf[start + k]] += n }
            let length = simd_length(n)
            if length > 0, length.isFinite { faceNormals[f] = n / length }
        }

        // One part for each material slot in use, its faces in the file's order; every
        // corner is a vertex to draw, since corners differ in direction and coordinates.
        var parts: [ModelScene.MeshPart] = []
        var partOf: [Int: Int] = [:]
        var order: [Int] = []
        var sizes: [[UInt32]] = []
        for f in 0..<faceCount where usable[f] {
            let start = starts[f], size = starts[f + 1] - start
            guard let triangles = PolygonTriangulation.indices(count: size, position: { points[vertexOf[start + $0]] }) else { continue }
            var slot = 0
            if let slotOf { slot = value(slotOf, f) } else if let polygons, let material = polygons.material { slot = Int(file.i16(polygons.offset + f * polygons.size + material)) }
            let p: Int
            if let known = partOf[slot] { p = known } else { p = parts.count; partOf[slot] = p; parts.append(ModelScene.MeshPart()); order.append(slot); sizes.append([]) }
            var smooth = true
            if let sharp { smooth = value(sharp, f) == 0 } else if let polygons, let flag = polygons.flag { smooth = file.u8(polygons.offset + f * polygons.size + flag) & 1 != 0 }
            let first = UInt32(parts[p].positions.count)
            for k in 0..<size {
                let vertex = vertexOf[start + k]
                parts[p].positions.append(points[vertex])
                var normal = faceNormals[f]
                if smooth { let n = vertexNormals[vertex], length = simd_length(n); if length > 0, length.isFinite { normal = n / length } }
                parts[p].normals.append(normal)
                if let uvs {
                    // Blender counts an image from its bottom edge; the scene from its top.
                    let u = file.f32(uvs.offset + (start + k) * uvs.stride), v = file.f32(uvs.offset + (start + k) * uvs.stride + 4)
                    parts[p].uv0.append(u.isFinite && v.isFinite ? SIMD2(u, 1 - v) : .zero)
                }
            }
            parts[p].triangleIndices.append(contentsOf: triangles.map { first + UInt32($0) })
            sizes[p].append(UInt32(size))
            scene.topology.addFace(corners: size)
        }
        guard !order.isEmpty else { return nil }
        scene.topology.vertices += vertexCount
        var made = ModelScene.Mesh(name: file.name(of: block))
        for (p, slot) in order.enumerated() {
            var part = parts[p]
            part.faceSizes = sizes[p].allSatisfy { $0 == 3 } ? nil : sizes[p]
            part.material = material(slots.indices.contains(slot) ? slots[slot] : nil)
            made.parts.append(part)
        }
        return made
    }

    // MARK: Materials

    /// The material in each slot of an object: the mesh's own, or the object's where it overrides.
    private func materialSlots(object: (index: Int, block: BlendFile.Block), mesh: (index: Int, block: BlendFile.Block)) -> [Int?] {
        func pointers(_ owner: (index: Int, block: BlendFile.Block), _ structure: String) -> [UInt64] {
            guard let list = file.offset(structure, "mat"), let total = file.offset(structure, "totcol") else { return [] }
            file.currentOwner = owner.index
            guard let b = file.block(at: file.pointer(owner.block.offset + list)) else { return [] }
            let count = min(max(Int(file.i16(owner.block.offset + total)), 0), b.length / file.pointerSize, 4096)
            return (0..<count).map { file.pointer(b.offset + $0 * file.pointerSize) }
        }
        var slots = pointers(mesh, "Mesh")
        let own = pointers(object, "Object")
        if let bits = file.offset("Object", "matbits") {
            file.currentOwner = object.index
            if let b = file.block(at: file.pointer(object.block.offset + bits)) {
                for i in 0..<min(own.count, b.length) where file.u8(b.offset + i) != 0 {
                    while slots.count <= i { slots.append(0) }
                    slots[i] = own[i]
                }
            }
        }
        return slots.map { file.dataBlock(at: $0).flatMap { $0.block.code == BlendFile.code("MA") ? $0.index : nil } }
    }

    /// Blender's colours are amounts of light; the scene's are as seen on screen.
    private static func screen(_ v: Float) -> Float {
        let c = min(max(v.isFinite ? v : 0, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private mutating func material(_ index: Int?) -> Int {
        guard let index else {
            if let plainMaterial { return plainMaterial }
            var plain = ModelScene.Material()
            plain.baseColor = SIMD4(0xb4, 0xb4, 0xb8, 255) / 255
            plain.metallic = 0; plain.roughness = 0.65; plain.doubleSided = true
            scene.materials.append(plain)
            plainMaterial = scene.materials.count - 1
            return plainMaterial!
        }
        if let known = materialIndex[index] { return known }
        let block = file.blocks[index], base = block.offset
        file.currentOwner = index
        var made = ModelScene.Material()
        made.name = file.name(of: block)
        made.doubleSided = true
        // The colour and surface the viewport shows, for a material with no Principled node.
        func plain(_ name: String, _ fallback: Float) -> Float { file.offset("Material", name).map { file.f32(base + $0) } ?? fallback }
        var colour = SIMD4(plain("r", 0.8), plain("g", 0.8), plain("b", 0.8), plain("a", 1))
        var metallic = plain("metallic", 0), roughness = plain("roughness", 0.5)
        var emission = SIMD3<Float>.zero, strength: Float = 1
        var image: Int?

        // The material's nodes are part of the material; older files write them as a
        // data-block of their own, whose pieces then belong to that.
        var tree: BlendFile.Block?
        if let treeField = file.offset("Material", "nodetree") {
            let address = file.pointer(base + treeField)
            tree = file.block(at: address)
            if tree == nil, let own = file.dataBlock(at: address) { tree = own.block; file.currentOwner = own.index }
        }
        if let tree,
           let nodes = file.offset("bNodeTree", "nodes"), let links = file.offset("bNodeTree", "links"),
           let idname = file.structure("bNode")?.fields["idname"], let inputs = file.offset("bNode", "inputs"),
           let identifier = file.structure("bNodeSocket")?.fields["identifier"], let value = file.offset("bNodeSocket", "default_value") {
            let all = file.list(file.pointer(tree.offset + nodes))
            let allLinks = file.list(file.pointer(tree.offset + links))
            func kind(_ node: BlendFile.Block) -> String { file.text(node.offset + idname.offset, idname.size) }
            func sockets(_ node: BlendFile.Block) -> [(address: UInt64, block: BlendFile.Block)] { file.list(file.pointer(node.offset + inputs)) }
            /// The node feeding a socket, when something is connected to it.
            func source(of socket: UInt64) -> BlendFile.Block? {
                guard let to = file.offset("bNodeLink", "tosock"), let from = file.offset("bNodeLink", "fromnode") else { return nil }
                return allLinks.first { file.pointer($0.block.offset + to) == socket }.flatMap { file.block(at: file.pointer($0.block.offset + from)) }
            }
            // The Principled node the output's surface comes from, or the first there is.
            var principled = all.first { kind($0.block) == "ShaderNodeBsdfPrincipled" }?.block
            for output in all where kind(output.block) == "ShaderNodeOutputMaterial" {
                if let surface = sockets(output.block).first(where: { file.text($0.block.offset + identifier.offset, identifier.size) == "Surface" }),
                   let from = source(of: surface.address), kind(from) == "ShaderNodeBsdfPrincipled" { principled = from; break }
            }
            if let principled {
                emission = .zero
                for socket in sockets(principled) {
                    let name = file.text(socket.block.offset + identifier.offset, identifier.size)
                    // The value's structure is known by the kind of socket (older files do not say it).
                    let colours = ["Base Color", "Emission", "Emission Color"].contains(name)
                    guard let held = file.block(at: file.pointer(socket.block.offset + value)),
                          let at = file.offset(colours ? "bNodeSocketValueRGBA" : "bNodeSocketValueFloat", "value"), held.length >= at + (colours ? 16 : 4) else { continue }
                    switch name {
                    case "Base Color":
                        colour = SIMD4(file.f32(held.offset + at), file.f32(held.offset + at + 4), file.f32(held.offset + at + 8), colour.w)
                        if let from = source(of: socket.address), kind(from) == "ShaderNodeTexImage", let id = file.offset("bNode", "id"),
                           let picture = file.dataBlock(at: file.pointer(from.offset + id)), picture.block.code == BlendFile.code("IM") { image = picture.index }
                    case "Metallic": metallic = file.f32(held.offset + at)
                    case "Roughness": roughness = file.f32(held.offset + at)
                    case "Alpha": colour.w = file.f32(held.offset + at)
                    case "Emission", "Emission Color": emission = file.vector(held.offset + at)
                    case "Emission Strength": strength = file.f32(held.offset + at)
                    default: break
                    }
                }
            }
        }
        made.baseColor = SIMD4(Self.screen(colour.x), Self.screen(colour.y), Self.screen(colour.z), 1)
        made.opacity = colour.w.isFinite ? min(max(colour.w, 0), 1) : 1
        made.metallic = metallic.isFinite ? min(max(metallic, 0), 1) : 0
        made.roughness = roughness.isFinite ? min(max(roughness, 0), 1) : 0.5
        made.authoredPBR = true
        let glow = emission * (strength.isFinite ? max(strength, 0) : 1)
        if glow.x.isFinite, glow.y.isFinite, glow.z.isFinite, simd_reduce_max(glow) > 0 { made.emissive = simd_clamp(glow, SIMD3(repeating: 0), SIMD3(repeating: 64)) }
        // Packed images take precedence over files beside the model.
        if let image, let texture = self.image(image) {
            made.baseColorTexture = texture
            // The image carries the colour; the plain colour would tint it.
            made.baseColor = SIMD4(1, 1, 1, 1)
        }
        scene.materials.append(made)
        materialIndex[index] = scene.materials.count - 1
        return scene.materials.count - 1
    }

    /// Packed image bytes, or an external image read through the restricted sidecar source.
    private mutating func image(_ index: Int) -> Int? {
        if let known = imageIndex[index] { return known }
        imageIndex[index] = .some(nil)
        let block = file.blocks[index]
        let before = file.currentOwner
        file.currentOwner = index
        defer { file.currentOwner = before }
        guard let size = file.offset("PackedFile", "size"), let data = file.offset("PackedFile", "data") else { return nil }
        var packed = file.offset("Image", "packedfile").flatMap { file.block(at: file.pointer(block.offset + $0)) }
        if packed == nil, let list = file.offset("Image", "packedfiles"), let entry = file.list(file.pointer(block.offset + list)).first,
           let held = file.offset("ImagePackedFile", "packedfile") { packed = file.block(at: file.pointer(entry.block.offset + held)) }
        guard let packed, let bytes = file.block(at: file.pointer(packed.offset + data)) else {
            let path = file.offset("Image", "filepath", "name").map { file.text(block.offset + $0, 1024) } ?? ""
            // Blender's // prefix is relative to the model, not the filesystem root.
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            let relative = normalized.hasPrefix("//") ? String(normalized.dropFirst(2)) : normalized
            if let data = sidecars?.data(named: relative), !data.isEmpty {
                scene.textures.append(.embedded(bytes: [UInt8](data), mime: ""))
                imageIndex[index] = scene.textures.count - 1
                return scene.textures.count - 1
            }
            let name = (normalized as NSString).lastPathComponent
            if !name.isEmpty, !scene.diagnostics.missingResources.contains(name) { scene.diagnostics.missingResources.append(name) }
            return nil
        }
        let length = min(max(Int(file.i32(packed.offset + size)), 0), bytes.length)
        guard length > 0 else { return nil }
        let start = file.bytes.startIndex + bytes.offset
        scene.textures.append(.embedded(bytes: [UInt8](file.bytes[start..<(start + length)]), mime: ""))
        imageIndex[index] = scene.textures.count - 1
        return scene.textures.count - 1
    }
}
