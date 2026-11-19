import Foundation

/// A small scene written three ways, as three generations of Blender lay a mesh out.
///
/// One mesh "Shape": a square of one flat face in material slot 0 and a triangle of one
/// smooth face in slot 1, with texture coordinates. Objects: "Shown" (the mesh, moved to
/// 1, 2, 3), "Child" (under Shown, moved by 10 along X), "Disabled" (off for viewports),
/// "HiddenByHand", "InHiddenCollection" and "Excluded" (in collections the view layer
/// hides or leaves out), "OnBone" (held by the bone "Head" of "Rig"). Materials: "Red"
/// (a Principled node behind the output, and a stray one before it) and "Picture" (its
/// base colour from an image packed into the file).
enum BlendFixture {
    enum Layout { case records, layers, attributes }
    typealias V = BlendBuilder.Value

    static let packed = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4, 5])

    static func make(_ layout: Layout, storedPlacement: Bool = false, objectMaterial: Bool = false, withScene: Bool = true, externalImage: String? = nil, concave: Bool = false, reversed: Bool = false) -> Data {
        let header: BlendBuilder.Header
        switch layout { case .records: header = .classic(version: "280"); case .layers: header = .classic(version: "402"); case .attributes: header = .large(version: "0500") }
        let b = BlendBuilder(header: header)
        let link = [("void", "*next"), ("void", "*prev")]
        b.define("Link", link)
        b.define("ListBase", [("void", "*first"), ("void", "*last")])
        b.define("ID", [("void", "*next"), ("void", "*prev"), ("char", "name[66]"), ("char", "pad[6]")])
        b.define("FileGlobal", [("Scene", "*curscene")])
        b.define("Collection", [("ID", "id"), ("ListBase", "gobject"), ("short", "flag"), ("char", "pad[6]")])
        b.define("CollectionObject", link + [("Object", "*ob")])
        b.define("Scene", [("ID", "id"), ("ListBase", "view_layers"), ("Collection", "*master_collection")])
        b.define("ViewLayer", link + [("ListBase", "object_bases"), ("ListBase", "layer_collections")])
        b.define("Base", link + [("Object", "*object"), ("short", "flag"), ("char", "pad[6]")])
        b.define("LayerCollection", link + [("Collection", "*collection"), ("short", "flag"), ("char", "pad[6]"), ("ListBase", "layer_collections")])
        b.define("bPose", [("ListBase", "chanbase")])
        b.define("bPoseChannel", link + [("char", "name[64]"), ("float", "pose_mat[4][4]"), ("float", "pose_tail[3]"), ("char", "pad[4]")])
        b.define("Object", [("ID", "id"), ("short", "type"), ("short", "partype"), ("short", "rotmode"), ("short", "visibility_flag"), ("void", "*data"), ("Object", "*parent"),
                            ("float", "loc[3]"), ("float", "dloc[3]"), ("float", "rot[3]"), ("float", "drot[3]"), ("float", "quat[4]"), ("float", "dquat[4]"),
                            ("float", "rotAxis[3]"), ("float", "drotAxis[3]"), ("float", "rotAngle"), ("float", "drotAngle"), ("float", "scale[3]"), ("float", "dscale[3]"),
                            ("float", "parentinv[4][4]"), ("char", "parsubstr[64]"), ("Material", "**mat"), ("char", "*matbits"), ("short", "totcol"), ("char", "pad[6]"),
                            ("bPose", "*pose")] + (storedPlacement ? [("float", "obmat[4][4]")] : []))
        b.define("CustomDataLayer", [("int", "type"), ("int", "flag"), ("int", "active_rnd"), ("int", "pad"), ("char", "name[68]"), ("char", "pad2[4]"), ("void", "*data")])
        b.define("CustomData", [("CustomDataLayer", "*layers"), ("int", "totlayer"), ("int", "pad")])
        let materials = [("Material", "**mat"), ("short", "totcol"), ("char", "pad2[6]")]
        switch layout {
        case .records:
            b.define("MVert", [("float", "co[3]"), ("short", "no[3]"), ("char", "flag"), ("char", "bweight")])
            b.define("MLoop", [("int", "v"), ("int", "e")])
            b.define("MPoly", [("int", "loopstart"), ("int", "totloop"), ("short", "mat_nr"), ("char", "flag"), ("char", "pad")])
            b.define("MLoopUV", [("float", "uv[2]"), ("int", "flag")])
            b.define("Mesh", [("ID", "id"), ("int", "totvert"), ("int", "totpoly"), ("int", "totloop"), ("int", "pad"), ("MVert", "*mvert"), ("MLoop", "*mloop"), ("MPoly", "*mpoly"),
                              ("CustomData", "vdata"), ("CustomData", "ldata"), ("CustomData", "pdata")] + materials)
        case .layers:
            b.define("Mesh", [("ID", "id"), ("int", "verts_num"), ("int", "faces_num"), ("int", "corners_num"), ("int", "pad"), ("int", "*face_offset_indices"),
                              ("CustomData", "vert_data"), ("CustomData", "corner_data"), ("CustomData", "face_data")] + materials)
        case .attributes:
            b.define("AttributeArray", [("void", "*data"), ("int64_t", "size")])
            b.define("AttributeSingle", [("void", "*data")])
            b.define("Attribute", [("char", "*name"), ("short", "data_type"), ("char", "domain"), ("char", "storage_type"), ("char", "pad[4]"), ("void", "*data")])
            b.define("AttributeStorage", [("Attribute", "*dna_attributes"), ("int", "dna_attributes_num"), ("char", "pad[4]")])
            b.define("Mesh", [("ID", "id"), ("int", "verts_num"), ("int", "faces_num"), ("int", "corners_num"), ("int", "pad"), ("int", "*face_offset_indices"),
                              ("AttributeStorage", "attribute_storage"), ("CustomData", "vert_data"), ("CustomData", "corner_data"), ("CustomData", "face_data")] + materials
                             + [("char", "*default_uv_map_attribute")])
        }
        b.define("bNodeTree", [("ListBase", "nodes"), ("ListBase", "links")])
        b.define("bNode", link + [("char", "idname[64]"), ("ListBase", "inputs"), ("ID", "*id")])
        b.define("bNodeSocket", link + [("char", "identifier[64]"), ("void", "*default_value")])
        b.define("bNodeLink", link + [("bNode", "*fromnode"), ("bNodeSocket", "*tosock")])
        b.define("bNodeSocketValueRGBA", [("float", "value[4]")])
        b.define("bNodeSocketValueFloat", [("int", "subtype"), ("float", "value"), ("float", "min"), ("float", "max")])
        b.define("Material", [("ID", "id"), ("float", "r"), ("float", "g"), ("float", "b"), ("float", "a"), ("float", "metallic"), ("float", "roughness"), ("bNodeTree", "*nodetree")])
        b.define("PackedFile", [("int", "size"), ("int", "seek"), ("void", "*data")])
        b.define("ImagePackedFile", link + [("PackedFile", "*packedfile")])
        b.define("Image", [("ID", "id"), ("ListBase", "packedfiles"), ("char", "filepath[1024]")])

        /// A linked list of pieces of one data-block; gives the address of the first.
        func list(_ structure: String, _ records: [[String: V]], addresses: [UInt64]? = nil) -> UInt64 {
            let at = addresses ?? records.map { _ in b.reserve() }
            for (i, record) in records.enumerated() {
                var values = record
                if i + 1 < records.count { values["next"] = .pointer(at[i + 1]) }
                b.add("DATA", structure, b.record(structure, values), at: at[i])
            }
            return at.first ?? 0
        }
        func raw(_ data: Data, at address: UInt64? = nil) -> UInt64 { b.add("DATA", "Link", data, at: address) }
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

        let names = ["Shown", "Child", "Disabled", "HiddenByHand", "InHiddenCollection", "Excluded", "OnBone", "Rig"]
        let objects = Dictionary(uniqueKeysWithValues: names.map { ($0, b.reserve()) })
        let mesh = b.reserve(), red = b.reserve(), picture = b.reserve(), image = b.reserve(), scene = b.reserve()
        let hiddenGroup = b.reserve(), excludedGroup = b.reserve()

        if withScene { b.add("GLOB", "FileGlobal", b.record("FileGlobal", ["curscene": .pointer(scene)])) }

        // The scene: one view layer, its bases, and the collections it shows or does not.
        if withScene {
            let layer = b.reserve(), master = b.reserve()
            b.add("SC", "Scene", b.record("Scene", ["id.name": .text("SCScene"), "view_layers.first": .pointer(layer), "master_collection": .pointer(master)]), at: scene)
            let bases = names.map { _ in b.reserve() }, tops = [b.reserve()], below = [b.reserve(), b.reserve()]
            b.add("DATA", "ViewLayer", b.record("ViewLayer", ["object_bases.first": .pointer(bases[0]), "layer_collections.first": .pointer(tops[0])]), at: layer)
            // Bit 1 is what Blender last worked out, kept set here even where the collections say otherwise.
            _ = list("Base", names.map { ["object": .pointer(objects[$0]!), "flag": .int($0 == "HiddenByHand" ? (1 << 1 | 1 << 8) : 1 << 1)] }, addresses: bases)
            _ = list("LayerCollection", [["collection": .pointer(master), "layer_collections.first": .pointer(below[0])]], addresses: tops)
            _ = list("LayerCollection", [["collection": .pointer(hiddenGroup), "flag": .int(1 << 7)], ["collection": .pointer(excludedGroup), "flag": .int(1 << 4)]], addresses: below)
            let inMaster = ["Shown", "Child", "Disabled", "HiddenByHand", "OnBone", "Rig"]
            let members = inMaster.map { _ in b.reserve() }
            b.add("DATA", "Collection", b.record("Collection", ["id.name": .text("GRMaster Collection"), "gobject.first": .pointer(members[0])]), at: master)
            _ = list("CollectionObject", inMaster.map { ["ob": .pointer(objects[$0]!)] }, addresses: members)
        }
        for (address, name, member) in [(hiddenGroup, "GRHidden", "InHiddenCollection"), (excludedGroup, "GRExcluded", "Excluded")] {
            let entry = b.reserve()
            b.add("GR", "Collection", b.record("Collection", ["id.name": .text(name), "gobject.first": .pointer(entry)]), at: address)
            _ = list("CollectionObject", [["ob": .pointer(objects[member]!)]], addresses: [entry])
        }

        // Objects.
        func object(_ name: String, _ values: [String: V]) {
            var all: [String: V] = ["id.name": .text("OB" + name), "type": .int(1), "rotmode": .int(1), "data": .pointer(mesh),
                                    "scale": .floats([1, 1, 1]), "dscale": .floats([1, 1, 1]), "parentinv": .floats(identity), "quat": .floats([1, 0, 0, 0]), "dquat": .floats([1, 0, 0, 0])]
            if storedPlacement { all["obmat"] = .floats(identity) }
            for (k, v) in values { all[k] = v }
            b.add("OB", "Object", b.record("Object", all), at: objects[name]!)
        }
        var pending: [() -> Void] = []
        // Where the object stands when the file keeps that: somewhere its own values do not say.
        var shown: [String: V] = ["loc": .floats([1, 2, 3])]
        if storedPlacement { shown["obmat"] = .floats([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 7, 8, 9, 1]) }
        if objectMaterial {
            // The object puts its own material in slot 0, over the mesh's.
            let slots = b.reserve(), bits = b.reserve()
            shown["mat"] = .pointer(slots); shown["matbits"] = .pointer(bits); shown["totcol"] = .int(2)
            pending.append { _ = raw(BlendBuilder.bytes([picture, UInt64(0)]), at: slots); _ = raw(Data([1, 0]), at: bits) }
        }
        object("Shown", shown)
        pending.forEach { $0() }
        // A quarter turn about Z, then under its parent.
        object("Child", ["loc": .floats([10, 0, 0]), "rot": .floats([0, 0, .pi / 2]), "parent": .pointer(objects["Shown"]!)])
        object("Disabled", ["visibility_flag": .int(1)])
        object("HiddenByHand", [:])
        object("InHiddenCollection", [:])
        object("Excluded", [:])
        object("OnBone", ["parent": .pointer(objects["Rig"]!), "partype": .int(7), "parsubstr": .text("Head"), "loc": .floats([0, 0, 1])])
        // An armature (type 25) with one posed bone whose far end is at 0, 5, 0.
        let pose = b.reserve(), channel = b.reserve()
        object("Rig", ["type": .int(25), "data": .pointer(0), "pose": .pointer(pose), "loc": .floats([100, 0, 0])])
        b.add("DATA", "bPose", b.record("bPose", ["chanbase.first": .pointer(channel)]), at: pose)
        _ = list("bPoseChannel", [["name": .text("Head"), "pose_mat": .floats(identity), "pose_tail": .floats([0, 5, 0])]], addresses: [channel])

        // The mesh.
        var positions: [Float] = concave ? [0,2,0, 0,0,0, 2,0,0, 0.5,0.5,0, 0.5,2,1] : [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0.5, 2, 1]
        if reversed { positions = (0..<4).reversed().flatMap { Array(positions[($0 * 3)..<($0 * 3 + 3)]) } + Array(positions.suffix(3)) }
        let cornerVertices: [Int32] = [0, 1, 2, 3, 3, 2, 4]
        let uv: [Float] = (0..<7).flatMap { [Float($0) / 10, 0.25] }
        let slots = b.reserve()
        var values: [String: V] = ["id.name": .text("MEShape"), "mat": .pointer(slots), "totcol": .int(2)]
        var after: [() -> Void] = []
        func layers(_ field: String, _ entries: [(type: Int, name: String, data: Data)]) {
            let table = b.reserve()
            let held = entries.map { _ in b.reserve() }
            values[field + ".layers"] = .pointer(table); values[field + ".totlayer"] = .int(entries.count)
            after.append {
                var bytes = Data()
                for (i, e) in entries.enumerated() {
                    // On the first layer of a kind: which of that kind is the one to render (here, the second map).
                    bytes += b.record("CustomDataLayer", ["type": .int(e.type), "name": .text(e.name), "data": .pointer(held[i]), "active_rnd": .int(e.type == 49 ? 1 : 0)])
                }
                b.add("DATA", "CustomDataLayer", bytes, count: entries.count, at: table)
                for (i, e) in entries.enumerated() { _ = raw(e.data, at: held[i]) }
            }
        }
        switch layout {
        case .records:
            let verts = b.reserve(), loops = b.reserve(), polys = b.reserve()
            values["totvert"] = .int(5); values["totpoly"] = .int(2); values["totloop"] = .int(7)
            values["mvert"] = .pointer(verts); values["mloop"] = .pointer(loops); values["mpoly"] = .pointer(polys)
            // Texture coordinates with their flag, twelve bytes a corner.
            layers("ldata", [(16, "UVMap", (0..<7).reduce(Data()) { $0 + BlendBuilder.bytes([uv[$1 * 2], uv[$1 * 2 + 1]]) + BlendBuilder.bytes([Int32(0)]) })])
            after.append {
                var v = Data(); for i in 0..<5 { v += b.record("MVert", ["co": .floats(Array(positions[(i * 3)..<(i * 3 + 3)]))]) }
                b.add("DATA", "MVert", v, count: 5, at: verts)
                var l = Data(); for c in cornerVertices { l += b.record("MLoop", ["v": .int(Int(c))]) }
                b.add("DATA", "MLoop", l, count: 7, at: loops)
                // The square is flat and in slot 0; the triangle smooth (flag bit 0) and in slot 1.
                b.add("DATA", "MPoly", b.record("MPoly", ["loopstart": .int(0), "totloop": .int(4)]) + b.record("MPoly", ["loopstart": .int(4), "totloop": .int(3), "mat_nr": .int(1), "flag": .int(1)]), count: 2, at: polys)
            }
        case .layers:
            let offsets = b.reserve()
            values["verts_num"] = .int(5); values["faces_num"] = .int(2); values["corners_num"] = .int(7); values["face_offset_indices"] = .pointer(offsets)
            layers("vert_data", [(48, "position", BlendBuilder.bytes(positions))])
            // A second map marked as the one to render (the mark is on the first layer of the kind).
            layers("corner_data", [(11, ".corner_vert", BlendBuilder.bytes(cornerVertices)), (49, "Other", BlendBuilder.bytes([Float](repeating: 0.5, count: 14))), (49, "UVMap", BlendBuilder.bytes(uv))])
            layers("face_data", [(50, "sharp_face", Data([1, 0])), (11, "material_index", BlendBuilder.bytes([Int32(0), 1]))])
            after.append { _ = raw(BlendBuilder.bytes([Int32(0), 4, 7]), at: offsets) }
        case .attributes:
            let offsets = b.reserve(), table = b.reserve(), wanted = b.reserve()
            values["verts_num"] = .int(5); values["faces_num"] = .int(2); values["corners_num"] = .int(7); values["face_offset_indices"] = .pointer(offsets)
            values["default_uv_map_attribute"] = .pointer(wanted)
            // name, kind of value, where it lives (0 vertex, 2 face, 3 corner), one value for all, the values, how many
            let entries: [(String, Int, Int, Bool, Data, Int)] = [
                ("position", 7, 0, false, BlendBuilder.bytes(positions), 5), (".corner_vert", 5, 3, false, BlendBuilder.bytes(cornerVertices), 7),
                ("Other", 6, 3, false, BlendBuilder.bytes([Float](repeating: 0.5, count: 14)), 7), ("UVMap", 6, 3, false, BlendBuilder.bytes(uv), 7),
                ("sharp_face", 3, 2, false, Data([1, 0]), 2), ("material_index", 5, 2, false, BlendBuilder.bytes([Int32(0), 1]), 2)]
            values["attribute_storage.dna_attributes"] = .pointer(table); values["attribute_storage.dna_attributes_num"] = .int(entries.count)
            after.append {
                _ = raw(BlendBuilder.bytes([Int32(0), 4, 7]), at: offsets)
                _ = raw(Data("UVMap".utf8) + Data([0]), at: wanted)
                let nameAt = entries.map { _ in b.reserve() }, holderAt = entries.map { _ in b.reserve() }, dataAt = entries.map { _ in b.reserve() }
                var bytes = Data()
                for (i, e) in entries.enumerated() { bytes += b.record("Attribute", ["name": .pointer(nameAt[i]), "data_type": .int(e.1), "domain": .int(e.2), "storage_type": .int(e.3 ? 1 : 0), "data": .pointer(holderAt[i])]) }
                b.add("DATA", "Attribute", bytes, count: entries.count, at: table)
                for (i, e) in entries.enumerated() {
                    _ = raw(Data(e.0.utf8) + Data([0]), at: nameAt[i])
                    b.add("DATA", "AttributeArray", b.record("AttributeArray", ["data": .pointer(dataAt[i]), "size": .int(e.5)]), at: holderAt[i])
                    _ = raw(e.4, at: dataAt[i])
                }
            }
        }
        b.add("ME", "Mesh", b.record("Mesh", values), at: mesh)
        _ = raw(BlendBuilder.bytes([red, picture]), at: slots)
        after.forEach { $0() }

        // Materials.
        func socket(_ name: String, colour: [Float]? = nil, number: Float? = nil, typed: Bool) -> (record: [String: V], value: (UInt64, Data, String)?) {
            guard colour != nil || number != nil else { return (["identifier": .text(name)], nil) }
            let at = b.reserve()
            let bytes = colour.map { b.record("bNodeSocketValueRGBA", ["value": .floats($0)]) } ?? b.record("bNodeSocketValueFloat", ["value": .float(number!)])
            return (["identifier": .text(name), "default_value": .pointer(at)], (at, bytes, typed ? (colour != nil ? "bNodeSocketValueRGBA" : "bNodeSocketValueFloat") : "Link"))
        }
        /// Adds a node's sockets after the node; gives the address of each by name.
        func sockets(_ made: [(record: [String: V], value: (UInt64, Data, String)?)]) -> (first: UInt64, addresses: [UInt64], add: () -> Void) {
            let at = made.map { _ in b.reserve() }
            return (at.first ?? 0, at, {
                _ = list("bNodeSocket", made.map(\.record), addresses: at)
                for m in made { if let v = m.value { b.add("DATA", v.2, v.1, at: v.0) } }
            })
        }
        // Older files do not say what a socket's value is; newer ones do.
        let typed = layout != .records
        do {
            let tree = b.reserve(), stray = b.reserve(), principled = b.reserve(), output = b.reserve(), linkAt = b.reserve()
            b.add("MA", "Material", b.record("Material", ["id.name": .text("MARed"), "r": .float(0.1), "g": .float(0.2), "b": .float(0.3), "a": .float(1), "metallic": .float(0.9), "roughness": .float(0.1), "nodetree": .pointer(tree)]), at: red)
            b.add("DATA", "bNodeTree", b.record("bNodeTree", ["nodes.first": .pointer(stray), "links.first": .pointer(linkAt)]), at: tree)
            let straySockets = sockets([socket("Base Color", colour: [0, 1, 0, 1], typed: typed)])
            let mainSockets = sockets([socket("Base Color", colour: [0.5, 0, 0, 1], typed: typed), socket("Metallic", number: 0.25, typed: typed), socket("Roughness", number: 0.75, typed: typed),
                                       socket("Alpha", number: 0.5, typed: typed), socket(layout == .records ? "Emission" : "Emission Color", colour: [0, 0, 1, 1], typed: typed),
                                       socket("Emission Strength", number: 2, typed: typed)])
            let outputSockets = sockets([socket("Surface", typed: typed)])
            _ = list("bNode", [["idname": .text("ShaderNodeBsdfPrincipled"), "inputs.first": .pointer(straySockets.first)],
                               ["idname": .text("ShaderNodeBsdfPrincipled"), "inputs.first": .pointer(mainSockets.first)],
                               ["idname": .text("ShaderNodeOutputMaterial"), "inputs.first": .pointer(outputSockets.first)]], addresses: [stray, principled, output])
            straySockets.add(); mainSockets.add(); outputSockets.add()
            _ = list("bNodeLink", [["fromnode": .pointer(principled), "tosock": .pointer(outputSockets.addresses[0])]], addresses: [linkAt])
        }
        do {
            let tree = b.reserve(), principled = b.reserve(), texture = b.reserve(), linkAt = b.reserve()
            b.add("MA", "Material", b.record("Material", ["id.name": .text("MAPicture"), "r": .float(1), "g": .float(1), "b": .float(1), "a": .float(1), "roughness": .float(0.5), "nodetree": .pointer(tree)]), at: picture)
            b.add("DATA", "bNodeTree", b.record("bNodeTree", ["nodes.first": .pointer(principled), "links.first": .pointer(linkAt)]), at: tree)
            let mainSockets = sockets([socket("Base Color", colour: [0.2, 0.2, 0.2, 1], typed: typed)])
            _ = list("bNode", [["idname": .text("ShaderNodeBsdfPrincipled"), "inputs.first": .pointer(mainSockets.first)],
                               ["idname": .text("ShaderNodeTexImage"), "id": .pointer(image)]], addresses: [principled, texture])
            mainSockets.add()
            _ = list("bNodeLink", [["fromnode": .pointer(texture), "tosock": .pointer(mainSockets.addresses[0])]], addresses: [linkAt])
        }
        do {
            let entry = b.reserve(), file = b.reserve(), bytes = b.reserve()
            b.add("IM", "Image", b.record("Image", ["id.name": .text("IMpicture.png"), "packedfiles.first": .pointer(externalImage == nil ? entry : 0), "filepath": .text(externalImage ?? "")]), at: image)
            _ = list("ImagePackedFile", [["packedfile": .pointer(file)]], addresses: [entry])
            b.add("DATA", "PackedFile", b.record("PackedFile", ["size": .int(packed.count), "data": .pointer(bytes)]), at: file)
            _ = raw(packed, at: bytes)
        }
        return b.build()
    }
}
