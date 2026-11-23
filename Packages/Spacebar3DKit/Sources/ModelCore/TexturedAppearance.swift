import simd

extension ModelScene {
    /// Saturation above which one material colour counts as a colour of its own, measured
    /// in linear RGB.
    static let texturedSaturation: Float = 0.08

    /// True when the model has an appearance of its own worth showing: a texture, vertex
    /// colours, material effects, or colours that are not a single neutral shade. Without one the
    /// model has no Textured view (it is shown in Solid) and no Unlit or Cartoon style.
    /// Only triangle parts count (meshes, not point clouds); a part with no material uses
    /// the default.
    public var hasTexturedAppearance: Bool {
        var first: SIMD3<Float>?
        for node in nodes {
            guard let m = node.mesh, meshes.indices.contains(m) else { continue }
            for part in meshes[m].parts where part.primitive == .triangles {
                if !part.colors.isEmpty { return true }
                let material = part.material.flatMap { materials.indices.contains($0) ? materials[$0] : nil } ?? Material()
                if material.baseColorTexture != nil || material.normalTexture != nil
                    || material.metallicRoughnessTexture != nil || material.metallicTexture != nil || material.roughnessTexture != nil
                    || material.emissiveTexture != nil || material.emissive != .zero
                    || material.opacity < 1 || material.alphaBlend || material.alphaCutoff != nil
                    || material.authoredPBR || material.unlit || material.toon != nil { return true }
                let color = SIMD3(material.baseColor.x, material.baseColor.y, material.baseColor.z)
                if first == nil { first = color }
                if first != color || Self.saturation(linear: Self.toLinear(color)) > Self.texturedSaturation { return true }
            }
        }
        return false
    }

    private static func toLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func f(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return SIMD3(f(c.x), f(c.y), f(c.z))
    }

    /// HSL saturation.
    static func saturation(linear c: SIMD3<Float>) -> Float {
        let hi = max(c.x, c.y, c.z), lo = min(c.x, c.y, c.z)
        let d = hi - lo
        if d == 0 { return 0 }
        let l = (hi + lo) / 2
        return l <= 0.5 ? d / (hi + lo) : d / (2 - hi - lo)
    }
}
