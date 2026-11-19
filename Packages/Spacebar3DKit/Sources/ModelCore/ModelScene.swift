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
        /// +1 for a map authored in the stored UV basis (glTF); -1 after flipping source V.
        public var normalYSign: Float = -1
        /// Light the surface gives off by itself (a screen, a lamp), linear red, green and
        /// blue with any strength already counted in; multiplied by the image when there is one.
        public var emissive = SIMD3<Float>(0, 0, 0)
        /// Index into `ModelScene.textures`.
        public var emissiveTexture: Int?
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
        /// Set for a cartoon material (VRM's MToon): the surface has a lit colour and a shade
        /// colour with an edge between them, and may carry an outline.
        public var toon: Toon?
        /// Below one the surface is see-through; texture and vertex alpha then count too.
        public var opacity: Float = 1
        /// Blend texture and vertex alpha even when the material factor is one.
        public var alphaBlend = false
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

    /// A node's placement in the scene, through its parents.
    public func worldTransform(of index: Int) -> simd_float4x4 {
        var result = nodes[index].transform, parent = nodes[index].parent, steps = 0
        while let p = parent, nodes.indices.contains(p), steps < nodes.count {
            result = nodes[p].transform * result; parent = nodes[p].parent; steps += 1
        }
        return result
    }
}
