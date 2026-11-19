import Foundation
import ModelCore
import simd

extension Document {
    /// The file as a `ModelScene`.
    mutating func scene() throws -> ModelScene {
        let nodes = root["nodes"] as? [Object] ?? []
        guard nodes.count <= GLTFReader.maxNodes else { throw Failure.unsupported(L10n.text("it has too many nodes")) }
        let materials = try readMaterials()

        // The default scene's roots, or every node that is nobody's child.
        var roots: [Int] = []
        let scenes = root["scenes"] as? [Object] ?? []
        if let chosen = scenes.indices.contains(Self.int(root["scene"]) ?? 0) ? scenes[Self.int(root["scene"]) ?? 0] : scenes.first {
            roots = (chosen["nodes"] as? [Any] ?? []).compactMap(Self.int)
        } else {
            var isChild = Set<Int>()
            for node in nodes { for child in (node["children"] as? [Any] ?? []).compactMap(Self.int) { isChild.insert(child) } }
            roots = nodes.indices.filter { !isChild.contains($0) }
        }

        let facesAway = (root["extensions"] as? Object)?["VRM"] != nil
        var meshOf: [Int: Int?] = [:]
        var statistics: [Int: (faces: Int, vertices: Int)] = [:]
        var visited = Set<Int>()
        // For each node of the scene: the file's node it came from.
        var source: [Int] = []
        // Depth first, without recursion: a file can nest its nodes very deep.
        var pending: [(node: Int, parent: Int?, depth: Int)] = roots.reversed().map { ($0, nil, 0) }
        while let (index, parent, depth) = pending.popLast() {
            guard nodes.indices.contains(index), depth <= GLTFReader.maxDepth, visited.insert(index).inserted else { continue }
            let node = nodes[index]
            var made = ModelScene.Node(name: node["name"] as? String ?? "", parent: parent, transform: Self.transform(of: node))
            // A VRM 0.x avatar faces away from the viewer; it is turned around, as the newer ones stand.
            if parent == nil, facesAway { made.transform = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))) * made.transform }
            if (node["extensions"] as? Object)?["EXT_mesh_gpu_instancing"] != nil { note("instanced copies of a mesh") }
            if let mesh = Self.int(node["mesh"]) {
                if meshOf[mesh] == nil {
                    let (converted, faces, vertices, bound) = try readMesh(mesh, materials: materials)
                    if let converted {
                        influences[mesh] = bound
                        out.meshes.append(converted)
                        meshOf[mesh] = out.meshes.count - 1
                        statistics[mesh] = (faces, vertices)
                    } else {
                        meshOf[mesh] = .some(nil)
                    }
                }
                if let known = meshOf[mesh] ?? nil {
                    made.mesh = known
                    // Counted once for every place the mesh stands in.
                    if let (faces, vertices) = statistics[mesh] {
                        out.topology.faces += faces
                        out.topology.triangles += faces
                        out.topology.vertices += vertices
                    }
                }
            }
            out.nodes.append(made)
            source.append(index)
            let me = out.nodes.count - 1
            for child in (node["children"] as? [Any] ?? []).compactMap(Self.int).reversed() { pending.append((child, me, depth + 1)) }
        }
        // Motion with nothing to move (a VRM animation) is shown on its skeleton.
        if out.meshes.isEmpty, !(root["animations"] as? [Any] ?? []).isEmpty, !out.addStickFigure() { throw Failure.empty }
        guard !out.meshes.isEmpty else { throw Failure.empty }
        try animate(nodes: nodes, source: source)
        return out
    }

    /// A node's placement: its matrix, or translation, rotation and scale.
    static func transform(of node: Object) -> simd_float4x4 {
        if let m = floats(node["matrix"], count: 16) {
            return simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
        }
        let t = floats(node["translation"], count: 3) ?? [0, 0, 0]
        let r = floats(node["rotation"], count: 4) ?? [0, 0, 0, 1]
        let s = floats(node["scale"], count: 3) ?? [1, 1, 1]
        let q = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
        return ModelScene.Skeleton.compose(SIMD3(t[0], t[1], t[2]), simd_length(q.vector) > 0 ? q : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), SIMD3(s[0], s[1], s[2]))
    }

    // MARK: Materials

    /// What a primitive needs to know of its material: where it is in the scene and which
    /// set of texture coordinates its colour image uses.
    struct MaterialUse {
        var index: Int
        var uvSet: Int
        /// How the colour image is placed on the surface, when the file moves it.
        var placement: Placement?
    }

    /// `KHR_texture_transform`: the texture coordinates are scaled, turned and moved.
    struct Placement: Equatable {
        var offset = SIMD2<Float>(0, 0)
        var rotation: Float = 0
        var scale = SIMD2<Float>(1, 1)

        func apply(_ uv: SIMD2<Float>) -> SIMD2<Float> {
            let s = uv * scale, c = cos(rotation), n = sin(rotation)
            return SIMD2(c * s.x - n * s.y, n * s.x + c * s.y) + offset
        }
    }

    /// Fold the material factor into the texture threshold. Values above one reject
    /// the entire surface, including when there is no image (implicit texture alpha 1).
    static func alphaThreshold(cutoff: Float, factor: Float) -> Float {
        let cutoff = max(0, cutoff), factor = min(1, max(0, factor))
        if factor == 0 { return cutoff > 0 ? 2 : 0 }
        return min(2, cutoff / factor)
    }

    static func toSRGB(_ v: Float) -> Float {
        let c = min(1, max(0, v))
        // One stays exactly one: a white material must not come out a shade under white.
        return c <= 0.0031308 ? c * 12.92 : min(1, 1.055 * pow(c, 1 / 2.4) - 0.055 + 1e-7)
    }

    mutating func note(_ feature: String) {
        if !out.diagnostics.skippedFeatures.contains(feature) { out.diagnostics.skippedFeatures.append(feature) }
    }

    private mutating func readMaterials() throws -> [MaterialUse] {
        let list = root["materials"] as? [Object] ?? []
        var imageOf: [Int: Int?] = [:]
        let textures = root["textures"] as? [Object] ?? []
        let images = root["images"] as? [Object] ?? []

        /// The scene's texture for a texture reference in a material, and its coordinate set.
        let samplers = root["samplers"] as? [Object] ?? []
        /// How the image of a texture reference continues past its edges and is enlarged.
        func sampling(_ info: Any?) -> ModelScene.TextureSampling {
            guard let info = info as? Object, let t = Self.int(info["index"]), textures.indices.contains(t),
                  let s = Self.int(textures[t]["sampler"]), samplers.indices.contains(s) else { return .init() }
            func wrap(_ value: Any?) -> ModelScene.TextureWrap { Self.int(value) == 33071 ? .clamp : Self.int(value) == 33648 ? .mirror : .repeat }
            return .init(wrapS: wrap(samplers[s]["wrapS"]), wrapT: wrap(samplers[s]["wrapT"]), sharp: Self.int(samplers[s]["magFilter"]) == 9728)
        }

        func texture(_ info: Any?) -> (index: Int, uvSet: Int, placement: Placement?)? {
            guard let info = info as? Object, let t = Self.int(info["index"]), textures.indices.contains(t) else { return nil }
            var placement: Placement?
            var moved: Int?
            if let transform = (info["extensions"] as? Object)?["KHR_texture_transform"] as? Object {
                var made = Placement()
                if let o = Self.floats(transform["offset"], count: 2) { made.offset = SIMD2(o[0], o[1]) }
                if let s = Self.floats(transform["scale"], count: 2) { made.scale = SIMD2(s[0], s[1]) }
                made.rotation = Self.float(transform["rotation"]) ?? 0
                if made != Placement() { placement = made }
                moved = Self.int(transform["texCoord"])
            }
            let entry = textures[t]
            let source = Self.int(entry["source"]) ?? Self.int(((entry["extensions"] as? Object)?["EXT_texture_webp"] as? Object)?["source"])
            guard let source, images.indices.contains(source) else { return nil }
            if imageOf[source] == nil {
                let image = images[source]
                var bytes: Data?
                var name = image["name"] as? String ?? "image \(source)"
                if let viewIndex = Self.int(image["bufferView"]) {
                    bytes = try? view(viewIndex).data
                } else if let uri = image["uri"] as? String {
                    if !uri.hasPrefix("data:") { name = ((uri.removingPercentEncoding ?? uri) as NSString).lastPathComponent }
                    bytes = self.bytes(uri: uri)
                }
                if let bytes, !bytes.isEmpty {
                    out.textures.append(.embedded(bytes: [UInt8](bytes), mime: image["mimeType"] as? String ?? ""))
                    imageOf[source] = out.textures.count - 1
                } else {
                    out.diagnostics.missingResources.append(name)
                    imageOf[source] = .some(nil)
                }
            }
            guard let index = imageOf[source] ?? nil else { return nil }
            return (index, moved ?? Self.int(info["texCoord"]) ?? 0, placement)
        }

        // VRM 0.x keeps its cartoon materials as the properties of the Unity material they came from.
        let oldProperties = ((root["extensions"] as? Object)?["VRM"] as? Object)?["materialProperties"] as? [Object] ?? []
        var uses: [MaterialUse] = []
        for (materialIndex, entry) in list.enumerated() {
            var material = ModelScene.Material()
            material.name = entry["name"] as? String ?? ""
            material.authoredPBR = true
            material.normalYSign = 1
            material.metallic = 1
            material.roughness = 1
            var colour: [Float] = [1, 1, 1, 1]
            var colour4: Float = 1
            var uvSet = 0
            // The colour image decides which texture coordinates the part carries and how
            // they are placed; an image that wants others, or another placement, is left out.
            var placement: Placement?
            var decided = false
            func fits(_ found: (index: Int, uvSet: Int, placement: Placement?)) -> Bool {
                if !decided { uvSet = found.uvSet; placement = found.placement; decided = true; return true }
                if found.uvSet == uvSet && found.placement == placement { return true }
                note("images placed differently on one surface")
                return false
            }
            let extensions = entry["extensions"] as? Object ?? [:]
            if let old = extensions["KHR_materials_pbrSpecularGlossiness"] as? Object, entry["pbrMetallicRoughness"] == nil {
                // The older model: its diffuse colour and image, shininess turned into roughness.
                colour = Self.floats(old["diffuseFactor"], count: 4) ?? colour
                material.metallic = 0
                material.roughness = 1 - min(1, max(0, Self.float(old["glossinessFactor"]) ?? 1))
                if let found = texture(old["diffuseTexture"]), fits(found) { material.baseColorTexture = found.index; material.sampling = sampling(old["diffuseTexture"]) }
            } else if let pbr = entry["pbrMetallicRoughness"] as? Object {
                colour = Self.floats(pbr["baseColorFactor"], count: 4) ?? colour
                material.metallic = min(1, max(0, Self.float(pbr["metallicFactor"]) ?? 1))
                material.roughness = min(1, max(0, Self.float(pbr["roughnessFactor"]) ?? 1))
                if let found = texture(pbr["baseColorTexture"]), fits(found) { material.baseColorTexture = found.index; material.sampling = sampling(pbr["baseColorTexture"]) }
                if let found = texture(pbr["metallicRoughnessTexture"]), fits(found) { material.metallicRoughnessTexture = found.index; material.metallicRoughnessSampling = sampling(pbr["metallicRoughnessTexture"]) }
            }
            if let found = texture(entry["normalTexture"]), fits(found) {
                material.normalTexture = found.index
                material.normalSampling = sampling(entry["normalTexture"])
                material.normalScale = Self.float((entry["normalTexture"] as? Object)?["scale"]) ?? 1
            }
            // What the surface gives off by itself, stronger where the file says so.
            var glow = Self.floats(entry["emissiveFactor"], count: 3) ?? [0, 0, 0]
            let strength = max(0, Self.float((extensions["KHR_materials_emissive_strength"] as? Object)?["emissiveStrength"]) ?? 1)
            glow = glow.map { max(0, $0) * strength }
            if glow.contains(where: { $0 > 0 }) {
                material.emissive = SIMD3(glow[0], glow[1], glow[2])
                if entry["emissiveTexture"] != nil {
                    // Without its image the glow would cover the whole surface: none, then.
                    if let found = texture(entry["emissiveTexture"]), fits(found) { material.emissiveTexture = found.index; material.emissiveSampling = sampling(entry["emissiveTexture"]) } else { material.emissive = .zero }
                }
            }
            // The file's colours are linear; the scene's are as seen on screen.
            material.baseColor = SIMD4(Self.toSRGB(colour[0]), Self.toSRGB(colour[1]), Self.toSRGB(colour[2]), 1)
            material.doubleSided = entry["doubleSided"] as? Bool ?? false
            material.oneSided = !material.doubleSided
            material.unlit = extensions["KHR_materials_unlit"] != nil
            switch entry["alphaMode"] as? String ?? "OPAQUE" {
            case "BLEND":
                material.alphaBlend = true
                material.opacity = min(1, max(0, colour[3]))
            case "MASK":
                // The image's alpha against the threshold, with the material's own alpha counted in.
                let cutoff = Self.float(entry["alphaCutoff"]) ?? 0.5
                material.alphaCutoff = Self.alphaThreshold(cutoff: cutoff, factor: colour[3])
            default:
                break
            }
            if let mtoon = extensions["VRMC_materials_mtoon"] as? Object {
                var toon = ModelScene.Toon()
                let shade = Self.floats(mtoon["shadeColorFactor"], count: 3) ?? [1, 1, 1]
                toon.shadeColor = SIMD3(Self.toSRGB(shade[0]), Self.toSRGB(shade[1]), Self.toSRGB(shade[2]))
                if let found = texture(mtoon["shadeMultiplyTexture"]), fits(found) { toon.shadeTexture = found.index }
                toon.shift = Self.float(mtoon["shadingShiftFactor"]) ?? 0
                toon.toony = Self.float(mtoon["shadingToonyFactor"]) ?? 0.9
                let mode = mtoon["outlineWidthMode"] as? String ?? "none"
                if mode != "none" {
                    toon.outlineWidth = max(0, Self.float(mtoon["outlineWidthFactor"]) ?? 0)
                    toon.outlineOnScreen = mode == "screenCoordinates"
                }
                let line = Self.floats(mtoon["outlineColorFactor"], count: 3) ?? [0, 0, 0]
                toon.outlineColor = SIMD3(Self.toSRGB(line[0]), Self.toSRGB(line[1]), Self.toSRGB(line[2]))
                toon.outlineLightingMix = min(1, max(0, Self.float(mtoon["outlineLightingMixFactor"]) ?? 1))
                if toon.outlineWidth > 0, let found = texture(mtoon["outlineWidthMultiplyTexture"]), fits(found) { toon.outlineWidthTexture = found.index }
                if let found = texture(mtoon["shadingShiftTexture"]), fits(found) {
                    toon.shiftTexture = found.index
                    toon.shiftTextureScale = Self.float((mtoon["shadingShiftTexture"] as? Object)?["scale"]) ?? 1
                }
                // The matcap is looked up by the surface's direction, not by its coordinates.
                if let found = texture(mtoon["matcapTexture"]) { toon.matcapTexture = found.index }
                let factor = Self.floats(mtoon["matcapFactor"], count: 3) ?? [1, 1, 1]
                toon.matcapColor = SIMD3(max(0, factor[0]), max(0, factor[1]), max(0, factor[2]))
                let rim = Self.floats(mtoon["parametricRimColorFactor"], count: 3) ?? [0, 0, 0]
                toon.rimColor = SIMD3(Self.toSRGB(rim[0]), Self.toSRGB(rim[1]), Self.toSRGB(rim[2]))
                toon.rimFresnelPower = max(0, Self.float(mtoon["parametricRimFresnelPowerFactor"]) ?? 5)
                toon.rimLift = Self.float(mtoon["parametricRimLiftFactor"]) ?? 0
                if let found = texture(mtoon["rimMultiplyTexture"]), fits(found) { toon.rimTexture = found.index }
                toon.rimLightingMix = min(1, max(0, Self.float(mtoon["rimLightingMixFactor"]) ?? 1))
                toon.uvScroll = SIMD2(Self.float(mtoon["uvAnimationScrollXSpeedFactor"]) ?? 0, Self.float(mtoon["uvAnimationScrollYSpeedFactor"]) ?? 0)
                toon.uvRotation = Self.float(mtoon["uvAnimationRotationSpeedFactor"]) ?? 0
                if toon.uvScroll != .zero || toon.uvRotation != 0, let found = texture(mtoon["uvAnimationMaskTexture"]), fits(found) { toon.uvMaskTexture = found.index }
                material.toon = toon
                material.unlit = false
            } else if oldProperties.indices.contains(materialIndex), let shader = oldProperties[materialIndex]["shader"] as? String, shader != "VRM_USE_GLTFSHADER" {
                let p = oldProperties[materialIndex]
                let numbers = p["floatProperties"] as? Object ?? [:], vectors = p["vectorProperties"] as? Object ?? [:], images = p["textureProperties"] as? Object ?? [:]
                func number(_ key: String) -> Float? { Self.float(numbers[key]) }
                // These colours are already as seen on screen.
                func colour(_ key: String) -> [Float]? { (vectors[key] as? [Any]).flatMap { $0.count >= 3 ? $0.map { Self.float($0) ?? 0 } : nil } }
                func image(_ key: String) -> Int? {
                    guard let t = Self.int(images[key]) else { return nil }
                    return texture(["index": t]).flatMap { fits($0) ? $0.index : nil }
                }
                if let c = colour("_Color") {
                    material.baseColor = SIMD4(min(1, max(0, c[0])), min(1, max(0, c[1])), min(1, max(0, c[2])), 1)
                    colour4 = c.count > 3 ? c[3] : 1
                }
                if let t = image("_MainTex") { material.baseColorTexture = t }
                let blend = Self.int(numbers["_BlendMode"]) ?? 0
                material.opacity = 1
                material.alphaBlend = false
                material.alphaCutoff = nil
                if blend == 1 {
                    material.alphaCutoff = Self.alphaThreshold(cutoff: number("_Cutoff") ?? 0.5, factor: colour4)
                } else if blend >= 2 {
                    material.alphaBlend = true
                    material.opacity = colour4
                }
                material.doubleSided = (Self.int(numbers["_CullMode"]) ?? 2) == 0
                material.oneSided = !material.doubleSided
                if shader == "VRM/MToon" {
                    var toon = ModelScene.Toon()
                    if let c = colour("_ShadeColor") { toon.shadeColor = SIMD3(min(1, max(0, c[0])), min(1, max(0, c[1])), min(1, max(0, c[2]))) }
                    toon.shadeTexture = image("_ShadeTexture")
                    // The older pair of numbers, brought to the newer one as three-vrm does.
                    let shift = number("_ShadeShift") ?? 0, toony = number("_ShadeToony") ?? 0.9
                    toon.toony = toony + (1 - toony) * (0.5 + 0.5 * shift)
                    toon.shift = -shift - (1 - toon.toony)
                    let mode = Self.int(numbers["_OutlineWidthMode"]) ?? 0
                    if mode != 0 {
                        // Centimetres there, metres here.
                        toon.outlineWidth = max(0, number("_OutlineWidth") ?? 0) * 0.01
                        toon.outlineOnScreen = mode == 2
                    }
                    if let c = colour("_OutlineColor") { toon.outlineColor = SIMD3(min(1, max(0, c[0])), min(1, max(0, c[1])), min(1, max(0, c[2]))) }
                    toon.outlineLightingMix = (Self.int(numbers["_OutlineColorMode"]) ?? 0) == 1 ? min(1, max(0, number("_OutlineLightingMix") ?? 1)) : 0
                    if toon.outlineWidth > 0 { toon.outlineWidthTexture = image("_OutlineWidthTexture") }
                    if let t = Self.int(images["_SphereAdd"]), let found = texture(["index": t]) { toon.matcapTexture = found.index }
                    if let c = colour("_RimColor") { toon.rimColor = SIMD3(min(1, max(0, c[0])), min(1, max(0, c[1])), min(1, max(0, c[2]))) }
                    toon.rimFresnelPower = max(0, number("_RimFresnelPower") ?? 1)
                    toon.rimLift = number("_RimLift") ?? 0
                    toon.rimTexture = image("_RimTexture")
                    toon.rimLightingMix = min(1, max(0, number("_RimLightingMix") ?? 0))
                    // Brought to the newer form as three-vrm does: that format counts an image
                    // from its bottom edge, so it slides the other way; the turning is taken as it is.
                    toon.uvScroll = SIMD2(number("_UvAnimScrollX") ?? 0, -(number("_UvAnimScrollY") ?? 0))
                    toon.uvRotation = number("_UvAnimRotation") ?? 0
                    if toon.uvScroll != .zero || toon.uvRotation != 0 { toon.uvMaskTexture = image("_UvAnimMaskTexture") }
                    material.toon = toon
                    material.unlit = false
                    material.metallic = 0
                    material.roughness = 1
                    if let glow = colour("_EmissionColor"), glow.prefix(3).contains(where: { $0 > 0 }) {
                        func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                        material.emissive = SIMD3(linear(max(0, glow[0])), linear(max(0, glow[1])), linear(max(0, glow[2])))
                        material.emissiveTexture = image("_EmissionMap")
                    }
                } else if shader.hasPrefix("VRM/Unlit") {
                    material.unlit = true
                }
            }
            out.materials.append(material)
            uses.append(MaterialUse(index: out.materials.count - 1, uvSet: uvSet, placement: placement))
        }
        return uses
    }

    // MARK: Meshes

    /// The material for primitives that name none: white, as the format defines it.
    private mutating func defaultMaterial() -> Int {
        if let known = out.materials.firstIndex(where: { $0.name == "\u{0}default" }) { return known }
        var material = ModelScene.Material()
        material.name = "\u{0}default"
        material.oneSided = true
        material.baseColor = SIMD4(1, 1, 1, 1)
        material.metallic = 1
        material.roughness = 1
        material.authoredPBR = true
        material.normalYSign = 1
        out.materials.append(material)
        return out.materials.count - 1
    }

    private mutating func readMesh(_ index: Int, materials: [MaterialUse]) throws -> (ModelScene.Mesh?, faces: Int, vertices: Int, bound: [Influences?]) {
        let meshes = root["meshes"] as? [Object] ?? []
        guard meshes.indices.contains(index) else { return (nil, 0, 0, []) }
        var bound: [Influences?] = []
        var mesh = ModelScene.Mesh(name: meshes[index]["name"] as? String ?? "")
        mesh.morphWeights = (meshes[index]["weights"] as? [Any] ?? []).map { Self.float($0) ?? 0 }
        var faces = 0, vertices = 0
        var counted = Set<Int>()
        for primitive in meshes[index]["primitives"] as? [Object] ?? [] {
            let use = Self.int(primitive["material"]).flatMap { materials.indices.contains($0) ? materials[$0] : nil }
            guard let (part, influence) = try readPrimitive(primitive, uvSet: use?.uvSet ?? 0) else { continue }
            bound.append(influence)
            var placed = part
            placed.material = use?.index ?? defaultMaterial()
            if let placement = use?.placement { placed.uv0 = placed.uv0.map(placement.apply) }
            faces += part.triangleIndices.count / 3
            // Parts may share their vertices (one list, several materials): those count once.
            let shared = Self.int((primitive["attributes"] as? Object)?["POSITION"])
            if shared == nil || counted.insert(shared!).inserted { vertices += part.positions.count }
            mesh.parts.append(placed)
        }
        // Every part of a mesh has the same targets; a mesh whose parts disagree has none.
        let targets = mesh.parts.first?.morphTargets.count ?? 0
        if mesh.parts.contains(where: { $0.morphTargets.count != targets }) {
            for p in mesh.parts.indices { mesh.parts[p].morphTargets = [] }
        }
        return (mesh.parts.isEmpty ? nil : mesh, faces, vertices, bound)
    }

    private mutating func readPrimitive(_ primitive: Object, uvSet: Int) throws -> (ModelScene.MeshPart, Influences?)? {
        if let extensions = primitive["extensions"] as? Object, extensions["KHR_draco_mesh_compression"] != nil {
            throw Failure.unsupported(L10n.text("Draco-compressed models are not supported"))
        }
        let mode = Self.int(primitive["mode"]) ?? 4
        guard [0, 4, 5, 6].contains(mode) else {
            note("lines")
            return nil
        }
        guard let attributes = primitive["attributes"] as? Object, let positionAccessor = Self.int(attributes["POSITION"]) else { return nil }
        let (p, _, count) = try floats(positionAccessor, components: 3)
        guard count > 0 else { return nil }
        var part = ModelScene.MeshPart()
        part.positions = (0..<count).map { SIMD3(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }

        if let accessor = Self.int(attributes["NORMAL"]) {
            let (n, _, found) = try floats(accessor, components: 3)
            if found == count { part.normals = (0..<count).map { SIMD3(n[$0 * 3], n[$0 * 3 + 1], n[$0 * 3 + 2]) } }
        }
        // Absent normals are implicitly flat, including when morphs change positions.
        part.faceted = part.normals.isEmpty
        if let accessor = Self.int(attributes["TEXCOORD_\(uvSet)"]) {
            let (t, _, found) = try floats(accessor, components: 2)
            if found == count { part.uv0 = (0..<count).map { SIMD2(t[$0 * 2], t[$0 * 2 + 1]) } }
        }
        if let accessor = Self.int(attributes["COLOR_0"]) {
            let (c, n, found) = try floats(accessor)
            if found == count, n == 3 || n == 4 {
                part.colors = (0..<count).map { SIMD4(Self.toSRGB(c[$0 * n]), Self.toSRGB(c[$0 * n + 1]), Self.toSRGB(c[$0 * n + 2]), n == 4 ? min(1, max(0, c[$0 * n + 3])) : 1) }
            }
        }

        // Which joints of the node's skin move each vertex, and how much.
        var influence: Influences?
        if let jointAccessor = Self.int(attributes["JOINTS_0"]), let weightAccessor = Self.int(attributes["WEIGHTS_0"]) {
            let j = try wholes(jointAccessor, components: 4)
            let (w, _, found) = try floats(weightAccessor, components: 4)
            if found == count, j.count == count * 4 {
                influence = Influences(
                    joints: (0..<count).map { SIMD4(UInt16(min(j[$0 * 4], 65535)), UInt16(min(j[$0 * 4 + 1], 65535)), UInt16(min(j[$0 * 4 + 2], 65535)), UInt16(min(j[$0 * 4 + 3], 65535))) },
                    weights: (0..<count).map { SIMD4(w[$0 * 4], w[$0 * 4 + 1], w[$0 * 4 + 2], w[$0 * 4 + 3]) })
            }
            if attributes["JOINTS_1"] != nil { note("more than four joints for a vertex") }
        }
        // The part's other shapes: what each adds to the positions and, if given, the normals.
        for target in primitive["targets"] as? [Object] ?? [] {
            var shape = ModelScene.MorphTarget()
            if let accessor = Self.int(target["POSITION"]) {
                let (d, _, found) = try floats(accessor, components: 3)
                if found == count { shape.positions = (0..<count).map { SIMD3(d[$0 * 3], d[$0 * 3 + 1], d[$0 * 3 + 2]) } }
            }
            if shape.positions.isEmpty { shape.positions = [SIMD3<Float>](repeating: .zero, count: count) }
            if let accessor = Self.int(target["NORMAL"]), !part.normals.isEmpty {
                let (d, _, found) = try floats(accessor, components: 3)
                if found == count { shape.normals = (0..<count).map { SIMD3(d[$0 * 3], d[$0 * 3 + 1], d[$0 * 3 + 2]) } }
            }
            part.morphTargets.append(shape)
            if part.morphTargets.count >= 512 { break }
        }

        if mode == 0 {
            if let accessor = Self.int(primitive["indices"]) {
                let order = try wholes(accessor).filter { $0 < UInt32(count) }.map(Int.init)
                guard !order.isEmpty else { return nil }
                func selected<T>(_ values: [T]) -> [T] { values.count == count ? order.map { values[$0] } : [] }
                part.positions = selected(part.positions)
                part.normals = selected(part.normals)
                part.uv0 = selected(part.uv0)
                part.colors = selected(part.colors)
                for i in part.morphTargets.indices {
                    part.morphTargets[i].positions = selected(part.morphTargets[i].positions)
                    part.morphTargets[i].normals = selected(part.morphTargets[i].normals)
                }
                if let original = influence { influence = Influences(joints: selected(original.joints), weights: selected(original.weights)) }
            }
            part.primitive = .points
            return (part, influence)
        }
        var order: [UInt32]
        if let accessor = Self.int(primitive["indices"]) {
            order = try wholes(accessor)
        } else {
            order = (0..<UInt32(count)).map { $0 }
        }
        var triangles: [UInt32] = []
        switch mode {
        case 5:
            // A strip: every vertex after the second closes a triangle, turning alternately.
            guard order.count >= 3 else { return nil }
            triangles.reserveCapacity((order.count - 2) * 3)
            for i in 0..<(order.count - 2) {
                triangles.append(order[i])
                triangles.append(order[i + (i % 2 == 0 ? 1 : 2)])
                triangles.append(order[i + (i % 2 == 0 ? 2 : 1)])
            }
        case 6:
            guard order.count >= 3 else { return nil }
            triangles.reserveCapacity((order.count - 2) * 3)
            for i in 1..<(order.count - 1) { triangles.append(order[0]); triangles.append(order[i]); triangles.append(order[i + 1]) }
        default:
            order.removeLast(order.count % 3)
            triangles = order
        }
        // Triangles that point outside the vertices are left out.
        let limit = UInt32(count)
        if triangles.contains(where: { $0 >= limit }) {
            var kept: [UInt32] = []
            kept.reserveCapacity(triangles.count)
            for t in stride(from: 0, to: triangles.count, by: 3) where triangles[t] < limit && triangles[t + 1] < limit && triangles[t + 2] < limit {
                kept.append(contentsOf: triangles[t..<(t + 3)])
            }
            triangles = kept
        }
        guard !triangles.isEmpty else { return nil }
        part.triangleIndices = triangles
        return (part, influence)
    }
}
