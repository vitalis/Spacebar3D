import Foundation
import ModelCore
import ModelIO
import simd

/// A USD file (`.usd`, `.usda`, `.usdc`, `.usdz`) as Model I/O reads it, turned into a
/// `ModelScene`: the object tree with its placements, meshes with their polygons, normals,
/// texture coordinates and colours, and each material's colour, image, metallic and
/// roughness, skeletons with the parts bound to them, and each skeleton's joint animation.
enum USDScene {
    static func load(_ url: URL) throws -> ModelScene {
        var error: NSError?
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: true, error: &error)
        if let error { throw ImportError.unsupported(error.localizedDescription) }
        // The images are not loaded through Model I/O: it would decode every one at full
        // size and keep them all while the scene is built. They are taken as the bytes
        // the file holds and decoded one at a time when they go to the GPU.
        var builder = Builder()
        builder.package = ZipStore(url: url)
        builder.namedColours = USDColorPrimvars(url: url)
        // USD says which way is up; the renderer's convention is Y up.
        var root: Int?
        if asset.upAxis.z > 0.5 {
            builder.scene.nodes.append(ModelScene.Node(name: "up", transform: simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))))
            root = 0
        }
        for i in 0..<asset.count { builder.visit(asset.object(at: i), parent: root, depth: 0) }
        builder.bindSkins()
        guard builder.scene.topology.faces > 0 else { throw ImportError.empty }
        return builder.scene
    }

    struct Builder {
        var scene = ModelScene()
        /// Shared by all the polygons of one file: see `PolygonTriangulation.Budget`.
        let polygonBudget = PolygonTriangulation.Budget()
        var materialIndex: [ObjectIdentifier: Int] = [:]
        var textureIndex: [ObjectIdentifier: Int] = [:]
        var imageIndex: [String: Int] = [:]
        /// The file itself when it is a `.usdz` package.
        var package: ZipStore?
        /// Colour attributes under their own names (Blender's), read from the file itself.
        var namedColours: USDColorPrimvars?
        var skeletonIndex: [ObjectIdentifier: Int] = [:]
        /// Parts waiting for their skeleton, which may come later in the file than the mesh.
        var pendingSkins: [(mesh: Int, source: MDLMesh, used: [[Int]?])] = []

        mutating func visit(_ object: MDLObject, parent: Int?, depth: Int) {
            // A file cannot nest deeper than this in any sane scene; a cycle would.
            guard depth < 512 else { return }
            var node = ModelScene.Node(name: object.name, parent: parent, transform: object.transform?.matrix ?? matrix_identity_float4x4)
            if let mesh = object as? MDLMesh, let (converted, used) = convert(mesh) {
                scene.meshes.append(converted)
                node.mesh = scene.meshes.count - 1
                if mesh.components.contains(where: { $0 is MDLAnimationBindComponent }) {
                    pendingSkins.append((scene.meshes.count - 1, mesh, used))
                }
            }
            scene.nodes.append(node)
            let index = scene.nodes.count - 1
            if let skeleton = object as? MDLSkeleton { add(skeleton, node: index) }
            for child in object.children.objects { visit(child, parent: index, depth: depth + 1) }
        }

        // MARK: Meshes

        // MARK: Skeletons and animation

        private mutating func add(_ source: MDLSkeleton, node: Int) {
            let paths = source.jointPaths
            let rest = source.jointRestTransforms.float4x4Array, bind = source.jointBindTransforms.float4x4Array
            guard !paths.isEmpty, paths.count <= 4096 else { return }
            var joints: [ModelScene.Skeleton.Joint] = []
            for (i, path) in paths.enumerated() {
                // "hips/spine/chest": the parent is the path without its last part.
                let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                let parent = parentPath.isEmpty ? nil : paths.firstIndex(of: parentPath).flatMap { $0 < i ? $0 : nil }
                let bindMatrix = i < bind.count ? bind[i] : matrix_identity_float4x4
                let inverse = simd_determinant(bindMatrix) != 0 ? simd_inverse(bindMatrix) : matrix_identity_float4x4
                joints.append(.init(name: path.split(separator: "/").last.map(String.init) ?? path, parent: parent,
                                    rest: i < rest.count ? rest[i] : matrix_identity_float4x4, inverseBind: inverse))
            }
            scene.skeletons.append(ModelScene.Skeleton(joints: joints, node: node))
            let index = scene.skeletons.count - 1
            skeletonIndex[ObjectIdentifier(source)] = index
            for component in source.components {
                guard let binding = component as? MDLAnimationBindComponent, let animation = binding.jointAnimation as? MDLPackedJointAnimation else { continue }
                if let clip = clip(from: animation, skeleton: index, paths: paths) { scene.clips.append(clip) }
            }
        }

        /// The animation's values, in the skeleton's joint order. A joint the animation does
        /// not name keeps its rest placement.
        private func clip(from animation: MDLPackedJointAnimation, skeleton: Int, paths: [String]) -> ModelScene.AnimationClip? {
            let joints = scene.skeletons[skeleton].joints
            let animated = animation.jointPaths
            // For each skeleton joint, its place in the animation's arrays.
            let source = paths.map { animated.firstIndex(of: $0) }
            let rest = joints.map { ModelScene.Skeleton.decompose($0.rest) }
            let limit = 100_000
            func channel<Value>(_ times: [TimeInterval], _ sample: (TimeInterval) -> [Value], _ fallback: (Int) -> Value) -> ModelScene.Channel<Value> {
                guard !times.isEmpty, times.count <= limit else { return .init() }
                var values: [Value] = []
                values.reserveCapacity(times.count * joints.count)
                for time in times {
                    let frame = sample(time)
                    for j in 0..<joints.count {
                        if let i = source[j], i < frame.count { values.append(frame[i]) } else { values.append(fallback(j)) }
                    }
                }
                return .init(times: times.map(Float.init), values: values)
            }
            let translations = channel(animation.translations.times, { animation.translations.float3Array(atTime: $0) }, { rest[$0].translation })
            var rotations = channel(animation.rotations.times, { animation.rotations.floatQuaternionArray(atTime: $0) }, { rest[$0].rotation })
            // A turn is used at unit length. One that is all zeros or no number is no turn:
            // the joint's own at rest stands in for it.
            for i in rotations.values.indices {
                let length = simd_length(rotations.values[i].vector)
                rotations.values[i] = length > 1e-6 && length.isFinite ? simd_quatf(vector: rotations.values[i].vector / length) : rest[i % joints.count].rotation
            }
            let scales = channel(animation.scales.times, { animation.scales.float3Array(atTime: $0) }, { rest[$0].scale })
            let times = translations.times + rotations.times + scales.times
            guard let start = times.min(), let end = times.max() else { return nil }
            let name = animation.name.split(separator: "/").last.map(String.init) ?? animation.name
            return ModelScene.AnimationClip(name: name, skeleton: skeleton, start: start, end: end, translations: translations, rotations: rotations, scales: scales)
        }

        /// Attaches joints and weights to the parts of every mesh bound to a skeleton.
        mutating func bindSkins() {
            for pending in pendingSkins {
                let mesh = pending.source
                guard let binding = mesh.components.compactMap({ $0 as? MDLAnimationBindComponent }).first,
                      let skeletonObject = binding.skeleton, let skeleton = skeletonIndex[ObjectIdentifier(skeletonObject)] else { continue }
                let count = mesh.vertexCount
                guard let indexData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeJointIndices),
                      let weightData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeJointWeights) else { continue }
                // Up to four joints per vertex are read; Model I/O's formats go no further.
                let perVertex = min(Int(indexData.format.rawValue & 0xff), Int(weightData.format.rawValue & 0xff))
                guard (1...4).contains(perVertex),
                      let indexFormat = MDLVertexFormat(rawValue: 0x50000 | UInt(perVertex)), let weightFormat = MDLVertexFormat(rawValue: 0xC0000 | UInt(perVertex)),
                      let indices = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeJointIndices, as: indexFormat),
                      let weights = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeJointWeights, as: weightFormat) else {
                    scene.diagnostics.skippedFeatures.append("skinning of \(mesh.name)")
                    continue
                }
                // The mesh may bind to some of the skeleton's joints only, by its own list.
                let jointCount = scene.skeletons[skeleton].joints.count
                let skeletonPaths = skeletonObject.jointPaths
                let remap: [Int]? = (binding.jointPaths?.isEmpty ?? true) ? nil : binding.jointPaths!.map { skeletonPaths.firstIndex(of: $0) ?? 0 }
                var joints = [SIMD4<UInt16>](repeating: .zero, count: count), influence = [SIMD4<Float>](repeating: .zero, count: count)
                for v in 0..<count {
                    var total: Float = 0
                    for k in 0..<perVertex {
                        var joint = Int(indices.dataStart.advanced(by: v * indices.stride + k * 2).loadUnaligned(as: UInt16.self))
                        var weight = weights.dataStart.advanced(by: v * weights.stride + k * 4).loadUnaligned(as: Float.self)
                        if let remap { joint = joint < remap.count ? remap[joint] : 0 }
                        if joint >= jointCount || !weight.isFinite || weight < 0 { joint = 0; weight = 0 }
                        joints[v][k] = UInt16(joint); influence[v][k] = weight; total += weight
                    }
                    // A vertex bound to nothing follows the first joint, so it is not left behind.
                    if total > 0 { influence[v] /= total } else { influence[v] = SIMD4(1, 0, 0, 0) }
                }
                let g = binding.geometryBindTransform
                let geometryBind = simd_float4x4(SIMD4<Float>(g.columns.0), SIMD4<Float>(g.columns.1), SIMD4<Float>(g.columns.2), SIMD4<Float>(g.columns.3))
                for p in scene.meshes[pending.mesh].parts.indices {
                    var skin = ModelScene.Skin(skeleton: skeleton, geometryBind: geometryBind)
                    if let used = pending.used[p] {
                        skin.joints = used.map { joints[$0] }; skin.weights = used.map { influence[$0] }
                    } else {
                        skin.joints = joints; skin.weights = influence
                    }
                    scene.meshes[pending.mesh].parts[p].skin = skin
                }
            }
            pendingSkins = []
        }

        /// The mesh and, for each of its parts, which of the mesh's vertices it took (nil
        /// when it took them all in order).
        private mutating func convert(_ mesh: MDLMesh) -> (ModelScene.Mesh, [[Int]?])? {
            let count = mesh.vertexCount
            guard count > 0, let positions: [SIMD3<Float>] = Self.attribute(mesh, MDLVertexAttributePosition, as: .float3, count: count, { SIMD3($0[0], $0[1], $0[2]) }) else { return nil }
            let normals: [SIMD3<Float>]? = Self.attribute(mesh, MDLVertexAttributeNormal, as: .float3, count: count) { SIMD3($0[0], $0[1], $0[2]) }
            // USD puts the origin of an image at its bottom left; ours is the top left.
            let uvs: [SIMD2<Float>]? = Self.attribute(mesh, MDLVertexAttributeTextureCoordinate, as: .float2, count: count) { SIMD2($0[0], 1 - $0[1]) }
            // USD keeps a colour as an amount of light; the scene keeps what is seen on screen.
            var colors: [SIMD4<Float>]? = Self.attribute(mesh, MDLVertexAttributeColor, as: .float4, count: count) { SIMD4(Self.toSRGB(SIMD3($0[0], $0[1], $0[2])), $0[3]) }
            // `displayColor` wins; without it, the colour attributes Blender writes under their own names.
            if colors == nil, let named = namedColours {
                colors = named.colours(forPath: mesh.path, positions: positions)
            }

            var parts: [ModelScene.MeshPart] = []
            var usedByPart: [[Int]?] = []
            let submeshes = (mesh.submeshes as? [MDLSubmesh]) ?? []
            for submesh in submeshes {
                guard let (indices, sizes) = Self.triangles(of: submesh, positions: positions, budget: polygonBudget, topology: &scene.topology) else { continue }
                var part = ModelScene.MeshPart()
                part.faceSizes = sizes
                part.material = submesh.material.map { material(for: $0) }
                if submeshes.count == 1 {
                    part.positions = positions
                    part.normals = normals ?? []
                    part.uv0 = uvs ?? []
                    part.colors = colors ?? []
                    part.triangleIndices = indices
                    usedByPart.append(nil)
                } else {
                    // Several parts share the mesh's vertices: each takes the ones it uses.
                    var remap = [UInt32](repeating: .max, count: count)
                    var used: [Int] = []
                    part.triangleIndices = indices.map { old in
                        if remap[Int(old)] == .max { remap[Int(old)] = UInt32(used.count); used.append(Int(old)) }
                        return remap[Int(old)]
                    }
                    part.positions = used.map { positions[$0] }
                    if let normals { part.normals = used.map { normals[$0] } }
                    if let uvs { part.uv0 = used.map { uvs[$0] } }
                    if let colors { part.colors = used.map { colors[$0] } }
                    usedByPart.append(used)
                }
                parts.append(part)
            }
            guard !parts.isEmpty else { return nil }
            scene.topology.vertices += count
            return (ModelScene.Mesh(name: mesh.name, parts: parts), usedByPart)
        }

        private static func attribute<T>(_ mesh: MDLMesh, _ name: String, as format: MDLVertexFormat, count: Int, _ make: (UnsafePointer<Float>) -> T) -> [T]? {
            guard let data = mesh.vertexAttributeData(forAttributeNamed: name, as: format), data.stride > 0 else { return nil }
            var out: [T] = []
            out.reserveCapacity(count)
            let components = format == .float2 ? 2 : format == .float3 ? 3 : 4
            withUnsafeTemporaryAllocation(of: Float.self, capacity: 4) { scratch in
                for i in 0..<count {
                    memcpy(scratch.baseAddress!, data.dataStart.advanced(by: i * data.stride), components * 4)
                    out.append(make(UnsafePointer(scratch.baseAddress!)))
                }
            }
            return out
        }

        /// The part's triangles (a polygon is split inside itself, wherever a corner is pushed
        /// in) and, when it has anything but triangles, the corner count of each polygon.
        /// Counts the polygons into `topology`.
        private static func triangles(of submesh: MDLSubmesh, positions: [SIMD3<Float>], budget: PolygonTriangulation.Budget, topology: inout SourceTopology) -> ([UInt32], [UInt32]?)? {
            let vertexCount = positions.count
            let total = submesh.indexCount
            guard total >= 3 else { return nil }
            let buffer = submesh.indexBuffer(asIndexType: .uint32)
            guard buffer.length >= total * 4 else { return nil }
            let map = buffer.map()
            let source = UnsafeRawBufferPointer(start: map.bytes, count: total * 4).bindMemory(to: UInt32.self)

            // Corner counts of the polygons, in order.
            var sizes: [Int]
            switch submesh.geometryType {
            case .triangles: sizes = []
            case .quads: sizes = [Int](repeating: 4, count: total / 4)
            case .variableTopology:
                guard let faces = submesh.topology, let counts = faces.faceTopology, counts.length >= faces.faceCount else { return nil }
                let bytes = UnsafeRawBufferPointer(start: counts.map().bytes, count: faces.faceCount).bindMemory(to: UInt8.self)
                sizes = bytes.map(Int.init)
            default: return nil
            }

            var indices: [UInt32] = []
            if submesh.geometryType == .triangles {
                let corners = total - total % 3
                indices.reserveCapacity(corners)
                var t = 0
                while t < corners {
                    let a = source[t], b = source[t + 1], c = source[t + 2]
                    t += 3
                    guard Int(a) < vertexCount, Int(b) < vertexCount, Int(c) < vertexCount else { continue }
                    indices.append(a); indices.append(b); indices.append(c)
                    topology.addFace(corners: 3)
                }
                return indices.isEmpty ? nil : (indices, nil)
            }
            var drawn: [UInt32] = []
            var at = 0
            var onlyTriangles = true
            for size in sizes {
                guard at + size <= total else { break }
                defer { at += size }
                guard size >= 3, (at..<(at + size)).allSatisfy({ Int(source[$0]) < vertexCount }) else { continue }
                if size == 3 {
                    indices.append(source[at]); indices.append(source[at + 1]); indices.append(source[at + 2])
                } else {
                    // As a fan from its first corner only where the split cannot be worked out.
                    let split = PolygonTriangulation.indices(count: size, budget: budget) { positions[Int(source[at + $0])] } ?? (1..<(size - 1)).flatMap { [0, $0, $0 + 1] }
                    for k in split { indices.append(source[at + k]) }
                }
                drawn.append(UInt32(size))
                if size != 3 { onlyTriangles = false }
                topology.addFace(corners: size)
            }
            return indices.isEmpty ? nil : (indices, onlyTriangles ? nil : drawn)
        }

        // MARK: Materials

        private mutating func material(for source: MDLMaterial) -> Int {
            if let known = materialIndex[ObjectIdentifier(source)] { return known }
            var material = ModelScene.Material()
            material.name = source.name
            // Model I/O lists its own default for every property next to the one the file
            // sets ("baseColor" 0.18 beside the file's "diffuseColor"): the file's comes last.
            func property(_ semantic: MDLMaterialSemantic) -> MDLMaterialProperty? {
                let all = (0..<source.count).compactMap { source[$0] }.filter { $0.semantic == semantic }
                return all.last { $0.type == .texture } ?? all.last
            }
            if let base = property(.baseColor) {
                switch base.type {
                case .float3: material.baseColor = SIMD4(Self.toSRGB(base.float3Value), 1)
                case .float4: material.baseColor = SIMD4(Self.toSRGB(SIMD3(base.float4Value.x, base.float4Value.y, base.float4Value.z)), 1)
                case .color:
                    if let c = base.color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, c.count >= 3 {
                        material.baseColor = SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), 1)
                    }
                case .texture:
                    // The image supplies the colour; the material's own stays white.
                    material.baseColor = SIMD4(1, 1, 1, 1)
                    if let texture = base.textureSamplerValue?.texture, let index = self.texture(for: texture) {
                        material.baseColorTexture = index
                    } else {
                        material.baseColor = SIMD4(0.8, 0.8, 0.8, 1)
                        scene.diagnostics.missingResources.append(base.stringValue ?? base.urlValue?.lastPathComponent ?? source.name)
                    }
                case .string, .URL:
                    // An image named by the file. It can be missing: beside the model, out of
                    // the sandbox's reach, or simply absent.
                    material.baseColor = SIMD4(1, 1, 1, 1)
                    if let index = image(named: base) {
                        material.baseColorTexture = index
                    } else {
                        material.baseColor = SIMD4(0.8, 0.8, 0.8, 1)
                    }
                default: break
                }
            }
            // Metallic and roughness: a number each, or an image each.
            if let metallic = property(.metallic) {
                if metallic.type == .float {
                    material.metallic = min(max(metallic.floatValue, 0), 1); material.authoredPBR = true
                } else if let index = image(of: metallic) {
                    material.metallicTexture = index; material.metallic = 1; material.authoredPBR = true
                }
            }
            if let roughness = property(.roughness) {
                if roughness.type == .float {
                    material.roughness = min(max(roughness.floatValue, 0), 1); material.authoredPBR = true
                } else if let index = image(of: roughness) {
                    material.roughnessTexture = index; material.roughness = 1; material.authoredPBR = true
                }
            }
            if let opacity = property(.opacity), opacity.type == .float, opacity.floatValue.isFinite {
                material.opacity = min(max(opacity.floatValue, 0), 1)
            }
            if let normal = property(.tangentSpaceNormal) { material.normalTexture = image(of: normal) }
            // Occlusion is the image's red channel, at full strength (Model I/O's own
            // `ambientOcclusionScale` is a default it lists, not something the file wrote).
            if let occlusion = property(.ambientOcclusion), let index = image(of: occlusion) {
                material.occlusionTexture = index; material.occlusionStrength = 1
            }
            scene.materials.append(material)
            materialIndex[ObjectIdentifier(source)] = scene.materials.count - 1
            return scene.materials.count - 1
        }

        /// The image a property stands for, whichever way Model I/O presents it.
        private mutating func image(of property: MDLMaterialProperty) -> Int? {
            switch property.type {
            case .texture: return property.textureSamplerValue?.texture.flatMap { texture(for: $0) }
            case .string, .URL: return image(named: property)
            default: return nil
            }
        }

        /// An image named as "package.usdz[path/inside.png]" or as a file path: its bytes,
        /// still compressed. Nil, and noted as missing, when it cannot be read.
        private mutating func image(named property: MDLMaterialProperty) -> Int? {
            guard let name = property.stringValue, !name.isEmpty else { return nil }
            if let known = imageIndex[name] { return known }
            var bytes: [UInt8]?
            var shortName = (name as NSString).lastPathComponent
            if name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
                let inner = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
                shortName = (inner as NSString).lastPathComponent
                bytes = package?.bytes(of: inner)
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: name), options: .mappedIfSafe), data.count <= 256 * 1024 * 1024 {
                bytes = [UInt8](data)
            }
            guard let bytes, !bytes.isEmpty else {
                scene.diagnostics.missingResources.append(shortName)
                return nil
            }
            scene.textures.append(.embedded(bytes: bytes, mime: ""))
            imageIndex[name] = scene.textures.count - 1
            return scene.textures.count - 1
        }

        private mutating func texture(for source: MDLTexture) -> Int? {
            if let known = textureIndex[ObjectIdentifier(source)] { return known }
            guard let image = Self.pixels(of: source) else { return nil }
            scene.textures.append(.pixels(width: image.width, height: image.height, rgba: image.rgba))
            textureIndex[ObjectIdentifier(source)] = scene.textures.count - 1
            return scene.textures.count - 1
        }

        struct Pixels { var width: Int; var height: Int; var rgba: [UInt8] }

        /// An image's pixels as red, green, blue, alpha bytes, top row first; nil for
        /// anything but 8-bit images of one to four channels.
        private static func pixels(of source: MDLTexture) -> Pixels? {
            let width = Int(source.dimensions.x), height = Int(source.dimensions.y), channels = source.channelCount
            guard width > 0, height > 0, width <= 16384, height <= 16384, source.channelEncoding == .uInt8, (1...4).contains(channels),
                  let data = source.texelDataWithTopLeftOrigin(atMipLevel: 0, create: true) else { return nil }
            let stride = source.rowStride
            guard stride >= width * channels, data.count >= stride * (height - 1) + width * channels else { return nil }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    var from = y * stride, to = y * width * 4
                    for _ in 0..<width {
                        switch channels {
                        case 1: rgba[to] = bytes[from]; rgba[to + 1] = bytes[from]; rgba[to + 2] = bytes[from]
                        case 2: rgba[to] = bytes[from]; rgba[to + 1] = bytes[from]; rgba[to + 2] = bytes[from]; rgba[to + 3] = bytes[from + 1]
                        case 3: rgba[to] = bytes[from]; rgba[to + 1] = bytes[from + 1]; rgba[to + 2] = bytes[from + 2]
                        default: rgba[to] = bytes[from]; rgba[to + 1] = bytes[from + 1]; rgba[to + 2] = bytes[from + 2]; rgba[to + 3] = bytes[from + 3]
                        }
                        from += channels; to += 4
                    }
                }
            }
            return Pixels(width: width, height: height, rgba: rgba)
        }

        /// USD colours are linear; `ModelScene` colours are sRGB.
        static func toSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
            func f(_ v: Float) -> Float { let x = min(max(v, 0), 1); return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
            return SIMD3(f(c.x), f(c.y), f(c.z))
        }
    }
}
