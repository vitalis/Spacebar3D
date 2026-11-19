import Assimp
import Foundation
import ModelCore
import simd

/// Reads 3D Studio and FBX files through Assimp's C interface into a `ModelScene`: the
/// node tree with its placements, meshes with their polygons, normals, texture coordinates
/// and colours, each material's colour and images, and for FBX the bones that move the
/// meshes and the animations that move the bones.
///
/// The file is handed to Assimp from memory, so Assimp itself opens nothing on disk.
public enum AssimpImporter {
    public enum Failure: Error, LocalizedError, Equatable {
        case tooLarge
        case unreadable(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return L10n.text("The file is too large to show.")
            case .unreadable(let why): return why.isEmpty ? L10n.text("The file could not be read.") : L10n.format("The file could not be read: %@", String(describing: why))
            case .empty: return L10n.text("The file contains no geometry.")
            }
        }
    }

    /// Assimp keeps the whole file and builds its own scene beside ours.
    public static let maxBytes = 512 * 1024 * 1024
    /// Formats read here.
    public static let formats: Set<Format> = [.threeDS, .fbx]

    public static func load(_ url: URL, format: Format) throws -> ModelScene {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try scene(from: data, format: format, sidecars: SidecarFolder(modelURL: url))
    }

    /// `sidecars` is where images the file names are asked for; they are read only when
    /// they can be (the sandbox hides them until the folder is granted).
    public static func scene(from data: Data, format: Format, sidecars: SidecarSource? = nil) throws -> ModelScene {
        let hint: String
        switch format {
        case .threeDS: hint = "3ds"
        case .fbx: hint = "fbx"
        default: throw Failure.unreadable(L10n.format("%@ is not read through Assimp", String(describing: format.rawValue)))
        }
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        // Vertices that are the same in every respect are merged; nothing is triangulated,
        // so the file's polygons survive.
        let flags = UInt32(aiProcess_JoinIdenticalVertices.rawValue)
        let imported: UnsafePointer<aiScene>? = data.withUnsafeBytes { raw in
            aiImportFileFromMemory(raw.bindMemory(to: CChar.self).baseAddress, UInt32(raw.count), flags, hint)
        }
        guard let imported else { throw Failure.unreadable(String(cString: aiGetErrorString())) }
        defer { aiReleaseImport(imported) }

        var builder = Builder(pointer: imported, sidecars: sidecars)
        // An FBX corner with its own normal or texture coordinate arrives as its own
        // vertex; the points the file has are counted, as they were authored.
        builder.countsPoints = format == .fbx
        guard let root = imported.pointee.mRootNode else { throw Failure.empty }
        // Assimp's 3D Studio reader has already turned its scene to Y up.
        builder.scene.nodes.append(ModelScene.Node(name: "up", transform: matrix_identity_float4x4))
        builder.visit(root, parent: 0, depth: 0)
        if builder.scene.topology.faces == 0 {
            // Motion with nothing to move is shown on its skeleton.
            guard imported.pointee.mNumAnimations > 0, builder.scene.addStickFigure() else { throw Failure.empty }
        }
        builder.animate()
        return builder.scene
    }

    private struct Builder {
        /// Assimp's scene; it stays alive until `scene(from:)` releases it.
        let pointer: UnsafePointer<aiScene>
        var source: aiScene { pointer.pointee }
        let sidecars: SidecarSource?
        var scene = ModelScene()
        var materialIndex: [UInt32: Int] = [:]
        var textureIndex: [String: Int] = [:]
        /// Assimp mesh index to the part made from it (nil when it has nothing to draw).
        var parts: [UInt32: ModelScene.MeshPart?] = [:]
        var nodeCount = 0
        var countsPoints = false
        /// The first node of each name: bones and animations name the nodes they move.
        var nodeNamed: [String: Int] = [:]
        /// For each mesh of the scene, the Assimp mesh each of its parts came from.
        var partSources: [Int: [UInt32]] = [:]

        mutating func visit(_ node: UnsafePointer<aiNode>, parent: Int, depth: Int) {
            // Guards against a damaged tree: far deeper or larger than any real scene.
            guard depth < 512, nodeCount < 1_000_000 else { return }
            nodeCount += 1
            let n = node.pointee
            var made = ModelScene.Node(name: Self.string(n.mName), parent: parent, transform: Self.matrix(n.mTransformation))
            var meshParts: [ModelScene.MeshPart] = []
            var sources: [UInt32] = []
            if let indices = n.mMeshes {
                for i in 0..<Int(n.mNumMeshes) {
                    if let part = part(for: indices[i]) { meshParts.append(part); sources.append(indices[i]) }
                }
            }
            if !meshParts.isEmpty {
                scene.meshes.append(ModelScene.Mesh(name: made.name, parts: meshParts))
                made.mesh = scene.meshes.count - 1
                partSources[scene.meshes.count - 1] = sources
                // Counted once per place the mesh is used, as it is drawn.
                for part in meshParts {
                    scene.topology.vertices += countsPoints ? Set(part.positions.map { SIMD3($0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern) }).count : part.positions.count
                    for size in part.faceSizes ?? [UInt32](repeating: 3, count: part.triangleIndices.count / 3) { scene.topology.addFace(corners: Int(size)) }
                }
            }
            scene.nodes.append(made)
            let index = scene.nodes.count - 1
            if nodeNamed[made.name] == nil { nodeNamed[made.name] = index }
            if let children = n.mChildren {
                for i in 0..<Int(n.mNumChildren) { if let child = children[i] { visit(child, parent: index, depth: depth + 1) } }
            }
        }

        // MARK: Meshes

        private mutating func part(for index: UInt32) -> ModelScene.MeshPart? {
            if let known = parts[index] { return known }
            let made = makePart(index)
            parts[index] = made
            return made
        }

        private mutating func makePart(_ index: UInt32) -> ModelScene.MeshPart? {
            guard index < source.mNumMeshes, let meshes = source.mMeshes, let pointer = meshes[Int(index)] else { return nil }
            let mesh = pointer.pointee
            let count = Int(mesh.mNumVertices)
            guard count > 0, let vertices = mesh.mVertices, let faces = mesh.mFaces else { return nil }
            var part = ModelScene.MeshPart()
            part.positions = (0..<count).map { SIMD3(vertices[$0].x, vertices[$0].y, vertices[$0].z) }
            if let normals = mesh.mNormals {
                part.normals = (0..<count).map { SIMD3(normals[$0].x, normals[$0].y, normals[$0].z) }
                // Assimp marks normals it could not supply with not-a-number.
                if part.normals.contains(where: { !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite }) { part.normals = [] }
            }
            // Texture coordinates start at the bottom left in Assimp; ours at the top left.
            if let uvs = mesh.mTextureCoords.0 { part.uv0 = (0..<count).map { SIMD2(uvs[$0].x, 1 - uvs[$0].y) } }
            if let colors = mesh.mColors.0 { part.colors = (0..<count).map { SIMD4(colors[$0].r, colors[$0].g, colors[$0].b, colors[$0].a) } }

            var sizes: [UInt32] = []
            var onlyTriangles = true
            for f in 0..<Int(mesh.mNumFaces) {
                let face = faces[f]
                let corners = Int(face.mNumIndices)
                // Points and lines are not drawn.
                guard corners >= 3, let indices = face.mIndices, (0..<corners).allSatisfy({ Int(indices[$0]) < count }) else { continue }
                for k in 1..<(corners - 1) {
                    part.triangleIndices.append(indices[0]); part.triangleIndices.append(indices[k]); part.triangleIndices.append(indices[k + 1])
                }
                sizes.append(UInt32(corners))
                if corners != 3 { onlyTriangles = false }
            }
            guard !part.triangleIndices.isEmpty else { return nil }
            // Kept in every case here: `visit` counts the faces from it. Dropped below when all are triangles.
            part.faceSizes = onlyTriangles ? nil : sizes
            part.material = material(for: mesh.mMaterialIndex)
            // Blend shapes: Assimp gives each as the whole mesh in that shape; what it adds is kept.
            let shapes = Int(mesh.mNumAnimMeshes)
            if shapes > 0, let list = mesh.mAnimMeshes {
                if shapes <= Self.maxShapes, shapes * count <= Self.maxShapeVertices {
                    for s in 0..<shapes {
                        var target = ModelScene.MorphTarget()
                        if let shape = list[s]?.pointee, Int(shape.mNumVertices) == count, let moved = shape.mVertices {
                            target.positions = (0..<count).map {
                                let d = SIMD3(moved[$0].x, moved[$0].y, moved[$0].z) - part.positions[$0]
                                return d.x.isFinite && d.y.isFinite && d.z.isFinite ? d : .zero
                            }
                            if let turned = shape.mNormals, part.normals.count == count {
                                target.normals = (0..<count).map {
                                    let d = SIMD3(turned[$0].x, turned[$0].y, turned[$0].z) - part.normals[$0]
                                    return d.x.isFinite && d.y.isFinite && d.z.isFinite ? d : .zero
                                }
                            }
                        } else {
                            // Kept in its place, changing nothing, so that the others keep their numbers.
                            target.positions = [SIMD3<Float>](repeating: .zero, count: count)
                        }
                        part.morphTargets.append(target)
                    }
                } else if !scene.diagnostics.skippedFeatures.contains("blend shapes") {
                    scene.diagnostics.skippedFeatures.append("blend shapes")
                }
            }
            return part
        }

        // MARK: Materials

        private mutating func material(for index: UInt32) -> Int? {
            if let known = materialIndex[index] { return known }
            guard index < source.mNumMaterials, let materials = source.mMaterials, let pointer = materials[Int(index)] else { return nil }
            var material = ModelScene.Material()
            var name = aiString()
            if aiGetMaterialString(pointer, "?mat.name", 0, 0, &name) == aiReturn_SUCCESS { material.name = Self.string(name) }
            // The physically based colour when the file has one, otherwise the diffuse colour.
            var color = aiColor4D()
            if aiGetMaterialColor(pointer, "$clr.base", 0, 0, &color) == aiReturn_SUCCESS || aiGetMaterialColor(pointer, "$clr.diffuse", 0, 0, &color) == aiReturn_SUCCESS {
                material.baseColor = simd_clamp(SIMD4(color.r, color.g, color.b, 1), SIMD4(repeating: 0), SIMD4(repeating: 1))
            }
            var value: Float = 0
            var one: UInt32 = 1
            if aiGetMaterialFloatArray(pointer, "$mat.metallicFactor", 0, 0, &value, &one) == aiReturn_SUCCESS {
                material.metallic = min(max(value, 0), 1); material.authoredPBR = true
            }
            one = 1
            if aiGetMaterialFloatArray(pointer, "$mat.roughnessFactor", 0, 0, &value, &one) == aiReturn_SUCCESS {
                material.roughness = min(max(value, 0), 1); material.authoredPBR = true
            }
            one = 1
            if aiGetMaterialFloatArray(pointer, "$mat.opacity", 0, 0, &value, &one) == aiReturn_SUCCESS, value.isFinite {
                material.opacity = min(max(value, 0), 1)
            }
            var twoSided: Int32 = 0
            one = 1
            if aiGetMaterialIntegerArray(pointer, "$mat.twosided", 0, 0, &twoSided, &one) == aiReturn_SUCCESS { material.doubleSided = twoSided != 0 }
            // An FBX material that says it lets everything through is an exporter's slip
            // (the format has two ways of writing it); such a surface is shown.
            if material.opacity == 0 { material.opacity = 1 }
            if aiGetMaterialColor(pointer, "$clr.emissive", 0, 0, &color) == aiReturn_SUCCESS, color.r.isFinite, color.g.isFinite, color.b.isFinite {
                material.emissive = simd_clamp(SIMD3(color.r, color.g, color.b), SIMD3(repeating: 0), SIMD3(repeating: 1))
            }
            for (type, set) in [(aiTextureType_NORMALS, 0), (aiTextureType_EMISSIVE, 1)] {
                var path = aiString()
                guard aiGetMaterialTexture(pointer, type, 0, &path, nil, nil, nil, nil, nil, nil) == aiReturn_SUCCESS, let texture = texture(named: Self.string(path)) else { continue }
                if set == 0 { material.normalTexture = texture } else {
                    material.emissiveTexture = texture
                    // The image is the light; a colour of nothing would put it out.
                    if material.emissive == .zero { material.emissive = SIMD3(1, 1, 1) }
                }
            }
            for type in [aiTextureType_BASE_COLOR, aiTextureType_DIFFUSE] {
                var path = aiString()
                guard aiGetMaterialTexture(pointer, type, 0, &path, nil, nil, nil, nil, nil, nil) == aiReturn_SUCCESS else { continue }
                if let texture = texture(named: Self.string(path)) {
                    material.baseColorTexture = texture
                    // The image supplies the colour.
                    material.baseColor = SIMD4(1, 1, 1, 1)
                }
                break
            }
            scene.materials.append(material)
            materialIndex[index] = scene.materials.count - 1
            return scene.materials.count - 1
        }

        /// An image the file carries inside it ("*3" is its fourth), or one beside the file.
        private mutating func texture(named written: String) -> Int? {
            // Files written on Windows name their images with its separators.
            let name = written.replacingOccurrences(of: "\\", with: "/")
            guard !name.isEmpty else { return nil }
            if let known = textureIndex[name] { return known }
            var made: ModelScene.TextureRef?
            if let embedded = aiGetEmbeddedTexture(pointer, written) {
                let t = embedded.pointee
                if t.mHeight == 0, t.mWidth > 0, let bytes = t.pcData {
                    // Compressed (PNG, JPEG): `mWidth` is its length in bytes.
                    made = .embedded(bytes: Array(UnsafeRawBufferPointer(start: bytes, count: Int(t.mWidth))), mime: "")
                } else if t.mHeight > 0, t.mWidth > 0, t.mWidth <= 16384, t.mHeight <= 16384, let texels = t.pcData {
                    let pixels = Int(t.mWidth) * Int(t.mHeight)
                    var rgba = [UInt8](repeating: 255, count: pixels * 4)
                    for i in 0..<pixels { rgba[i * 4] = texels[i].r; rgba[i * 4 + 1] = texels[i].g; rgba[i * 4 + 2] = texels[i].b; rgba[i * 4 + 3] = texels[i].a }
                    made = .pixels(width: Int(t.mWidth), height: Int(t.mHeight), rgba: rgba)
                }
            } else if let data = sidecars?.data(named: name), !data.isEmpty {
                // Beside the model, under the folder's own rules.
                made = .embedded(bytes: [UInt8](data), mime: "")
            }
            guard let made else {
                scene.diagnostics.missingResources.append((name as NSString).lastPathComponent)
                return nil
            }
            scene.textures.append(made)
            textureIndex[name] = scene.textures.count - 1
            return scene.textures.count - 1
        }

        // MARK: Bones and animations

        static let samplesPerSecond: Float = 30
        static let maxKeys = 3600
        static let maxClipValues = 4_000_000
        static let maxClips = 256
        static let maxShapes = 512
        /// Shapes times vertices a mesh may hold.
        static let maxShapeVertices = 8_000_000

        /// Everything that moves is one skeleton, as for glTF: every node is a joint, every
        /// bone of a mesh is one more joint under the node it names, carrying that mesh's
        /// bind matrix, and a mesh with no bones under a moving node follows its node whole.
        mutating func animate() {
            let animations: [UnsafeMutablePointer<aiAnimation>] = (0..<Int(source.mNumAnimations)).compactMap { source.mAnimations?[$0] }
            let boned = partSources.values.contains { $0.contains { (source.mMeshes?[Int($0)]?.pointee.mNumBones ?? 0) > 0 } }
            // Every part of a mesh has the same shapes; a mesh whose parts disagree has none.
            for m in scene.meshes.indices {
                let shapes = scene.meshes[m].parts.first?.morphTargets.count ?? 0
                if scene.meshes[m].parts.contains(where: { $0.morphTargets.count != shapes }) {
                    for p in scene.meshes[m].parts.indices { scene.meshes[m].parts[p].morphTargets = [] }
                } else if shapes > 0 {
                    // At rest none of them shows.
                    scene.meshes[m].morphWeights = [Float](repeating: 0, count: shapes)
                }
            }
            let shaped = scene.meshes.contains { !$0.morphWeights.isEmpty }
            guard boned || shaped || !animations.isEmpty else { return }

            var moved = [Bool](repeating: false, count: scene.nodes.count)
            for animation in animations {
                for c in 0..<Int(animation.pointee.mNumChannels) {
                    guard let channel = animation.pointee.mChannels?[c], let node = nodeNamed[Self.string(channel.pointee.mNodeName)] else { continue }
                    moved[node] = true
                }
            }
            for i in scene.nodes.indices { if let p = scene.nodes[i].parent, moved[p] { moved[i] = true } }

            var joints = scene.nodes.map { ModelScene.Skeleton.Joint(name: $0.name, parent: $0.parent, rest: $0.transform) }
            var changed = false
            for i in scene.nodes.indices {
                guard let meshIndex = scene.nodes[i].mesh, joints.count <= 65535, i <= 65535 else { continue }
                let sources = partSources[meshIndex] ?? []
                var skinned = false
                for p in scene.meshes[meshIndex].parts.indices {
                    let count = scene.meshes[meshIndex].parts[p].positions.count
                    guard sources.indices.contains(p), let mesh = source.mMeshes?[Int(sources[p])]?.pointee, mesh.mNumBones > 0, let bones = mesh.mBones,
                          joints.count + Int(mesh.mNumBones) <= 65535 else { continue }
                    // The four strongest pulls on each vertex.
                    var pulls = [[(joint: UInt16, weight: Float)]](repeating: [], count: count)
                    for b in 0..<Int(mesh.mNumBones) {
                        guard let bone = bones[b]?.pointee else { continue }
                        // A bone whose node is not there stands still where the file put it.
                        joints.append(ModelScene.Skeleton.Joint(name: Self.string(bone.mName), parent: nodeNamed[Self.string(bone.mName)], inverseBind: Self.matrix(bone.mOffsetMatrix)))
                        guard let weights = bone.mWeights else { continue }
                        for w in 0..<Int(bone.mNumWeights) {
                            let vertex = Int(weights[w].mVertexId), weight = weights[w].mWeight
                            if vertex < count, weight.isFinite, weight > 0 { pulls[vertex].append((UInt16(joints.count - 1), weight)) }
                        }
                    }
                    var skin = ModelScene.Skin(skeleton: 0)
                    skin.joints.reserveCapacity(count); skin.weights.reserveCapacity(count)
                    for var pull in pulls {
                        if pull.count > 4 { pull.sort { $0.weight > $1.weight }; pull.removeSubrange(4...) }
                        let sum = pull.reduce(0) { $0 + $1.weight }
                        // A vertex no bone holds stays with the mesh's own node.
                        guard sum > 0 else { skin.joints.append(SIMD4(UInt16(i), 0, 0, 0)); skin.weights.append(SIMD4(1, 0, 0, 0)); continue }
                        var j = SIMD4<UInt16>(0, 0, 0, 0), w = SIMD4<Float>(0, 0, 0, 0)
                        for (k, one) in pull.enumerated() { j[k] = one.joint; w[k] = one.weight / sum }
                        skin.joints.append(j); skin.weights.append(w)
                    }
                    scene.meshes[meshIndex].parts[p].skin = skin
                    skinned = true
                }
                // Other shapes are shown through a skin too (see `ModelScene.MeshPart.morphTargets`).
                if moved[i] || skinned || !scene.meshes[meshIndex].morphWeights.isEmpty {
                    // What has no bones of its own follows the node whole.
                    for p in scene.meshes[meshIndex].parts.indices where scene.meshes[meshIndex].parts[p].skin == nil {
                        let count = scene.meshes[meshIndex].parts[p].positions.count
                        scene.meshes[meshIndex].parts[p].skin = ModelScene.Skin(skeleton: 0, joints: [SIMD4<UInt16>](repeating: SIMD4(UInt16(i), 0, 0, 0), count: count),
                                                                                weights: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: count))
                    }
                    changed = true
                }
            }
            guard changed else { return }
            scene.skeletons = [ModelScene.Skeleton(joints: joints, node: nil)]
            for animation in animations.prefix(Self.maxClips) {
                if let clip = clip(animation.pointee, joints: joints) { scene.clips.append(clip) }
            }
        }

        /// The clip an animation is: its keys, sampled at a steady rate for every joint.
        private func clip(_ animation: aiAnimation, joints: [ModelScene.Skeleton.Joint]) -> ModelScene.AnimationClip? {
            let ticks = animation.mTicksPerSecond > 0 && animation.mTicksPerSecond.isFinite ? animation.mTicksPerSecond : 25
            var channels: [(joint: Int, channel: aiNodeAnim)] = []
            var first = Double.infinity, last = -Double.infinity
            for c in 0..<Int(animation.mNumChannels) {
                guard let channel = animation.mChannels?[c]?.pointee, let joint = nodeNamed[Self.string(channel.mNodeName)] else { continue }
                channels.append((joint, channel))
                for (count, time) in [(Int(channel.mNumPositionKeys), { (k: Int) in channel.mPositionKeys[k].mTime }),
                                      (Int(channel.mNumRotationKeys), { (k: Int) in channel.mRotationKeys[k].mTime }),
                                      (Int(channel.mNumScalingKeys), { (k: Int) in channel.mScalingKeys[k].mTime })] where count > 0 {
                    first = min(first, time(0)); last = max(last, time(count - 1))
                }
            }
            // Blend shapes over time: for each mesh of the scene, each shape's keys.
            var shapeKeys: [Int: [Int: [(time: Double, weight: Float)]]] = [:]
            for c in 0..<Int(animation.mNumMorphMeshChannels) {
                guard let channel = animation.mMorphMeshChannels?[c]?.pointee, let keys = channel.mKeys else { continue }
                // Named after the node, with the number of its geometry: "Head*0".
                var name = Self.string(channel.mName)
                if let star = name.lastIndex(of: "*") { name = String(name[..<star]) }
                guard let node = nodeNamed[name], let mesh = scene.nodes[node].mesh, !scene.meshes[mesh].morphWeights.isEmpty else { continue }
                let shapes = scene.meshes[mesh].morphWeights.count
                for k in 0..<Int(channel.mNumKeys) {
                    let key = keys[k]
                    guard key.mTime.isFinite, let which = key.mValues, let weights = key.mWeights else { continue }
                    first = min(first, key.mTime); last = max(last, key.mTime)
                    for v in 0..<Int(key.mNumValuesAndWeights) where Int(which[v]) < shapes && weights[v].isFinite {
                        shapeKeys[mesh, default: [:]][Int(which[v]), default: []].append((key.mTime, Float(weights[v])))
                    }
                }
            }
            guard !channels.isEmpty || !shapeKeys.isEmpty, first.isFinite, last.isFinite, last >= first else { return nil }
            let end = Float((last - first) / ticks)
            guard end.isFinite else { return nil }
            let count = joints.count
            // Clamp before converting: even a finite duration can exceed the integer range.
            let intervals = min(Float(Self.maxKeys - 1), (end * Self.samplesPerSecond).rounded(.up))
            var keys = max(2, Int(intervals) + 1)
            keys = max(2, min(keys, Self.maxClipValues / max(count, 1)))
            let times = (0..<keys).map { end * (Float($0) / Float(keys - 1)) }
            let rest = joints.map { ModelScene.Skeleton.decompose($0.rest) }

            var translations = [SIMD3<Float>](repeating: .zero, count: keys * count)
            var scales = translations
            var rotations = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: keys * count)
            for k in 0..<keys { for j in 0..<count { translations[k * count + j] = rest[j].translation; scales[k * count + j] = rest[j].scale; rotations[k * count + j] = rest[j].rotation } }

            /// The two keys around a time and how far between them it is.
            func around(_ tick: Double, _ count: Int, _ time: (Int) -> Double) -> (Int, Int, Float) {
                if count == 1 || tick <= time(0) { return (0, 0, 0) }
                if tick >= time(count - 1) { return (count - 1, count - 1, 0) }
                var low = 0, high = count - 1
                while high - low > 1 { let mid = (low + high) / 2; if time(mid) <= tick { low = mid } else { high = mid } }
                let span = time(high) - time(low)
                return (low, high, span > 0 ? Float((tick - time(low)) / span) : 0)
            }
            for (joint, channel) in channels {
                for k in 0..<keys {
                    let tick = first + Double(times[k]) * ticks
                    if channel.mNumPositionKeys > 0, let list = channel.mPositionKeys {
                        let (a, b, t) = around(tick, Int(channel.mNumPositionKeys)) { list[$0].mTime }
                        let v = simd_mix(SIMD3(list[a].mValue.x, list[a].mValue.y, list[a].mValue.z), SIMD3(list[b].mValue.x, list[b].mValue.y, list[b].mValue.z), SIMD3(repeating: t))
                        if v.x.isFinite, v.y.isFinite, v.z.isFinite { translations[k * count + joint] = v }
                    }
                    if channel.mNumScalingKeys > 0, let list = channel.mScalingKeys {
                        let (a, b, t) = around(tick, Int(channel.mNumScalingKeys)) { list[$0].mTime }
                        let v = simd_mix(SIMD3(list[a].mValue.x, list[a].mValue.y, list[a].mValue.z), SIMD3(list[b].mValue.x, list[b].mValue.y, list[b].mValue.z), SIMD3(repeating: t))
                        if v.x.isFinite, v.y.isFinite, v.z.isFinite { scales[k * count + joint] = v }
                    }
                    if channel.mNumRotationKeys > 0, let list = channel.mRotationKeys {
                        let (a, b, t) = around(tick, Int(channel.mNumRotationKeys)) { list[$0].mTime }
                        let qa = simd_quatf(ix: list[a].mValue.x, iy: list[a].mValue.y, iz: list[a].mValue.z, r: list[a].mValue.w)
                        let qb = simd_quatf(ix: list[b].mValue.x, iy: list[b].mValue.y, iz: list[b].mValue.z, r: list[b].mValue.w)
                        guard simd_length(qa.vector) > 1e-8, simd_length(qb.vector) > 1e-8 else { continue }
                        let q = a == b ? simd_normalize(qa) : simd_slerp(simd_normalize(qa), simd_normalize(qb), t)
                        if q.vector.x.isFinite, q.vector.w.isFinite { rotations[k * count + joint] = q }
                    }
                }
            }
            var clip = ModelScene.AnimationClip(name: Self.string(animation.mName), skeleton: 0, start: 0, end: end)
            clip.translations = .init(times: times, values: translations)
            clip.rotations = .init(times: times, values: rotations)
            clip.scales = .init(times: times, values: scales)
            for (mesh, byShape) in shapeKeys.sorted(by: { $0.key < $1.key }) {
                let shapes = scene.meshes[mesh].morphWeights.count
                var channel = ModelScene.MorphChannel(mesh: mesh, targetCount: shapes, times: times)
                channel.values = [Float](repeating: 0, count: keys * shapes)
                for (shape, unsorted) in byShape {
                    let list = unsorted.sorted { $0.time < $1.time }
                    for k in 0..<keys {
                        let (a, b, t) = around(first + Double(times[k]) * ticks, list.count) { list[$0].time }
                        channel.values[k * shapes + shape] = list[a].weight + (list[b].weight - list[a].weight) * t
                    }
                }
                clip.morphs.append(channel)
            }
            return clip
        }

        // MARK: Conversions

        static func string(_ s: aiString) -> String {
            let length = min(Int(s.length), 1023)
            return withUnsafeBytes(of: s.data) { String(decoding: $0.prefix(length), as: UTF8.self) }
        }

        /// Assimp stores matrices row by row.
        static func matrix(_ m: aiMatrix4x4) -> simd_float4x4 {
            simd_float4x4(columns: (SIMD4(m.a1, m.b1, m.c1, m.d1), SIMD4(m.a2, m.b2, m.c2, m.d2), SIMD4(m.a3, m.b3, m.c3, m.d3), SIMD4(m.a4, m.b4, m.c4, m.d4)))
        }
    }
}
