import Foundation
import simd

/// A file with nodes and no mesh (a VRM animation, an FBX with motion only) is shown as
/// its skeleton: a bone drawn from every node to each of its children.
extension ModelScene {
    public static let maxStickBones = 20_000

    /// Gives every node of the scene that has children a mesh of bones, in the node's own
    /// space, so that it moves with its node. Returns whether there is anything to show.
    public mutating func addStickFigure() -> Bool {
        var children: [Int: [Int]] = [:]
        for (i, node) in nodes.enumerated() { if let p = node.parent { children[p, default: []].append(i) } }
        var material = ModelScene.Material()
        material.name = "skeleton"
        material.baseColor = SIMD4(0.62, 0.78, 1, 1)
        material.metallic = 0
        material.roughness = 0.6
        materials.append(material)
        let materialIndex = materials.count - 1
        var bones = 0
        for (parent, below) in children.sorted(by: { $0.key < $1.key }) {
            var part = ModelScene.MeshPart()
            part.material = materialIndex
            part.faceted = true
            for child in below where bones < Self.maxStickBones {
                let c = nodes[child].transform.columns.3
                let tip = SIMD3(c.x, c.y, c.z), length = simd_length(tip)
                guard length > 1e-6, length.isFinite else { continue }
                // A long pyramid on a short one: thick near the joint it turns about.
                let along = tip / length
                let side = simd_normalize(simd_cross(along, abs(along.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
                let other = simd_cross(along, side)
                let width = length * 0.09, waist = along * (length * 0.18)
                let ring = [waist + side * width, waist + other * width, waist - side * width, waist - other * width]
                for k in 0..<4 {
                    let a = ring[k], b = ring[(k + 1) % 4]
                    for (p, q, r) in [(SIMD3<Float>.zero, b, a), (tip, a, b)] {
                        let normal = simd_cross(q - p, r - p), size = simd_length(normal)
                        let base = UInt32(part.positions.count)
                        part.positions += [p, q, r]
                        part.normals += [SIMD3<Float>](repeating: size > 0 ? normal / size : along, count: 3)
                        part.triangleIndices += [base, base + 1, base + 2]
                    }
                }
                bones += 1
            }
            guard !part.positions.isEmpty else { continue }
            meshes.append(ModelScene.Mesh(name: "skeleton", parts: [part]))
            nodes[parent].mesh = meshes.count - 1
        }
        return bones > 0
    }
}
