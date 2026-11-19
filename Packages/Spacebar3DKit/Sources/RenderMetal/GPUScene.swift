import Foundation
import Metal
import ModelCore
import simd

public enum RenderError: Error, LocalizedError {
    case noDevice
    case shaders(String)
    case tooLarge
    case badIndices

    public var errorDescription: String? {
        switch self {
        case .noDevice: return L10n.text("This Mac has no Metal graphics device.")
        case .shaders(let message): return L10n.format("The renderer's shaders did not compile: %@", message)
        case .tooLarge: return L10n.text("The model is too large to show.")
        case .badIndices: return L10n.text("The file refers to vertices that do not exist.")
        }
    }
}

/// What a surface is made of, as the shaders take it.
public struct RenderMaterial: Equatable, Sendable {
    /// Linear RGB.
    public var baseColor: SIMD3<Float>
    public var metallic: Float
    public var roughness: Float
    public var normalScale: Float = 1
    public var normalYSign: Float = -1
    /// Below one the surface is drawn see-through, after everything opaque.
    public var opacity: Float = 1
    /// Preserve BLEND when only texture or vertex alpha makes the surface see-through.
    public var alphaBlend = false
    public var isBlended: Bool { alphaCutoff == nil && (alphaBlend || opacity < 1) }
    /// Where texture alpha times vertex alpha is below this, nothing is drawn.
    public var alphaCutoff: Float?
    /// Linear; light the surface gives off by itself.
    public var emissive = SIMD3<Float>(0, 0, 0)
    public var doubleSided = false
    /// The far side is never drawn, whether or not the part is closed.
    public var oneSided = false
    /// Shown in its own colours, untouched by the lights.
    public var unlit = false
    /// Cartoon shading: the shade colour (linear), the edge's shift and narrowness, and the outline.
    public var toon: RenderToon?
    public var sampling = ModelScene.TextureSampling()
    public var metallicRoughnessSampling: ModelScene.TextureSampling?
    public var normalSampling: ModelScene.TextureSampling?
    public var emissiveSampling: ModelScene.TextureSampling?

    /// A neutral lit grey, for geometry that comes with no material: #b4b4b8, not metallic,
    /// roughness 0.65.
    public static let plain = RenderMaterial(baseColor: srgbToLinear(SIMD3(0xb4, 0xb4, 0xb8) / 255), metallic: 0, roughness: 0.65)
}

public func srgbToLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(c.x <= 0.04045 ? c.x / 12.92 : pow((c.x + 0.055) / 1.055, 2.4),
          c.y <= 0.04045 ? c.y / 12.92 : pow((c.y + 0.055) / 1.055, 2.4),
          c.z <= 0.04045 ? c.z / 12.92 : pow((c.z + 0.055) / 1.055, 2.4))
}

public struct RenderToon: Equatable, Sendable {
    public var shadeColor: SIMD3<Float>
    public var shift: Float
    public var toony: Float
    public var outlineWidth: Float
    public var outlineOnScreen: Bool
    public var outlineColor: SIMD3<Float>
    public var outlineLightingMix: Float
    public var shiftTextureScale: Float = 1
    /// Linear, like the colours beside them.
    public var matcapColor = SIMD3<Float>(1, 1, 1)
    public var rimColor = SIMD3<Float>(0, 0, 0)
    public var rimFresnelPower: Float = 5
    public var rimLift: Float = 0
    public var rimLightingMix: Float = 1
    public var uvScroll = SIMD2<Float>(0, 0)
    public var uvRotation: Float = 0
}

/// A `ModelScene` uploaded to the GPU: one vertex buffer per mesh part, one draw each.
/// Built off the main thread; drawn by `MetalRenderer`.
public final class GPUScene: @unchecked Sendable {
    /// Matches `V` in the shaders: position and normal, 12 bytes each.
    static let vertexStride = 24

    /// Visit the vertices used by a draw, including repeated triangle corners. Unused
    /// accessor elements must not influence framing or transparency metadata.
    static func forEachDrawnVertex(count: Int, indices: MTLBuffer?, indexCount: Int, _ body: (Int) -> Void) {
        if let indices {
            let values = indices.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<indexCount { body(Int(values[i])) }
        } else {
            for i in 0..<count { body(i) }
        }
    }

    /// What a part needs to follow its skeleton: the vertices as they were bound, and whose
    /// joints move each of them. The GPU moves the vertices, in a pass before the frame
    /// that draws them (see `encodePose`); the same is kept for the CPU, which does it
    /// once when the scene is made and whenever the GPU's pass is not to be had.
    final class SkinData {
        let skeleton: Int
        /// Position and normal per vertex (six floats, as in the vertex buffer), in the
        /// skeleton's space in the bind pose. With morph targets, the shape their current
        /// weights make.
        fileprivate(set) var rest: [Float]
        /// The part's other shapes, when it has any.
        var morph: MorphData?
        // Weighted homogeneous rest points, averaged per joint. Their transformed sum
        // is the exact posed vertex centroid, without CPU skinning every frame.
        var centerContributions: [(joint: Int, point: SIMD4<Float>)]?
        let drawIndices: MTLBuffer?
        let drawIndexCount: Int

        func refreshCenterContributions() {
            var sums: [Int: SIMD4<Float>] = [:]
            let count = rest.count / 6, drawn = drawIndices == nil ? rest.count / 6 : drawIndexCount
            guard drawn > 0 else { centerContributions = []; return }
            GPUScene.forEachDrawnVertex(count: count, indices: drawIndices, indexCount: drawIndexCount) { i in
                let p = SIMD4(rest[i * 6], rest[i * 6 + 1], rest[i * 6 + 2], 1) / Float(drawn)
                for k in 0..<4 where k == 0 || weights[i][k] > 0 {
                    sums[Int(joints[i][k]), default: .zero] += p * weights[i][k]
                }
            }
            centerContributions = sums.keys.sorted().map { ($0, sums[$0]!) }
        }
        let joints: [SIMD4<UInt16>]
        let weights: [SIMD4<Float>]
        /// The same three for the GPU.
        var restBuffer: MTLBuffer
        let jointsBuffer: MTLBuffer
        let weightsBuffer: MTLBuffer
        /// The outline's normals in the bind pose, once the outline has been built.
        var restOutline: [Float]?
        var restOutlineBuffer: MTLBuffer?

        init(skeleton: Int, rest: [Float], joints: [SIMD4<UInt16>], weights: [SIMD4<Float>], restBuffer: MTLBuffer, jointsBuffer: MTLBuffer, weightsBuffer: MTLBuffer, drawIndices: MTLBuffer?, drawIndexCount: Int) {
            self.drawIndices = drawIndices; self.drawIndexCount = drawIndexCount
            self.skeleton = skeleton; self.rest = rest; self.joints = joints; self.weights = weights
            self.restBuffer = restBuffer; self.jointsBuffer = jointsBuffer; self.weightsBuffer = weightsBuffer
        }
    }

    /// The other shapes of a skinned part and how much of each is showing. The shape they
    /// add up to is written over the skin's rest shape, on the CPU, whenever the weights
    /// change; the skinning then carries it like any other.
    final class MorphData {
        /// Index into the scene's meshes, by which a clip's morph channel finds the part.
        let mesh: Int
        /// The shape with no target showing, six floats a vertex.
        let base: [Float]
        /// What each target adds, six floats a vertex (position, normal).
        let targets: [[Float]]
        let defaults: [Float]
        var current: [Float]?

        init(mesh: Int, base: [Float], targets: [[Float]], defaults: [Float]) {
            self.mesh = mesh; self.base = base; self.targets = targets; self.defaults = defaults
        }
    }

    /// Owned by the draw thread. Each replacement keeps the preceding buffer immutable
    /// for command buffers that have already encoded it.
    struct PointOrder {
        let back: SIMD3<Float>
        let rest: MTLBuffer?
        let transforms: [simd_float4x4]?
        let buffer: MTLBuffer
    }

    final class Part {
        var pointOrder: PointOrder?
        var vertexBuffer: MTLBuffer
        var skin: SkinData?
        var windingJoint: Int?
        var posedMirrored: Bool?
        let vertexCount: Int
        /// Nil when the vertices are already in triangle order (3 per triangle).
        let indexBuffer: MTLBuffer?
        let indexCount: Int
        var drawnVertexCount: Int { indexBuffer == nil ? vertexCount : indexCount }
        func forEachDrawnVertex(_ body: (Int) -> Void) {
            GPUScene.forEachDrawnVertex(count: vertexCount, indices: indexBuffer, indexCount: indexCount, body)
        }
        let model: simd_float4x4
        let normalMatrix: simd_float4x4
        let material: RenderMaterial
        let faceSizes: [UInt32]?
        /// The source gave every face one normal and its corners were merged by position, so
        /// the part is always shaded flat, from the surface itself (see `upload`).
        var faceted = false
        /// A point cloud: `vertexCount` dots, no triangles.
        var isPoints = false
        /// One colour per vertex (4 bytes: sRGB red, green, blue, and alpha), when the file has them.
        var colorBuffer: MTLBuffer?
        /// One texture coordinate per vertex (two floats), and the image they point into,
        /// when the part's material has one.
        var uvBuffer: MTLBuffer?
        var texture: MTLTexture?
        /// Roughness (green) and metallic (blue), and the normal map, when the material has them.
        var mapsTexture: MTLTexture?
        var normalTexture: MTLTexture?
        /// What the surface gives off, as colours.
        var emissiveTexture: MTLTexture?
        /// A cartoon material's shade, as colours.
        var shadeTexture: MTLTexture?
        /// A cartoon material's painted highlight and what multiplies its rim, as colours;
        /// what moves its edge and scales its outline, as data.
        var matcapTexture: MTLTexture?
        var rimTexture: MTLTexture?
        var shiftTexture: MTLTexture?
        var outlineWidthTexture: MTLTexture?
        /// How much of the material's sliding and turning each place gets (blue), as data.
        var uvMaskTexture: MTLTexture?
        /// The part is a closed surface with its faces turned outward (`ClosedSurface`), so
        /// its back faces are left out whenever the camera cannot be inside it.
        var closed = false
        /// Box around the part in the scene, for that decision.
        var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (.zero, .zero)
        /// Middle of the part in the scene: see-through parts are drawn farthest first.
        var worldCenter = SIMD3<Float>.zero
        /// Pose orientation is separate from placement when vertices are already skinned.
        var mirrored: Bool { posedMirrored ?? Self.isMirrored(model) }
        static func isMirrored(_ model: simd_float4x4) -> Bool { simd_determinant(simd_float3x3(SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z), SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z), SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z))) < 0 }

        /// Fills `closed` and `worldBounds`. Only for parts whose vertices are merged by position.
        func checkClosed() {
            guard let indexBuffer else { return }
            let floats = UnsafePointer(vertexBuffer.contents().assumingMemoryBound(to: Float.self))
            let stride = GPUScene.vertexStride / 4
            guard ClosedSurface.isClosedAndOutward(indices: indexBuffer.contents().assumingMemoryBound(to: UInt32.self), indexCount: indexCount, floats: floats, stride: stride, vertexCount: vertexCount) else { return }
            var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
            forEachDrawnVertex { i in
                let p = SIMD3(floats[i * stride], floats[i * stride + 1], floats[i * stride + 2])
                low = simd_min(low, p); high = simd_max(high, p)
            }
            var worldLow = SIMD3<Float>(repeating: .infinity), worldHigh = SIMD3<Float>(repeating: -.infinity)
            for corner in 0..<8 {
                let p = SIMD3(corner & 1 == 0 ? low.x : high.x, corner & 2 == 0 ? low.y : high.y, corner & 4 == 0 ? low.z : high.z)
                let w = model * SIMD4(p, 1)
                worldLow = simd_min(worldLow, SIMD3(w.x, w.y, w.z)); worldHigh = simd_max(worldHigh, SIMD3(w.x, w.y, w.z))
            }
            guard worldLow.x.isFinite, worldHigh.x.isFinite else { return }
            worldBounds = (worldLow, worldHigh)
            closed = true
        }
        // Filled once by `prepareWire`.
        var wireIndexBuffer: MTLBuffer?
        var wireIndexCount = 0
        /// Filled once by `prepareOutline`: one welded, smoothed normal per vertex (12 bytes each).
        var outlineNormals: MTLBuffer?

        init(vertexBuffer: MTLBuffer, vertexCount: Int, indexBuffer: MTLBuffer?, indexCount: Int, model: simd_float4x4, material: RenderMaterial, faceSizes: [UInt32]?) {
            self.vertexBuffer = vertexBuffer; self.vertexCount = vertexCount
            self.indexBuffer = indexBuffer; self.indexCount = indexCount
            self.model = model; self.material = material; self.faceSizes = faceSizes
            let inverseTranspose = simd_transpose(simd_inverse(model))
            normalMatrix = inverseTranspose
        }
    }

    var voxelParts: [Part]?
    public let hasTexturedView: Bool
    let parts: [Part]
    let skeletons: [ModelScene.Skeleton]
    /// The model's animations.
    public let clips: [ModelScene.AnimationClip]
    public let framing: Framing
    public let triangleCount: Int
    /// Metallic and roughness of the first material, which the view settings' sliders start from.
    public let authoredMaterial: RenderMaterial
    let device: MTLDevice
    private let lock = NSLock()
    private var wireState: WireState = .none
    private var outlineState: WireState = .none
    private enum WireState { case none, building, ready }

    /// Uploads a scene. Empty parts and unsupported primitives are skipped. A part with no normals of its
    /// own gets smooth ones generated (see `SmoothNormals`), which puts its vertices in
    /// triangle order.
    public init(device: MTLDevice, scene: ModelScene, maxTextureSide: Int = TextureUpload.maxSide) throws {
        let dataSide = min(2048, maxTextureSide)
        self.device = device
        var parts: [Part] = []
        var textures: [Int: MTLTexture] = [:], opaqueTextures: [Int: MTLTexture] = [:], dataTextures: [Int: MTLTexture] = [:]
        var triangles = 0
        var first: RenderMaterial?
        for (nodeIndex, node) in scene.nodes.enumerated() {
            guard let meshIndex = node.mesh, scene.meshes.indices.contains(meshIndex) else { continue }
            let world = scene.worldTransform(of: nodeIndex)
            for source in scene.meshes[meshIndex].parts {
                let material = Self.material(for: source, in: scene)
                // MASK can reject every texel, even without a texture. Omit it from all
                // passes, including shadows, wires and outlines.
                if let cutoff = material.alphaCutoff, cutoff > 1 { continue }
                let isPoints = source.primitive == .points
                if (isPoints && !source.positions.isEmpty) || (source.primitive == .triangles && source.triangleIndices.count >= 3) {
                    if !isPoints { first = first ?? material }
                    // A skinned part is placed by its skeleton, not by its own node.
                    var placement = world
                    var skin = source.skin
                    if let s = skin, scene.skeletons.indices.contains(s.skeleton), s.joints.count == source.positions.count, s.weights.count == source.positions.count {
                        placement = scene.skeletons[s.skeleton].node.flatMap { scene.nodes.indices.contains($0) ? scene.worldTransform(of: $0) : nil } ?? matrix_identity_float4x4
                    } else {
                        skin = nil
                    }
                    let part = try isPoints
                        ? Self.uploadPoints(source, world: placement, material: material, device: device)
                        : Self.upload(source, skinned: skin != nil, world: placement, material: material, device: device)
                    if let skin {
                        try Self.attach(skin, to: part, device: device)
                        Self.attach(source.morphTargets, weights: scene.meshes[meshIndex].morphWeights, mesh: meshIndex, skin: skin, to: part)
                    }
                    // The image of the part's material, made once per image.
                    if part.uvBuffer != nil, let m = source.material, scene.materials.indices.contains(m) {
                        func colours(_ index: Int?, ignoresAlpha: Bool = true) -> MTLTexture? {
                            guard let t = index, scene.textures.indices.contains(t) else { return nil }
                            if ignoresAlpha {
                                if opaqueTextures[t] == nil { opaqueTextures[t] = TextureUpload.make(scene.textures[t], device: device, maxSide: maxTextureSide, ignoresAlpha: true) }
                                return opaqueTextures[t]
                            }
                            if textures[t] == nil { textures[t] = TextureUpload.make(scene.textures[t], device: device, maxSide: maxTextureSide) }
                            return textures[t]
                        }
                        let usesAlpha = material.alphaCutoff.map { $0 > 0 } ?? material.isBlended
                        part.texture = colours(scene.materials[m].baseColorTexture, ignoresAlpha: !usesAlpha)
                        // Data, not colours: no sRGB decoding, and half the size is plenty.
                        func data(_ index: Int?) -> MTLTexture? {
                            guard let t = index, scene.textures.indices.contains(t) else { return nil }
                            if dataTextures[t] == nil { dataTextures[t] = TextureUpload.make(scene.textures[t], device: device, srgb: false, maxSide: dataSide) }
                            return dataTextures[t]
                        }
                        if part.isPoints {
                            // Points use their base color and UV motion, without lighting maps.
                            part.uvMaskTexture = data(scene.materials[m].toon?.uvMaskTexture)
                        } else {
                            part.mapsTexture = data(scene.materials[m].metallicRoughnessTexture)
                            if part.mapsTexture == nil, scene.materials[m].metallicTexture != nil || scene.materials[m].roughnessTexture != nil {
                                // Two separate grey images: packed into one, once per pair.
                                let rough = scene.materials[m].roughnessTexture, metal = scene.materials[m].metallicTexture
                                let key = -1 - ((rough ?? -1) + 1) * 100_003 - ((metal ?? -1) + 1)
                                if dataTextures[key] == nil {
                                    func ref(_ i: Int?) -> ModelScene.TextureRef? { i.flatMap { scene.textures.indices.contains($0) ? scene.textures[$0] : nil } }
                                    dataTextures[key] = TextureUpload.makePacked(roughness: ref(rough), metallic: ref(metal), device: device, maxSide: dataSide)
                                }
                                part.mapsTexture = dataTextures[key]
                            }
                            part.normalTexture = data(scene.materials[m].normalTexture)
                            part.emissiveTexture = colours(scene.materials[m].emissiveTexture)
                            part.shadeTexture = colours(scene.materials[m].toon?.shadeTexture)
                            if let toon = scene.materials[m].toon {
                                part.matcapTexture = colours(toon.matcapTexture)
                                part.rimTexture = colours(toon.rimTexture)
                                part.shiftTexture = data(toon.shiftTexture)
                                part.outlineWidthTexture = data(toon.outlineWidthTexture)
                                part.uvMaskTexture = data(toon.uvMaskTexture)
                            }
                        }
                    }
                    parts.append(part)
                    if !isPoints { triangles += source.triangleIndices.count / 3 }
                }
            }
        }
        // A model waiting for image files must have a usable texture on a drawn
        // surface before the viewer offers Textured. Importer-supplied roughness
        // alone would otherwise enable it even when every image is missing.
        if !scene.diagnostics.missingResources.isEmpty || !scene.textures.isEmpty {
            hasTexturedView = parts.contains { part in
                !part.isPoints && (part.texture != nil || part.mapsTexture != nil || part.normalTexture != nil
                    || part.emissiveTexture != nil || part.shadeTexture != nil || part.matcapTexture != nil
                    || part.rimTexture != nil || part.shiftTexture != nil || part.outlineWidthTexture != nil
                    || part.uvMaskTexture != nil)
            }
        } else {
            hasTexturedView = scene.hasTexturedAppearance
        }
        self.parts = parts
        skeletons = scene.skeletons
        if let system = scene.springs, scene.skeletons.indices.contains(system.skeleton) {
            let simulator = SpringSimulator(system, skeleton: scene.skeletons[system.skeleton])
            if !simulator.isEmpty { springs = simulator; springSkeleton = system.skeleton }
        }
        clips = scene.clips.filter { scene.skeletons.indices.contains($0.skeleton) }
        triangleCount = triangles
        authoredMaterial = first ?? .plain
        if parts.contains(where: { $0.skin != nil }) {
            framing = AnimationBounds.framing(parts: parts, skeletons: scene.skeletons, clips: clips)
        } else if let b = scene.bounds {
            framing = Framing(min: b.min, max: b.max)
        } else {
            framing = .unit
        }
        for part in parts where part.material.isBlended {
            if let skin = part.skin { skin.refreshCenterContributions() }
            let floats = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
            var center = SIMD3<Float>.zero
            part.forEachDrawnVertex { i in
                center += SIMD3(floats[i * 6], floats[i * 6 + 1], floats[i * 6 + 2]) / Float(part.drawnVertexCount)
            }
            let world = part.model * SIMD4(center, 1)
            part.worldCenter = SIMD3(world.x, world.y, world.z)
        }
        // Skinned parts start in the rest pose: put there now, for whatever reads the
        // vertices before a frame is drawn, and again by the GPU with the first frame, so
        // that every frame comes from the same arithmetic.
        pose()
        poseOnCPU(poseMatrices)
    }

    static func material(for part: ModelScene.MeshPart, in scene: ModelScene) -> RenderMaterial {
        guard let index = part.material, scene.materials.indices.contains(index) else {
            var fallback = RenderMaterial.plain
            if part.primitive == .points, !part.colors.isEmpty, part.colors.count == part.positions.count {
                fallback.baseColor = SIMD3(repeating: 1)
            }
            return fallback
        }
        let m = scene.materials[index]
        return RenderMaterial(baseColor: srgbToLinear(SIMD3(m.baseColor.x, m.baseColor.y, m.baseColor.z)), metallic: m.metallic, roughness: m.roughness,
                              normalScale: m.normalScale.isFinite ? m.normalScale : 1, normalYSign: m.normalYSign < 0 ? -1 : 1,
                              opacity: min(max(m.opacity.isFinite ? m.opacity : 1, 0), 1),
                              alphaBlend: m.alphaBlend, alphaCutoff: m.alphaCutoff.flatMap { $0.isFinite ? max($0, 0) : nil },
                              emissive: simd_clamp(SIMD3(m.emissive.x.isFinite ? m.emissive.x : 0, m.emissive.y.isFinite ? m.emissive.y : 0, m.emissive.z.isFinite ? m.emissive.z : 0), SIMD3(repeating: 0), SIMD3(repeating: 64)),
                              doubleSided: m.doubleSided, oneSided: m.oneSided && !m.doubleSided, unlit: m.unlit,
                              toon: m.toon.map { RenderToon(shadeColor: srgbToLinear($0.shadeColor), shift: $0.shift.isFinite ? $0.shift : 0, toony: $0.toony.isFinite ? min(max($0.toony, 0), 0.999) : 0.9,
                                                            outlineWidth: $0.outlineWidth.isFinite ? max(0, $0.outlineWidth) : 0, outlineOnScreen: $0.outlineOnScreen,
                                                            outlineColor: srgbToLinear($0.outlineColor), outlineLightingMix: $0.outlineLightingMix,
                                                            shiftTextureScale: $0.shiftTextureScale.isFinite ? $0.shiftTextureScale : 1,
                                                            matcapColor: simd_clamp($0.matcapColor.x.isFinite && $0.matcapColor.y.isFinite && $0.matcapColor.z.isFinite ? $0.matcapColor : SIMD3(1, 1, 1), SIMD3(repeating: 0), SIMD3(repeating: 64)),
                                                            rimColor: srgbToLinear($0.rimColor),
                                                            rimFresnelPower: $0.rimFresnelPower.isFinite ? min(max($0.rimFresnelPower, 0), 1000) : 5,
                                                            rimLift: $0.rimLift.isFinite ? $0.rimLift : 0,
                                                            rimLightingMix: $0.rimLightingMix.isFinite ? min(max($0.rimLightingMix, 0), 1) : 1,
                                                            uvScroll: $0.uvScroll.x.isFinite && $0.uvScroll.y.isFinite ? $0.uvScroll : .zero,
                                                            uvRotation: $0.uvRotation.isFinite ? $0.uvRotation : 0) },
                              sampling: m.sampling, metallicRoughnessSampling: m.metallicRoughnessSampling, normalSampling: m.normalSampling, emissiveSampling: m.emissiveSampling)
    }

    private static func upload(_ source: ModelScene.MeshPart, skinned: Bool = false, world: simd_float4x4, material: RenderMaterial, device: MTLDevice) throws -> Part {
        let count = source.positions.count
        let corners = source.triangleIndices.count - source.triangleIndices.count % 3
        guard source.triangleIndices.prefix(corners).allSatisfy({ Int($0) < count }) else { throw RenderError.badIndices }

        let hasNormals = source.normals.count == count
        let hasColors = source.colors.count == count
        // No normals in the file. A part marked faceted is shaded flat. A large one gets one
        // averaged normal per vertex and keeps its shared vertices; giving every corner its
        // own normal, as below, would multiply its vertices several times over.
        // A skinned part keeps the file's vertices one for one, so joints and weights still fit.
        if !hasNormals, source.faceted || skinned || corners / 3 > Self.creaseLimit {
            let part = try uploadIndexed(source, corners: corners, faceted: source.faceted || !source.morphTargets.isEmpty, world: world, material: material, device: device)
            if hasColors { part.colorBuffer = try colorBuffer(source.colors, count: count, device: device) { $0 } }
            if source.uv0.count == count { part.uvBuffer = try uvBuffer(source.uv0, count: count, device: device) { $0 } }
            return part
        }
        if hasNormals, !skinned, source.uv0.isEmpty, !hasColors, isFaceted(source, corners: corners),
           let part = try uploadFaceted(source, corners: corners, world: world, material: material, device: device) {
            return part
        }
        let vertexCount = hasNormals ? count : corners
        let length = vertexCount * vertexStride
        guard length < device.maxBufferLength, let vertices = device.makeBuffer(length: length, options: .storageModeShared) else { throw RenderError.tooLarge }
        let out = vertices.contents().assumingMemoryBound(to: Float.self)

        var indexBuffer: MTLBuffer?
        if hasNormals {
            source.positions.withUnsafeBufferPointer { p in
                source.normals.withUnsafeBufferPointer { n in
                    for i in 0..<count {
                        out[i * 6] = p[i].x; out[i * 6 + 1] = p[i].y; out[i * 6 + 2] = p[i].z
                        out[i * 6 + 3] = n[i].x; out[i * 6 + 4] = n[i].y; out[i * 6 + 5] = n[i].z
                    }
                }
            }
            guard let buffer = source.triangleIndices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: corners * 4, options: .storageModeShared) }) else { throw RenderError.tooLarge }
            indexBuffer = buffer
        } else {
            let normals = SmoothNormals.generate(positions: source.positions, triangleIndices: source.triangleIndices)
            source.positions.withUnsafeBufferPointer { p in
                source.triangleIndices.withUnsafeBufferPointer { idx in
                    normals.withUnsafeBufferPointer { n in
                        for i in 0..<corners {
                            let v = p[Int(idx[i])]
                            out[i * 6] = v.x; out[i * 6 + 1] = v.y; out[i * 6 + 2] = v.z
                            out[i * 6 + 3] = n[i].x; out[i * 6 + 4] = n[i].y; out[i * 6 + 5] = n[i].z
                        }
                    }
                }
            }
        }
        let part = Part(vertexBuffer: vertices, vertexCount: vertexCount, indexBuffer: indexBuffer, indexCount: corners, model: world, material: material, faceSizes: source.faceSizes)
        if hasColors {
            part.colorBuffer = try source.triangleIndices.withUnsafeBufferPointer { idx in
                try colorBuffer(source.colors, count: vertexCount, device: device) { hasNormals ? $0 : Int(idx[$0]) }
            }
        }
        if source.uv0.count == count {
            part.uvBuffer = try source.triangleIndices.withUnsafeBufferPointer { idx in
                try uvBuffer(source.uv0, count: vertexCount, device: device) { hasNormals ? $0 : Int(idx[$0]) }
            }
        }
        if hasNormals { part.checkClosed() }
        return part
    }

    /// Texture coordinates as the GPU takes them; vertex `i` gets `uvs[source(i)]`.
    private static func uvBuffer(_ uvs: [SIMD2<Float>], count: Int, device: MTLDevice, source: (Int) -> Int) throws -> MTLBuffer {
        guard count > 0, let buffer = device.makeBuffer(length: count * 8, options: .storageModeShared) else { throw RenderError.tooLarge }
        let out = buffer.contents().assumingMemoryBound(to: Float.self)
        uvs.withUnsafeBufferPointer { u in
            for i in 0..<count { let v = u[source(i)]; out[i * 2] = v.x; out[i * 2 + 1] = v.y }
        }
        return buffer
    }

    /// Gives a part its skin: the uploaded vertices taken into the skeleton's bind space,
    /// kept as the rest shape, and buffers to pose into.
    private static func attach(_ skin: ModelScene.Skin, to part: Part, device: MTLDevice) throws {
        let count = part.vertexCount
        var rest = [Float](repeating: 0, count: count * 6)
        let source = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
        let g = skin.geometryBind
        let linear = simd_float3x3(SIMD3(g.columns.0.x, g.columns.0.y, g.columns.0.z), SIMD3(g.columns.1.x, g.columns.1.y, g.columns.1.z), SIMD3(g.columns.2.x, g.columns.2.y, g.columns.2.z))
        let forNormals = simd_determinant(linear) != 0 ? simd_transpose(simd_inverse(linear)) : linear
        for i in 0..<count {
            let p = g * SIMD4(source[i * 6], source[i * 6 + 1], source[i * 6 + 2], 1)
            let n = forNormals * SIMD3(source[i * 6 + 3], source[i * 6 + 4], source[i * 6 + 5])
            rest[i * 6] = p.x; rest[i * 6 + 1] = p.y; rest[i * 6 + 2] = p.z
            rest[i * 6 + 3] = n.x; rest[i * 6 + 4] = n.y; rest[i * 6 + 5] = n.z
        }
        guard let restBuffer = rest.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let jointsBuffer = skin.joints.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let weightsBuffer = skin.weights.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { throw RenderError.tooLarge }
        part.windingJoint = skin.windingJoint
        part.skin = SkinData(skeleton: skin.skeleton, rest: rest, joints: skin.joints, weights: skin.weights,
                             restBuffer: restBuffer, jointsBuffer: jointsBuffer, weightsBuffer: weightsBuffer,
                             drawIndices: part.indexBuffer, drawIndexCount: part.indexCount)
        // Its shape changes, so what was found out about the uploaded shape does not hold.
        part.closed = false
    }

    /// Gives a skinned part its other shapes, taken into the skeleton's bind space like its
    /// vertices, and shows the weights the file starts with.
    private static func attach(_ targets: [ModelScene.MorphTarget], weights: [Float], mesh: Int, skin: ModelScene.Skin, to part: Part) {
        let count = part.vertexCount
        let usable = targets.filter { $0.positions.count == count }
        guard let data = part.skin, !usable.isEmpty, usable.count == targets.count else { return }
        let g = skin.geometryBind
        let linear = simd_float3x3(SIMD3(g.columns.0.x, g.columns.0.y, g.columns.0.z), SIMD3(g.columns.1.x, g.columns.1.y, g.columns.1.z), SIMD3(g.columns.2.x, g.columns.2.y, g.columns.2.z))
        let forNormals = simd_determinant(linear) != 0 ? simd_transpose(simd_inverse(linear)) : linear
        let deltas = usable.map { target -> [Float] in
            var out = [Float](repeating: 0, count: count * 6)
            let hasNormals = target.normals.count == count
            for i in 0..<count {
                let p = linear * target.positions[i]
                out[i * 6] = p.x.isFinite ? p.x : 0; out[i * 6 + 1] = p.y.isFinite ? p.y : 0; out[i * 6 + 2] = p.z.isFinite ? p.z : 0
                if hasNormals {
                    let n = forNormals * target.normals[i]
                    out[i * 6 + 3] = n.x.isFinite ? n.x : 0; out[i * 6 + 4] = n.y.isFinite ? n.y : 0; out[i * 6 + 5] = n.z.isFinite ? n.z : 0
                }
            }
            return out
        }
        var defaults = [Float](repeating: 0, count: deltas.count)
        for (i, w) in weights.prefix(deltas.count).enumerated() where w.isFinite { defaults[i] = w }
        data.morph = MorphData(mesh: mesh, base: data.rest, targets: deltas, defaults: defaults)
        show(defaults, on: data)
    }

    /// Writes the shape the weights make over the skin's rest shape. True when it changed.
    @discardableResult
    private static func show(_ weights: [Float], on skin: SkinData) -> Bool {
        guard let morph = skin.morph else { return false }
        var wanted = [Float](repeating: 0, count: morph.targets.count)
        for (i, w) in weights.prefix(wanted.count).enumerated() where w.isFinite { wanted[i] = min(8, max(-8, w)) }
        if let current = morph.current, current == wanted { return false }
        var shape = morph.base
        shape.withUnsafeMutableBufferPointer { out in
            // Most targets are at rest most of the time: only those showing are added.
            for (t, w) in wanted.enumerated() where w != 0 {
                morph.targets[t].withUnsafeBufferPointer { delta in
                    for i in 0..<out.count { out[i] += delta[i] * w }
                }
            }
        }
        // A queued frame retains its buffer. Never overwrite bytes it may still read.
        guard let buffer = shape.withUnsafeBytes({ skin.restBuffer.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return false }
        skin.restBuffer = buffer
        morph.current = wanted
        skin.rest = shape
        if skin.centerContributions != nil { skin.refreshCenterContributions() }
        return true
    }

    // MARK: Posing

    /// The joints' matrices of the pose to show, by skeleton, and whether the vertices
    /// still have to be moved to it.
    private var poseMatrices: [Int: [simd_float4x4]] = [:]
    private var poseIsDue = false

    /// Sets the pose to show: where each skeleton is `time` seconds into a clip, or the
    /// rest pose when `clip` is nil. Parts of other skeletons than the clip's rest. The
    /// vertices are moved when the next frame is encoded.
    ///
    /// `elapsed` is the time since the pose shown before, which the springs (hair, skirts)
    /// are moved by; the answer is whether they are still moving. Call it from one thread.
    @discardableResult
    public func pose(clip: Int? = nil, time: Float = 0, elapsed: Float = 0) -> Bool {
        guard parts.contains(where: { $0.skin != nil }) else { return false }
        var swinging = false
        let playing = clip.flatMap { clips.indices.contains($0) ? clips[$0] : nil }
        var matrices: [Int: [simd_float4x4]] = [:]
        for part in parts {
            guard let skin = part.skin, skeletons.indices.contains(skin.skeleton) else { continue }
            // The other shapes: as the clip has them at this moment, or as the file starts.
            if let morph = skin.morph {
                Self.show(playing?.morphs.first { $0.mesh == morph.mesh }?.weights(at: time) ?? morph.defaults, on: skin)
            }
            guard matrices[skin.skeleton] == nil else { continue }
            let skeleton = skeletons[skin.skeleton], moving = playing?.skeleton == skin.skeleton ? playing : nil
            if springs != nil, springSkeleton == skin.skeleton {
                var locals = skeleton.localMatrices(clip: moving, time: time)
                // A long gap (the window was hidden) is not caught up with.
                let fastest = springs?.step(min(max(elapsed, 0), Self.longestSpringStep), locals: &locals) ?? 0
                springsRest = fastest < Self.springRest ? springsRest + 1 : 0
                swinging = elapsed > 0 ? springsRest < Self.springRestFrames : !springsAreSettled
                matrices[skin.skeleton] = skeleton.skinMatrices(locals: locals)
            } else {
                matrices[skin.skeleton] = skeleton.skinMatrices(clip: moving, time: time)
            }
        }
        lock.lock()
        poseMatrices = matrices
        poseIsDue = true
        lock.unlock()
        return swinging
    }

    private var springs: SpringSimulator?
    private var springSkeleton = 0
    /// How many poses in a row the springs have hardly moved.
    private var springsRest = 0
    static let longestSpringStep: Float = 1.0 / 30
    /// A tail that moves less than this share of its bone's length in a step is at rest.
    static let springRest: Float = 2e-4
    static let springRestFrames = 20

    /// Whether a material slides or turns its images over time (a cartoon material's own
    /// motion), so that the picture changes while nothing else does.
    public var hasMovingTextures: Bool {
        parts.contains { part in part.uvBuffer != nil && part.material.toon.map { $0.uvScroll != .zero || $0.uvRotation != 0 } == true }
    }

    /// Whether the model has parts that swing by themselves.
    public var hasSprings: Bool { springs != nil }
    private var springsAreSettled: Bool { springsRest >= Self.springRestFrames }

    /// Lets the springs fall to where they come to rest, at once (for a still picture, and
    /// when motion is to be reduced). The next `pose` shows them there.
    public func settleSprings(clip: Int? = nil, time: Float = 0, longest seconds: Float = 10) {
        guard springs != nil, skeletons.indices.contains(springSkeleton) else { return }
        let playing = clip.flatMap { clips.indices.contains($0) ? clips[$0] : nil }
        let rest = skeletons[springSkeleton].localMatrices(clip: playing?.skeleton == springSkeleton ? playing : nil, time: time)
        let step: Float = 1.0 / 60
        for _ in 0..<Int(seconds / step) where !springsAreSettled {
            var locals = rest
            let fastest = springs?.step(step, locals: &locals) ?? 0
            springsRest = fastest < Self.springRest ? springsRest + 1 : 0
        }
        springsRest = Self.springRestFrames
    }

    /// What the GPU's pass is told: how many vertices and joints, and whether there are
    /// outline normals to turn as well. Matches `SkinU` in the shaders.
    struct SkinUniforms { var vertexCount: UInt32; var jointCount: UInt32; var hasOutline: UInt32; var pad: UInt32 = 0 }

    /// Moves the skinned parts to the pose last set, if that has not been done: on the GPU
    /// with `pipeline`, in `commandBuffer` ahead of the frame that draws them, or on the
    /// CPU when there is no pipeline.
    func encodePose(into commandBuffer: MTLCommandBuffer, pipeline: MTLComputePipelineState?, voxel: Bool = false) {
        lock.lock()
        let due = poseIsDue || (voxel && voxelParts == nil && !poseMatrices.isEmpty), matrices = poseMatrices, outlined = outlineState == .ready
        poseIsDue = false
        lock.unlock()
        guard due else { return }
        voxelParts = nil
        updateWinding(matrices)
        updateTransparencyCenters(matrices)
        guard !voxel, let pipeline, let encoder = commandBuffer.makeComputeCommandEncoder() else { poseOnCPU(matrices); return }
        encoder.setComputePipelineState(pipeline)
        var jointBuffers: [Int: MTLBuffer] = [:]
        for part in parts {
            guard let skin = part.skin, let joints = matrices[skin.skeleton], !joints.isEmpty else { continue }
            if jointBuffers[skin.skeleton] == nil {
                jointBuffers[skin.skeleton] = joints.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            }
            guard let jointBuffer = jointBuffers[skin.skeleton] else { continue }
            let outline = outlined ? part.outlineNormals : nil, restOutline = outlined ? skin.restOutlineBuffer : nil
            var u = SkinUniforms(vertexCount: UInt32(part.vertexCount), jointCount: UInt32(joints.count), hasOutline: outline != nil && restOutline != nil ? 1 : 0)
            encoder.setBuffer(skin.restBuffer, offset: 0, index: 0)
            encoder.setBuffer(skin.jointsBuffer, offset: 0, index: 1)
            encoder.setBuffer(skin.weightsBuffer, offset: 0, index: 2)
            encoder.setBuffer(jointBuffer, offset: 0, index: 3)
            encoder.setBuffer(part.vertexBuffer, offset: 0, index: 4)
            // Without an outline these two are never read or written; something has to be bound.
            encoder.setBuffer(u.hasOutline == 1 ? restOutline : skin.restBuffer, offset: 0, index: 5)
            encoder.setBuffer(u.hasOutline == 1 ? outline : skin.restBuffer, offset: 0, index: 6)
            encoder.setBytes(&u, length: MemoryLayout<SkinUniforms>.stride, index: 7)
            let width = pipeline.threadExecutionWidth
            encoder.dispatchThreadgroups(MTLSize(width: (part.vertexCount + width - 1) / width, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
        encoder.endEncoding()
    }

    /// Normal directions use the inverse transpose of the deformation. For a
    /// singular or non-finite transform, keep the finite rest normal instead.
    static func skinNormalMatrix(_ linear: simd_float3x3) -> simd_float3x3 {
        let det = simd_determinant(linear)
        guard det.isFinite, det != 0 else { return matrix_identity_float3x3 }
        let normal = simd_transpose(simd_inverse(linear))
        guard (0..<3).allSatisfy({ c in (0..<3).allSatisfy { normal[c][$0].isFinite } }) else { return matrix_identity_float3x3 }
        return normal
    }

    private func updateWinding(_ matrices: [Int: [simd_float4x4]]) {
        for part in parts {
            guard let skin = part.skin, let joint = part.windingJoint,
                  let transforms = matrices[skin.skeleton], transforms.indices.contains(joint) else { continue }
            part.posedMirrored = Part.isMirrored(part.model * transforms[joint])
        }
    }

    private func updateTransparencyCenters(_ matrices: [Int: [simd_float4x4]]) {
        for part in parts {
            guard let skin = part.skin, let centers = skin.centerContributions,
                  let transforms = matrices[skin.skeleton], !transforms.isEmpty else { continue }
            var center = SIMD4<Float>.zero
            for (joint, point) in centers { center += transforms[min(joint, transforms.count - 1)] * point }
            let world = part.model * SIMD4(center.x, center.y, center.z, 1)
            part.worldCenter = SIMD3(world.x, world.y, world.z)
        }
    }

    /// Back-to-front ordering within a translucent point cloud. Skin positions come
    /// from the pose inputs: the GPU output buffer may still belong to a queued frame.
    func orderedPointIndices(for part: Part, camera: OrbitCamera) -> MTLBuffer? {
        guard part.vertexCount > 1 else { return nil }
        lock.lock()
        let transforms = part.skin.flatMap { poseMatrices[$0.skeleton] }
        lock.unlock()
        let back = camera.basis.back, rest = part.skin?.restBuffer
        if let cached = part.pointOrder, cached.back == back, cached.rest === rest,
           cached.transforms == transforms { return cached.buffer }
        let floats = part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)
        var keys = [UInt32](repeating: 0, count: part.vertexCount)
        for i in 0..<part.vertexCount {
            var point: SIMD4<Float>
            if let skin = part.skin, let transforms, !transforms.isEmpty {
                let rest = SIMD4(skin.rest[i * 6], skin.rest[i * 6 + 1], skin.rest[i * 6 + 2], 1)
                point = .zero
                for k in 0..<4 where k == 0 || skin.weights[i][k] > 0 {
                    point += (transforms[min(Int(skin.joints[i][k]), transforms.count - 1)] * rest) * skin.weights[i][k]
                }
            } else {
                point = SIMD4(floats[i * 6], floats[i * 6 + 1], floats[i * 6 + 2], 1)
            }
            let world = part.model * SIMD4(point.x, point.y, point.z, 1)
            // Camera translation subtracts the same depth from every point, so it
            // cannot change order and must not invalidate the cached buffer.
            let depth = simd_dot(SIMD3(world.x, world.y, world.z), back)
            // Map IEEE floats to unsigned order. Canonical zero preserves source order
            // for equal depths; invalid transformed coordinates get a deterministic key.
            let bits = (depth.isNaN || depth == 0 ? Float.zero : depth).bitPattern
            keys[i] = bits & 0x8000_0000 == 0 ? bits ^ 0x8000_0000 : ~bits
        }
        // Four stable counting passes bound sorting work to O(n), including a large
        // cloud whose camera or pose changes every frame. Equal depths keep input order.
        var indices = (0..<part.vertexCount).map(UInt32.init)
        var scratch = [UInt32](repeating: 0, count: part.vertexCount)
        for shift in stride(from: 0, to: 32, by: 8) {
            var offsets = [Int](repeating: 0, count: 256)
            for key in keys { offsets[Int((key >> shift) & 255)] += 1 }
            var total = 0
            for bucket in offsets.indices {
                let count = offsets[bucket]; offsets[bucket] = total; total += count
            }
            for index in indices {
                let bucket = Int((keys[Int(index)] >> shift) & 255)
                scratch[offsets[bucket]] = index
                offsets[bucket] += 1
            }
            swap(&indices, &scratch)
        }
        guard let buffer = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
        part.pointOrder = PointOrder(back: back, rest: rest, transforms: transforms, buffer: buffer)
        return buffer
    }

    /// The same on the CPU, at once.
    func partsForVoxels() -> [Part] {
        if let voxelParts { return voxelParts }
        let surface = makeVoxelParts()
        voxelParts = surface
        return surface
    }

    private func poseOnCPU(_ matrices: [Int: [simd_float4x4]]) {
        updateWinding(matrices)
        updateTransparencyCenters(matrices)
        for part in parts {
            guard let skin = part.skin, let joints = matrices[skin.skeleton], !joints.isEmpty else { continue }
            // The CPU fallback also publishes a fresh output for pending GPU draws.
            guard let vertices = device.makeBuffer(length: part.vertexBuffer.length, options: .storageModeShared) else { continue }
            part.vertexBuffer = vertices
            if let old = part.outlineNormals {
                part.outlineNormals = device.makeBuffer(length: old.length, options: .storageModeShared)
            }
            let out = vertices.contents().assumingMemoryBound(to: Float.self)
            let outline = part.outlineNormals?.contents().assumingMemoryBound(to: Float.self)
            let count = part.vertexCount
            skin.rest.withUnsafeBufferPointer { rest in
                joints.withUnsafeBufferPointer { m in
                    for i in 0..<count {
                        let j = skin.joints[i], w = skin.weights[i]
                        var blended = m[min(Int(j.x), m.count - 1)] * w.x
                        if w.y > 0 { blended += m[min(Int(j.y), m.count - 1)] * w.y }
                        if w.z > 0 { blended += m[min(Int(j.z), m.count - 1)] * w.z }
                        if w.w > 0 { blended += m[min(Int(j.w), m.count - 1)] * w.w }
                        let p = blended * SIMD4(rest[i * 6], rest[i * 6 + 1], rest[i * 6 + 2], 1)
                        let linear = simd_float3x3(SIMD3(blended.columns.0.x, blended.columns.0.y, blended.columns.0.z), SIMD3(blended.columns.1.x, blended.columns.1.y, blended.columns.1.z), SIMD3(blended.columns.2.x, blended.columns.2.y, blended.columns.2.z))
                        let normal = Self.skinNormalMatrix(linear)
                        let n = normal * SIMD3(rest[i * 6 + 3], rest[i * 6 + 4], rest[i * 6 + 5])
                        out[i * 6] = p.x; out[i * 6 + 1] = p.y; out[i * 6 + 2] = p.z
                        out[i * 6 + 3] = n.x; out[i * 6 + 4] = n.y; out[i * 6 + 5] = n.z
                        if let outline, let base = skin.restOutline {
                            let o = normal * SIMD3(base[i * 3], base[i * 3 + 1], base[i * 3 + 2])
                            outline[i * 3] = o.x; outline[i * 3 + 1] = o.y; outline[i * 3 + 2] = o.z
                        }
                    }
                }
            }
        }
    }

    /// True when some part of the scene follows a skeleton.
    public var isSkinned: Bool { parts.contains { $0.skin != nil } }

    /// Above this many triangles a part without normals keeps its shared vertices (one
    /// averaged normal each) instead of getting crease-aware normals per corner.
    static let creaseLimit = 300_000

    /// Colours as the GPU takes them, 4 bytes per vertex; vertex `i` gets `colors[source(i)]`.
    private static func colorBuffer(_ colors: [SIMD4<Float>], count: Int, device: MTLDevice, source: (Int) -> Int) throws -> MTLBuffer {
        guard count > 0, let buffer = device.makeBuffer(length: count * 4, options: .storageModeShared) else { throw RenderError.tooLarge }
        let out = buffer.contents().assumingMemoryBound(to: UInt8.self)
        colors.withUnsafeBufferPointer { c in
            for i in 0..<count {
                let v = simd_clamp(c[source(i)], SIMD4(repeating: 0), SIMD4(repeating: 1)) * 255 + SIMD4(repeating: 0.5)
                out[i * 4] = UInt8(v.x); out[i * 4 + 1] = UInt8(v.y); out[i * 4 + 2] = UInt8(v.z); out[i * 4 + 3] = UInt8(v.w)
            }
        }
        return buffer
    }

    private static func uploadPoints(_ source: ModelScene.MeshPart, world: simd_float4x4, material: RenderMaterial, device: MTLDevice) throws -> Part {
        let count = source.positions.count
        guard count * vertexStride < device.maxBufferLength,
              let vertices = device.makeBuffer(length: count * vertexStride, options: .storageModeShared) else { throw RenderError.tooLarge }
        let out = vertices.contents().assumingMemoryBound(to: Float.self)
        source.positions.withUnsafeBufferPointer { p in
            for i in 0..<count {
                out[i * 6] = p[i].x; out[i * 6 + 1] = p[i].y; out[i * 6 + 2] = p[i].z
                out[i * 6 + 3] = 0; out[i * 6 + 4] = 0; out[i * 6 + 5] = 0
            }
        }
        let part = Part(vertexBuffer: vertices, vertexCount: count, indexBuffer: nil, indexCount: 0, model: world, material: material, faceSizes: nil)
        part.isPoints = true
        if source.colors.count == count { part.colorBuffer = try colorBuffer(source.colors, count: count, device: device) { $0 } }
        if source.uv0.count == count { part.uvBuffer = try uvBuffer(source.uv0, count: count, device: device) { $0 } }
        return part
    }

    /// True when every triangle's three corners carry the same normal: a mesh stored face by
    /// face, as STL is.
    private static func isFaceted(_ source: ModelScene.MeshPart, corners: Int) -> Bool {
        guard corners >= 3 else { return false }
        return source.normals.withUnsafeBufferPointer { n in
            source.triangleIndices.withUnsafeBufferPointer { idx in
                var t = 0
                while t < corners {
                    let a = n[Int(idx[t])], b = n[Int(idx[t + 1])], c = n[Int(idx[t + 2])]
                    if simd_distance_squared(a, b) > 1e-8 || simd_distance_squared(a, c) > 1e-8 { return false }
                    // Equal corner normals need not be the geometric face normal. Keep
                    // custom authored directions rather than replacing them when welding.
                    let pa = source.positions[Int(idx[t])], pb = source.positions[Int(idx[t + 1])], pc = source.positions[Int(idx[t + 2])]
                    let geometric = simd_cross(pb - pa, pc - pa)
                    guard simd_length_squared(a) > 0, simd_length_squared(geometric) > 0,
                          simd_dot(simd_normalize(a), simd_normalize(geometric)) > 1 - 1e-5 else { return false }
                    t += 3
                }
                return true
            }
        }
    }

    /// A face-by-face mesh repeats every corner (six million vertices for two million
    /// triangles where a million positions exist). Its corners are merged by position, and
    /// the flat look comes from the surface in the fragment stage, which needs no per-corner
    /// normal. That is a sixth of the vertex data to store and for the GPU to process each
    /// frame. The normal kept per vertex is the area-weighted average of its faces.
    private static func uploadFaceted(_ source: ModelScene.MeshPart, corners: Int, world: simd_float4x4, material: RenderMaterial, device: MTLDevice) throws -> Part? {
        let keys = PositionWelder.canonicalIDs(source.positions)
        // New index of each kept vertex, in order of first appearance.
        var remap = [UInt32](repeating: .max, count: keys.count)
        var unique = 0
        for i in 0..<keys.count where Int(keys[i]) == i { remap[i] = UInt32(unique); unique += 1 }
        guard unique > 0, unique * vertexStride < device.maxBufferLength,
              let vertices = device.makeBuffer(length: unique * vertexStride, options: .storageModeShared),
              let indices = device.makeBuffer(length: corners * 4, options: .storageModeShared) else { throw RenderError.tooLarge }
        let out = vertices.contents().assumingMemoryBound(to: Float.self)
        out.update(repeating: 0, count: unique * 6)
        let index = indices.contents().assumingMemoryBound(to: UInt32.self)
        source.positions.withUnsafeBufferPointer { p in
            for i in 0..<keys.count where Int(keys[i]) == i {
                let o = Int(remap[i]) * 6
                out[o] = p[i].x; out[o + 1] = p[i].y; out[o + 2] = p[i].z
            }
            source.triangleIndices.withUnsafeBufferPointer { idx in
                var t = 0
                while t < corners {
                    let a = Int(remap[Int(keys[Int(idx[t])])]), b = Int(remap[Int(keys[Int(idx[t + 1])])]), c = Int(remap[Int(keys[Int(idx[t + 2])])])
                    index[t] = UInt32(a); index[t + 1] = UInt32(b); index[t + 2] = UInt32(c)
                    let g = simd_cross(p[Int(idx[t + 1])] - p[Int(idx[t])], p[Int(idx[t + 2])] - p[Int(idx[t])])
                    for v in [a, b, c] { out[v * 6 + 3] += g.x; out[v * 6 + 4] += g.y; out[v * 6 + 5] += g.z }
                    t += 3
                }
            }
        }
        normalizeNormals(out, count: unique)
        let part = Part(vertexBuffer: vertices, vertexCount: unique, indexBuffer: indices, indexCount: corners, model: world, material: material, faceSizes: source.faceSizes)
        part.faceted = true
        part.checkClosed()
        return part
    }

    /// Positions and indices go up as they are, with the area-weighted average of its faces
    /// as each vertex's normal: for a part marked `faceted` (shaded flat; the normal serves
    /// the outline) and for a large part that came without normals (shaded smooth with it).
    private static func uploadIndexed(_ source: ModelScene.MeshPart, corners: Int, faceted: Bool, world: simd_float4x4, material: RenderMaterial, device: MTLDevice) throws -> Part {
        let count = source.positions.count
        guard count > 0, count * vertexStride < device.maxBufferLength,
              let vertices = device.makeBuffer(length: count * vertexStride, options: .storageModeShared),
              let indices = source.triangleIndices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: corners * 4, options: .storageModeShared) })
        else { throw RenderError.tooLarge }
        let out = vertices.contents().assumingMemoryBound(to: Float.self)
        source.positions.withUnsafeBufferPointer { p in
            for i in 0..<count {
                out[i * 6] = p[i].x; out[i * 6 + 1] = p[i].y; out[i * 6 + 2] = p[i].z
                out[i * 6 + 3] = 0; out[i * 6 + 4] = 0; out[i * 6 + 5] = 0
            }
            source.triangleIndices.withUnsafeBufferPointer { idx in
                var t = 0
                while t < corners {
                    let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
                    let g = simd_cross(p[b] - p[a], p[c] - p[a])
                    for v in [a, b, c] { out[v * 6 + 3] += g.x; out[v * 6 + 4] += g.y; out[v * 6 + 5] += g.z }
                    t += 3
                }
            }
        }
        normalizeNormals(out, count: count)
        let part = Part(vertexBuffer: vertices, vertexCount: count, indexBuffer: indices, indexCount: corners, model: world, material: material, faceSizes: source.faceSizes)
        part.faceted = faceted
        part.checkClosed()
        return part
    }

    /// Makes the summed normals in a vertex buffer (floats 3 to 5 of each vertex) unit length.
    private static func normalizeNormals(_ out: UnsafeMutablePointer<Float>, count: Int) {
        for v in 0..<count {
            let n = SIMD3(out[v * 6 + 3], out[v * 6 + 4], out[v * 6 + 5]), length = simd_length(n)
            let unit = length > 0 && length.isFinite ? n / length : SIMD3<Float>(0, 0, 1)
            out[v * 6 + 3] = unit.x; out[v * 6 + 4] = unit.y; out[v * 6 + 5] = unit.z
        }
    }

    // MARK: Wire

    public var isWireReady: Bool { lock.lock(); defer { lock.unlock() }; return wireState == .ready }

    /// Builds the line geometry of the polygon wire, once. Synchronous.
    public func prepareWire() {
        lock.lock()
        if wireState != .none { lock.unlock(); return }
        wireState = .building
        lock.unlock()
        for part in parts where !part.isPoints { buildWire(part) }
        lock.lock(); wireState = .ready; lock.unlock()
    }

    /// Builds the wire on a background queue (a no-op if started); `completion` runs on
    /// that queue once it is ready.
    public func prepareWireAsync(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        let state = wireState
        lock.unlock()
        if state == .ready { completion(); return }
        if state == .building { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            prepareWire()
            completion()
        }
    }

    /// Runs `body` on the part's vertices (six floats each). A skinned part is looked at in
    /// the shape it was bound in, whatever pose it is in now.
    private func withShape<T>(of part: Part, _ body: (UnsafePointer<Float>) -> T) -> T {
        if let skin = part.skin { return skin.rest.withUnsafeBufferPointer { body($0.baseAddress!) } }
        return body(UnsafePointer(part.vertexBuffer.contents().assumingMemoryBound(to: Float.self)))
    }

    private func buildWire(_ part: Part) {
        let stride = Self.vertexStride / 4
        // Corners at the same position are the same point, whether or not the file shares
        // vertices (STL repeats every corner), so each edge is drawn once.
        let keys = withShape(of: part) { PositionWelder.canonicalIDs(floats: $0, stride: stride, count: part.vertexCount) }
        var edges: [UInt32]
        if let indexBuffer = part.indexBuffer {
            let indices = Array(UnsafeBufferPointer(start: indexBuffer.contents().assumingMemoryBound(to: UInt32.self), count: part.indexCount))
            let corners = WireLines.edges(triangleIndices: indices, faceSizes: part.faceSizes, vertexKeys: keys)
            edges = corners.map { indices[Int($0)] }
        } else {
            let identity = (0..<UInt32(part.vertexCount)).map { $0 }
            edges = WireLines.edges(triangleIndices: identity, faceSizes: part.faceSizes, vertexKeys: keys)
        }
        guard !edges.isEmpty else { return }
        part.wireIndexBuffer = edges.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: edges.count * 4, options: .storageModeShared) }
        part.wireIndexCount = edges.count
    }

    // MARK: Outline

    public var isOutlineReady: Bool { lock.lock(); defer { lock.unlock() }; return outlineState == .ready }

    /// Builds the normals the outline hull is pushed along, once. Synchronous.
    public func prepareOutline() {
        lock.lock()
        if outlineState != .none { lock.unlock(); return }
        outlineState = .building
        lock.unlock()
        for part in parts where !part.isPoints { buildOutline(part) }
        // The new normals are in the bind pose; they are turned to the pose with the next frame.
        lock.lock(); outlineState = .ready; poseIsDue = poseIsDue || isSkinned; lock.unlock()
    }

    /// Builds the outline normals on a background queue; `completion` runs there when ready.
    public func prepareOutlineAsync(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        let state = outlineState
        lock.unlock()
        if state == .ready { completion(); return }
        if state == .building { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            prepareOutline()
            completion()
        }
    }

    /// The hull of an outline is the mesh pushed along its normals. The mesh's own normals
    /// differ between the corners that sit at one position (STL gives every face its own; a
    /// cube has hard edges), so pushing along them tears the hull open along those edges.
    /// These normals are instead summed (area-weighted) over everything at one position, so
    /// all corners at a position move together and the hull stays closed.
    private func buildOutline(_ part: Part) {
        withShape(of: part) { buildOutline(part, floats: $0) }
    }

    private func buildOutline(_ part: Part, floats: UnsafePointer<Float>) {
        let stride = Self.vertexStride / 4
        let count = part.vertexCount
        guard let buffer = device.makeBuffer(length: max(count, 1) * 12, options: .storageModeShared) else { return }
        // Working memory is kept to the welding table: sums are gathered in the output buffer
        // itself, at the first vertex of each position, and positions are read in place.
        let out = buffer.contents().assumingMemoryBound(to: Float.self)
        out.update(repeating: 0, count: max(count, 1) * 3)
        let keys = PositionWelder.canonicalIDs(floats: floats, stride: stride, count: count)
        @inline(__always) func position(_ i: Int) -> SIMD3<Float> { SIMD3(floats[i * stride], floats[i * stride + 1], floats[i * stride + 2]) }
        @inline(__always) func add(_ a: Int, _ b: Int, _ c: Int) {
            let pa = position(a)
            let g = simd_cross(position(b) - pa, position(c) - pa)
            for v in [a, b, c] {
                let k = Int(keys[v]) * 3
                out[k] += g.x; out[k + 1] += g.y; out[k + 2] += g.z
            }
        }
        if let indexBuffer = part.indexBuffer {
            let idx = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            var t = 0
            while t + 2 < part.indexCount { add(Int(idx[t]), Int(idx[t + 1]), Int(idx[t + 2])); t += 3 }
        } else {
            var t = 0
            while t + 2 < count { add(t, t + 1, t + 2); t += 3 }
        }
        // First the vertex that stands for each position, then every other one copies it
        // (the first vertex at a position always has the lower index).
        for i in 0..<count where Int(keys[i]) == i {
            var n = SIMD3(out[i * 3], out[i * 3 + 1], out[i * 3 + 2])
            if simd_length_squared(n) < 1e-20 { n = SIMD3(floats[i * stride + 3], floats[i * stride + 4], floats[i * stride + 5]) }
            else { n = simd_normalize(n) }
            out[i * 3] = n.x; out[i * 3 + 1] = n.y; out[i * 3 + 2] = n.z
        }
        for i in 0..<count where Int(keys[i]) != i {
            let k = Int(keys[i]) * 3
            out[i * 3] = out[k]; out[i * 3 + 1] = out[k + 1]; out[i * 3 + 2] = out[k + 2]
        }
        // Kept in the bind pose too, to be turned with the joints at every pose.
        if let skin = part.skin {
            skin.restOutline = Array(UnsafeBufferPointer(start: out, count: count * 3))
            skin.restOutlineBuffer = device.makeBuffer(bytes: out, length: count * 12, options: .storageModeShared)
        }
        part.outlineNormals = buffer
    }

    /// Number of wire lines built so far.
    public var wireLineCount: Int { parts.reduce(0) { $0 + $1.wireIndexCount / 2 } }

    /// Parts found to be closed surfaces, whose back faces are left out.
    public var closedPartCount: Int { parts.filter(\.closed).count }

    /// Dots of the point clouds in the scene.
    public var pointCount: Int { parts.filter(\.isPoints).reduce(0) { $0 + $1.vertexCount } }

    /// Vertices held on the GPU, after any merging.
    public var vertexCount: Int { parts.reduce(0) { $0 + $1.vertexCount } }

    /// Vertex buffers, index buffers and wire indices, in bytes.
    public var gpuBytes: Int {
        parts.reduce(0) { $0 + $1.vertexBuffer.length + ($1.indexBuffer?.length ?? 0) + ($1.wireIndexBuffer?.length ?? 0) + ($1.colorBuffer?.length ?? 0) + ($1.uvBuffer?.length ?? 0) }
    }
}
