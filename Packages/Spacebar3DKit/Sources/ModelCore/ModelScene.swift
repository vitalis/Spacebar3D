import simd

/// A model as the renderer sees it, whatever file it came from. Importers produce it off
/// the main thread and do every coordinate and unit fix-up, so the renderer has one
/// convention: right-handed, Y up, metres or the file's own unit.
///
/// Only what the formats moved so far need is here; skins, animation clips, morph targets
/// and the VRM document are added with the formats that have them.
public struct ModelScene: Sendable {
    public var nodes: [Node] = []
    public var meshes: [Mesh] = []
    public var materials: [Material] = []
    public var textures: [TextureRef] = []
    public var skeletons: [Skeleton] = []
    /// Animations, in the order the viewer offers them.
    public var clips: [AnimationClip] = []
    /// Joints that trail and settle by themselves (hair, skirts), when the file has them.
    public var springs: SpringSystem?
    /// Faces and vertices as authored, for the statistics.
    public var topology = SourceTopology()
    public var diagnostics = Diagnostics()

    public init() {}

    public struct Node: Sendable {
        public var name: String
        /// Index into `nodes`, or nil for a root.
        public var parent: Int?
        /// Placement relative to the parent.
        public var transform: simd_float4x4
        /// Index into `meshes`.
        public var mesh: Int?

        public init(name: String = "", parent: Int? = nil, transform: simd_float4x4 = matrix_identity_float4x4, mesh: Int? = nil) {
            self.name = name; self.parent = parent; self.transform = transform; self.mesh = mesh
        }
    }

    public struct Mesh: Sendable {
        public var name: String
        public var parts: [MeshPart]
        /// How much of each morph target shows when nothing is animated; one for each of
        /// the targets its parts carry.
        public var morphWeights: [Float] = []

        public init(name: String = "", parts: [MeshPart] = []) { self.name = name; self.parts = parts }
    }

    public enum Primitive: Sendable { case triangles, points }

    /// One draw: vertex streams of equal length, indexed by `triangleIndices`.
    public struct MeshPart: Sendable {
        public var positions: [SIMD3<Float>] = []
        /// Empty when the file has none; the renderer then computes them.
        public var normals: [SIMD3<Float>] = []
        public var uv0: [SIMD2<Float>] = []
        /// One per vertex when the file has them (glTF `TANGENT`), else empty: xyz points
        /// along increasing U, and w is the handedness, so the bitangent is
        /// `cross(normal, xyz) * w`. A normal map baked against them is laid on by them.
        public var tangents: [SIMD4<Float>] = []
        public var colors: [SIMD4<Float>] = []
        /// Three per triangle. Empty for `.points`.
        public var triangleIndices: [UInt32] = []
        /// Corner count of each source polygon, in triangle order (a quad covers the next
        /// two triangles, a pentagon three). Nil when the source has only triangles.
        public var faceSizes: [UInt32]?
        /// Index into `ModelScene.materials`, or nil for the default material.
        public var material: Int?
        public var primitive: Primitive = .triangles
        /// The source stores the mesh face by face, each face with its own normal (STL), and
        /// the importer has merged the corners that share a position: `normals` is empty and
        /// every face is shaded flat, whatever the shading setting.
        public var faceted = false
        /// Set when a skeleton moves this part; one entry per vertex in its arrays.
        public var skin: Skin?
        /// Other shapes of the part (a smile, a blink), each as what it adds to every
        /// vertex. Shown only on a part that has a skin: a part with shapes and no
        /// skeleton of its own is bound whole to one joint by its importer.
        public var morphTargets: [MorphTarget] = []

        public init() {}
    }

    /// Metallic-roughness material, the one model every source is brought to.
    public struct Material: Sendable {
        public var name = ""
        public var baseColor = SIMD4<Float>(0.8, 0.8, 0.8, 1)
        /// Index into `ModelScene.textures`.
        public var baseColorTexture: Int?
        public var metallic: Float = 0
        public var roughness: Float = 0.5
        /// Index into `ModelScene.textures`: roughness in the green channel and metallic in
        /// the blue one (the glTF layout), each multiplied by the value above.
        public var metallicRoughnessTexture: Int?
        /// Indices into `ModelScene.textures`: the same two as separate grey images (USD).
        public var metallicTexture: Int?
        public var roughnessTexture: Int?
        /// Index into `ModelScene.textures`: a tangent-space normal map; see `normalYSign`.
        public var normalTexture: Int?
        /// Multiplies the tangent-space normal's X and Y before normalization.
        public var normalScale: Float = 1
        /// Which way green runs along the stored V when the renderer works the frame out from the
        /// texture coordinates: -1 (toward decreasing stored V, the image top, OpenGL green) for
        /// v-down data (glTF, and formats whose V was flipped on import); +1 for a v-up map.
        /// A glTF file's own tangents already say it and ignore this.
        public var normalYSign: Float = -1
        /// Light the surface gives off by itself (a screen, a lamp), linear red, green and
        /// blue with any strength already counted in; multiplied by the image when there is one.
        public var emissive = SIMD3<Float>(0, 0, 0)
        /// Index into `ModelScene.textures`.
        public var emissiveTexture: Int?
        /// Index into `ModelScene.textures`: in its red channel, how much of the light from
        /// all round reaches each place (none in a deep fold). The lamps' light is not
        /// affected. `occlusionStrength` says how much of it counts.
        public var occlusionTexture: Int?
        public var occlusionStrength: Float = 1
        public var doubleSided = false
        /// The file means the surface to be seen from its front only: its far side is not
        /// drawn. (Without this, and without `doubleSided`, the renderer leaves out far
        /// sides only where it can tell they are hidden.)
        public var oneSided = false
        /// How the material's images continue outside their edges and how they are enlarged.
        public var sampling = TextureSampling()
        /// Overrides for maps whose sampler differs from the base-color image.
        public var metallicRoughnessSampling: TextureSampling?
        public var normalSampling: TextureSampling?
        public var emissiveSampling: TextureSampling?
        public var occlusionSampling: TextureSampling?
        /// Set for a cartoon material (VRM's MToon): the surface has a lit colour and a shade
        /// colour with an edge between them, and may carry an outline.
        public var toon: Toon?
        /// Below one the surface is see-through; texture and vertex alpha then count too.
        public var opacity: Float = 1
        /// Blend texture and vertex alpha even when the material factor is one.
        public var alphaBlend = false
        /// Set when the colour image is laid over per-vertex colours and mixed with them by
        /// its own alpha (rgb = image * a + vertex colour * (1 - a)); the surface stays solid.
        public var imageOverVertexColour = false
        /// Set for a cut-out surface (leaves, hair): where the colour image's alpha
        /// times vertex alpha is below this, the surface is absent; elsewhere it is solid.
        /// Without an image its alpha is one. A threshold above one rejects the whole surface.
        public var alphaCutoff: Float?
        public var unlit = false
        /// False for sources with no physically based values (Phong, Lambert, none at
        /// all), so the view settings know they supply a stand-in.
        public var authoredPBR = false

        public init() {}
    }

    /// The cartoon shading of a material: where the light does not reach, the surface
    /// takes its shade colour; `shift` moves the edge between the two and `toony` narrows it.
    public struct Toon: Equatable, Sendable {
        /// As seen on screen (sRGB), like `baseColor`.
        public var shadeColor = SIMD3<Float>(1, 1, 1)
        /// Index into `ModelScene.textures`; multiplies the shade colour.
        public var shadeTexture: Int?
        public var shift: Float = 0
        public var toony: Float = 0.9
        /// The outline's width: metres, or a share of the view's height when `outlineOnScreen`.
        /// Zero for no outline.
        public var outlineWidth: Float = 0
        public var outlineOnScreen = false
        public var outlineColor = SIMD3<Float>(0, 0, 0)
        /// How much of the surface's own colour shows in the outline, 0...1.
        public var outlineLightingMix: Float = 1
        /// Index into `ModelScene.textures`; its green scales the outline's width over the surface.
        public var outlineWidthTexture: Int?
        /// Index into `ModelScene.textures`; its red, times `shiftTextureScale`, adds to `shift`.
        public var shiftTexture: Int?
        public var shiftTextureScale: Float = 1
        /// A picture of a lit ball, looked up by which way the surface faces the viewer and
        /// added to it (a painted highlight). Index into `ModelScene.textures`.
        public var matcapTexture: Int?
        /// Multiplies the matcap (linear).
        public var matcapColor = SIMD3<Float>(1, 1, 1)
        /// Light along the edges that face away from the viewer: its colour (as seen on
        /// screen), how sharply it stays at the edge, and how far it reaches in.
        public var rimColor = SIMD3<Float>(0, 0, 0)
        public var rimFresnelPower: Float = 5
        public var rimLift: Float = 0
        /// Index into `ModelScene.textures`; multiplies the matcap and the rim.
        public var rimTexture: Int?
        /// How much the scene's light dims or brightens the matcap and the rim, 0...1.
        public var rimLightingMix: Float = 1
        /// The images slide over the surface by this much of themselves a second, and turn
        /// about their middle by this many radians a second; the blue of the mask image
        /// (index into `ModelScene.textures`) says how much of that each place gets.
        public var uvScroll = SIMD2<Float>(0, 0)
        public var uvRotation: Float = 0
        public var uvMaskTexture: Int?

        public init() {}
    }

    /// What an image does outside its own edges.
    public enum TextureWrap: Hashable, Sendable { case `repeat`, clamp, mirror }

    public struct TextureSampling: Hashable, Sendable {
        public var wrapS = TextureWrap.repeat
        public var wrapT = TextureWrap.repeat
        /// Enlarged pixels stay square-edged (pixel art) instead of being blended.
        public var sharp = false

        public init(wrapS: TextureWrap = .repeat, wrapT: TextureWrap = .repeat, sharp: Bool = false) {
            self.wrapS = wrapS; self.wrapT = wrapT; self.sharp = sharp
        }
    }

    public enum TextureRef: Sendable {
        case embedded(bytes: [UInt8], mime: String)
        /// Already decoded: `width * height * 4` bytes, sRGB red, green, blue and alpha, top row first.
        /// Colour channels are straight (not multiplied by alpha); upload performs that conversion.
        case pixels(width: Int, height: Int, rgba: [UInt8])
        /// A file beside the model, by the name the model uses for it.
        case sidecar(name: String)
        /// Named by the model but not available; the viewer says so.
        case missing(name: String)
    }

    public struct Diagnostics: Sendable {
        /// Files the model refers to that could not be read.
        public var missingResources: [String] = []
        /// Features of the file that were not shown.
        public var skippedFeatures: [String] = []

        public init() {}
    }

    /// Smallest box around drawn vertices, with node placement applied; nil for an empty scene.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for (index, node) in nodes.enumerated() {
            guard let mesh = node.mesh, meshes.indices.contains(mesh) else { continue }
            let world = worldTransform(of: index)
            for part in meshes[mesh].parts {
                func include(_ p: SIMD3<Float>) {
                    let w = world * SIMD4(p, 1)
                    // A coordinate that is infinite or no number is no place to make room for.
                    guard w.x.isFinite, w.y.isFinite, w.z.isFinite else { return }
                    low = simd_min(low, SIMD3(w.x, w.y, w.z)); high = simd_max(high, SIMD3(w.x, w.y, w.z))
                }
                if part.primitive == .triangles {
                    for index in part.triangleIndices.prefix(part.triangleIndices.count / 3 * 3) where Int(index) < part.positions.count {
                        include(part.positions[Int(index)])
                    }
                } else {
                    for p in part.positions { include(p) }
                }
            }
        }
        return low.x.isFinite ? (low, high) : nil
    }

    /// The scene with its middle at the origin when it lies far off (see `Whereabouts`);
    /// otherwise the scene as it is.
    ///
    /// The root nodes move by the middle, in Double. A mesh whose own corners lie far out
    /// is brought to its own middle too, and its node takes the middle's place (a node's
    /// Float turn applied to corners millions out would lose them); a skinned part is
    /// rebased the same way through its skeleton (see `rebaseSkeletons`).
    public func movedNearTheOrigin() -> ModelScene {
        var whereabouts = Whereabouts()
        let worlds = nodes.indices.map { Self.double(worldTransform(of: $0)) }
        var restPlacements: [Int: [simd_double4x4]] = [:]
        for (index, node) in nodes.enumerated() {
            guard let mesh = node.mesh, meshes.indices.contains(mesh) else { continue }
            for part in meshes[mesh].parts {
                // A skinned part is placed by its skeleton's node, not by its own.
                var placement = worlds[index], bind = matrix_identity_double4x4
                if let s = skeletonOf(part) {
                    placement = skeletons[s].node.flatMap { nodes.indices.contains($0) ? worlds[$0] : nil } ?? matrix_identity_double4x4
                    bind = Self.double(part.skin?.geometryBind ?? matrix_identity_float4x4)
                }
                let m = placement * bind
                guard let s = skeletonOf(part), let skin = part.skin else {
                    Self.forEachDrawn(part) { p in
                        let w = m * SIMD4<Double>(Double(p.x), Double(p.y), Double(p.z), 1)
                        whereabouts.include(SIMD3(w.x, w.y, w.z))
                    }
                    continue
                }
                // Where its joints put a vertex in the rest pose: its skeleton node (or identity)
                // times each joint's world times inverse bind, weighted.
                if restPlacements[s] == nil {
                    var jointWorlds: [simd_double4x4] = []
                    for joint in skeletons[s].joints {
                        let local = Self.double(joint.rest)
                        if let p = joint.parent, p >= 0, p < jointWorlds.count { jointWorlds.append(jointWorlds[p] * local) } else { jointWorlds.append(local) }
                    }
                    restPlacements[s] = zip(jointWorlds, skeletons[s].joints).map { placement * $0 * Self.double($1.inverseBind) }
                }
                let ks = restPlacements[s]!
                let g = Self.double(skin.geometryBind)
                Self.forEachDrawn(part, indexed: true) { i, p in
                    let v = g * SIMD4<Double>(Double(p.x), Double(p.y), Double(p.z), 1)
                    var sum = SIMD4<Double>(repeating: 0), total = 0.0, usable = true
                    let js = skin.joints[i], ws = skin.weights[i]
                    for k in 0..<4 where ws[k] != 0 {
                        guard Int(js[k]) < ks.count, ws[k].isFinite, ws[k] > 0 else { usable = false; break }
                        sum += Double(ws[k]) * (ks[Int(js[k])] * v); total += Double(ws[k])
                    }
                    if usable, total > 0, sum.x.isFinite, sum.y.isFinite, sum.z.isFinite {
                        whereabouts.include(SIMD3(sum.x, sum.y, sum.z))
                    } else {
                        let w = m * SIMD4<Double>(Double(p.x), Double(p.y), Double(p.z), 1)
                        whereabouts.include(SIMD3(w.x, w.y, w.z))
                    }
                }
            }
        }
        guard let middle = whereabouts.farMiddle else { return self }
        var moved = self
        let offsets = moved.rebaseSkeletons(middle: middle)
        for i in moved.nodes.indices where moved.nodes[i].parent.map({ !moved.nodes.indices.contains($0) }) ?? true {
            let at = moved.nodes[i].transform.columns.3
            let here = offsets[i].map { Self.apply(moved.nodes[i].transform, to: $0) } ?? SIMD3<Double>(SIMD3(at.x, at.y, at.z))
            moved.nodes[i].transform = Self.shifted(moved.nodes[i].transform, by: here - middle)
        }
        for (i, c) in offsets where moved.nodes[i].parent.map({ moved.nodes.indices.contains($0) }) ?? false {
            moved.nodes[i].transform = Self.shifted(moved.nodes[i].transform, by: Self.apply(moved.nodes[i].transform, to: c))
        }
        moved.foldMeshMiddlesIntoNodes()
        return moved
    }

    /// The skeleton a part is skinned to, when the part really is: the renderer treats a
    /// skin whose arrays do not fit the vertices as no skin.
    private func skeletonOf(_ part: MeshPart) -> Int? {
        guard let s = part.skin, skeletons.indices.contains(s.skeleton),
              s.joints.count == part.positions.count, s.weights.count == part.positions.count else { return nil }
        return s.skeleton
    }

    /// Calls `body` for each position that is drawn.
    private static func forEachDrawn(_ part: MeshPart, indexed: Bool, _ body: (Int, SIMD3<Float>) -> Void) {
        if part.primitive == .triangles {
            for index in part.triangleIndices.prefix(part.triangleIndices.count / 3 * 3) where Int(index) < part.positions.count { body(Int(index), part.positions[Int(index)]) }
        } else {
            for (i, p) in part.positions.enumerated() { body(i, p) }
        }
    }

    private static func forEachDrawn(_ part: MeshPart, _ body: (SIMD3<Float>) -> Void) {
        if part.primitive == .triangles {
            for index in part.triangleIndices.prefix(part.triangleIndices.count / 3 * 3) where Int(index) < part.positions.count { body(part.positions[Int(index)]) }
        } else {
            for p in part.positions { body(p) }
        }
    }

    private static func double(_ m: simd_float4x4) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1), SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3)))
    }

    private static func float(_ m: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }

    /// `matrix` taken at `point` through its linear part, in Double.
    private static func apply(_ matrix: simd_float4x4, to point: SIMD3<Double>) -> SIMD3<Double> {
        let m = Self.double(matrix)
        let v = m * SIMD4(point, 0)
        return SIMD3(v.x + Double(matrix.columns.3.x), v.y + Double(matrix.columns.3.y), v.z + Double(matrix.columns.3.z))
    }

    /// The matrix with `translation` in its last column, worked out in Double.
    private static func shifted(_ matrix: simd_float4x4, by translation: SIMD3<Double>) -> simd_float4x4 {
        var result = matrix
        result.columns.3 = SIMD4(SIMD3<Float>(translation), matrix.columns.3.w)
        return result
    }

    /// Skinned parts far from their skeleton's origin are posed by joint matrices whose
    /// far translations cancel badly in Float. For each such skeleton, its bind space is
    /// moved to the skinned vertices' middle `c` in Double: the vertices lose `c`, each
    /// inverse bind takes it back (`IB * T(c)`), the root joints lose it (`T(-c) * rest`),
    /// and the skeleton's node gains it, so what is drawn does not change. Returns, by node,
    /// the `c` its transform must take in (as `transform * T(c)`).
    ///
    /// A skeleton with no node (glTF's and Assimp's own, whose skinned parts are drawn at
    /// identity) has nowhere to put `c` back, and no root node of the scene moves it by the
    /// scene's `middle` either. Its root joints (rest and `animationPrefix`) lose the scene's
    /// `middle` instead of `c`, so it moves with everything else; the vertex and inverse-bind
    /// rebase is the same, and is skipped, leaving only that move, when its vertices are
    /// already near their own bind origin (a far rig whose parts are near).
    private mutating func rebaseSkeletons(middle: SIMD3<Double>) -> [Int: SIMD3<Double>] {
        var placed: [Int: SIMD3<Double>] = [:]
        let used = Set(nodes.compactMap(\.mesh))
        var sharing: [Int: Int] = [:]
        for s in skeletons { if let n = s.node { sharing[n, default: 0] += 1 } }
        for s in skeletons.indices {
            guard !skeletons[s].joints.isEmpty else { continue }
            let node: Int? = skeletons[s].node
            if let node { guard nodes.indices.contains(node), sharing[node] == 1 else { continue } }
            /// What the root joints lose: `c` when the node gains it back, else the scene's middle.
            var lost: SIMD3<Double>? = node == nil ? middle : nil
            var whereabouts = Whereabouts(), usable = true
            for m in meshes.indices where used.contains(m) {
                for part in meshes[m].parts where skeletonOf(part) == s {
                    let g = Self.double(part.skin!.geometryBind)
                    if abs(simd_determinant(simd_double3x3(SIMD3(g.columns.0.x, g.columns.0.y, g.columns.0.z), SIMD3(g.columns.1.x, g.columns.1.y, g.columns.1.z), SIMD3(g.columns.2.x, g.columns.2.y, g.columns.2.z)))) < 1e-12 { usable = false }
                    for p in part.positions { let w = g * SIMD4(Double(p.x), Double(p.y), Double(p.z), 1); whereabouts.include(SIMD3(w.x, w.y, w.z)) }
                }
            }
            guard usable, let c = whereabouts.farMiddle else {
                if let lost { Self.moveRoots(of: &skeletons[s], by: lost) }
                continue
            }
            if node != nil { lost = c }
            for m in meshes.indices {
                for k in meshes[m].parts.indices where skeletonOf(meshes[m].parts[k]) == s {
                    let g = Self.double(meshes[m].parts[k].skin!.geometryBind)
                    let linear = simd_double3x3(SIMD3(g.columns.0.x, g.columns.0.y, g.columns.0.z), SIMD3(g.columns.1.x, g.columns.1.y, g.columns.1.z), SIMD3(g.columns.2.x, g.columns.2.y, g.columns.2.z))
                    // Its own frame's share of `c`, so that `geometryBind * p'` is `geometryBind * p - c`.
                    let share = linear.inverse * c
                    meshes[m].parts[k].positions = meshes[m].parts[k].positions.map { SIMD3<Float>(SIMD3<Double>($0) - share) }
                }
            }
            var toBind = matrix_identity_double4x4
            toBind.columns.3 = SIMD4(c, 1)
            for j in skeletons[s].joints.indices {
                skeletons[s].joints[j].inverseBind = Self.float(Self.double(skeletons[s].joints[j].inverseBind) * toBind)
            }
            Self.moveRoots(of: &skeletons[s], by: lost ?? c)
            if let node { placed[node] = c }
        }
        return placed
    }

    /// The skeleton's root joints taken by `-amount`, in Double (`T(-amount) * rest`).
    private static func moveRoots(of skeleton: inout Skeleton, by amount: SIMD3<Double>) {
        var fromBind = matrix_identity_double4x4
        fromBind.columns.3 = SIMD4(-amount, 1)
        for j in skeleton.joints.indices {
            let isRoot = skeleton.joints[j].parent.map { $0 < 0 || $0 >= j } ?? true
            guard isRoot else { continue }
            let rest = skeleton.joints[j].rest
            // A joint without authored components is animated from its rest pose's own;
            // keep those as they were, and let the prefix carry the move.
            if skeleton.joints[j].restComponents == nil { skeleton.joints[j].restComponents = Skeleton.decompose(rest) }
            skeleton.joints[j].rest = Self.float(fromBind * Self.double(rest))
            skeleton.joints[j].animationPrefix = Self.float(fromBind * Self.double(skeleton.joints[j].animationPrefix))
        }
    }

    /// A mesh whose own corners lie far from its own origin is brought to its own middle `m`
    /// (exact: nearby Floats), and each node using it takes `m` into its translation, worked
    /// out in Double. A mesh is left as it is when a node using it has children (they would
    /// move) or places a skeleton.
    private mutating func foldMeshMiddlesIntoNodes() {
        let hasChildren = Set(nodes.compactMap(\.parent))
        let placesSkeleton = Set(skeletons.compactMap(\.node))
        for m in meshes.indices {
            var whereabouts = Whereabouts()
            for part in meshes[m].parts where skeletonOf(part) == nil { Self.forEachDrawn(part) { whereabouts.include(SIMD3<Double>($0)) } }
            guard let far = whereabouts.farMiddle else { continue }
            let users = nodes.indices.filter { nodes[$0].mesh == m }
            guard !users.isEmpty, users.allSatisfy({ !hasChildren.contains($0) && !placesSkeleton.contains($0) }) else { continue }
            let middle = SIMD3<Float>(far)
            var locals: [Int: simd_float4x4] = [:]
            for n in users {
                let world = Self.double(worldTransform(of: n))
                var target = world
                target.columns.3 = world * SIMD4(SIMD3<Double>(middle), 1)
                var parent = matrix_identity_double4x4
                if let p = nodes[n].parent, nodes.indices.contains(p) { parent = Self.double(worldTransform(of: p)) }
                guard abs(simd_determinant(parent)) > 1e-12 else { locals = [:]; break }
                let local = Self.float(parent.inverse * target)
                guard local.columns.3.x.isFinite, local.columns.3.y.isFinite, local.columns.3.z.isFinite else { locals = [:]; break }
                locals[n] = local
            }
            guard locals.count == users.count else { continue }
            for (n, local) in locals { nodes[n].transform.columns.3 = local.columns.3 }
            for k in meshes[m].parts.indices where skeletonOf(meshes[m].parts[k]) == nil {
                meshes[m].parts[k].positions = meshes[m].parts[k].positions.map { $0 - middle }
            }
        }
    }

    /// A node's placement in the scene, through its parents.
    public func worldTransform(of index: Int) -> simd_float4x4 {
        var result = nodes[index].transform, parent = nodes[index].parent, steps = 0
        while let p = parent, nodes.indices.contains(p), steps < nodes.count {
            result = nodes[p].transform * result; parent = nodes[p].parent; steps += 1
        }
        return result
    }
}
