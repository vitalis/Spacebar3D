import simd

/// Triangles of a simple polygon, expressed as indices of its original corners. No corner
/// attributes are merged or moved. Successful output always has (count - 2) triangles.
public enum PolygonTriangulation {
    public static func indices(count: Int, position: (Int) -> SIMD3<Float>) -> [Int]? {
        guard count >= 3 else { return nil }
        if count == 3 { return [0, 1, 2] }
        let origin = SIMD3<Double>(position(0))
        let points = (0..<count).map { SIMD3<Double>(position($0)) - origin }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        var normal = SIMD3<Double>.zero
        for i in 0..<count { normal += simd_cross(points[i], points[(i + 1) % count]) }
        let n = simd_abs(normal)
        let axis = n.x >= n.y && n.x >= n.z ? 0 : n.y >= n.z ? 1 : 2
        var uv = points.map { p in axis == 0 ? SIMD2(p.y,p.z) : axis == 1 ? SIMD2(p.z,p.x) : SIMD2(p.x,p.y) }
        let extent = uv.reduce(0.0) { max($0, abs($1.x), abs($1.y)) }
        func fan() -> [Int] { (1..<(count - 1)).flatMap { [0, $0, $0 + 1] } }
        guard extent > 0 else { return fan() }
        uv = uv.map { $0 / extent }
        func cross(_ a: Int, _ b: Int, _ c: Int) -> Double {
            let u = uv[b] - uv[a], v = uv[c] - uv[a]
            return u.x * v.y - u.y * v.x
        }
        let area = (1..<(count - 1)).reduce(0.0) { $0 + cross(0, $1, $1 + 1) }
        let direction = area >= 0 ? 1.0 : -1.0
        // Coordinates are normalized to unit extent; this only absorbs Double rounding.
        let epsilon = 1e-12
        if (0..<count).allSatisfy({ cross(($0 + count - 1) % count, $0, ($0 + 1) % count) * direction >= -epsilon }) {
            return fan() // Convex faces, including large ones, stay linear-time.
        }
        guard abs(area) > epsilon else { return nil }
        var ring = Array(0..<count), triangles: [Int] = []
        triangles.reserveCapacity((count - 2) * 3)
        // Bound work on adversarial faces instead of hanging on a huge non-convex polygon.
        var work = 0
        while ring.count > 3 {
            var ear: Int?
            for i in ring.indices {
                work += 1
                guard work <= 4_000_000 else { return nil }
                let a = ring[(i + ring.count - 1) % ring.count], b = ring[i], c = ring[(i + 1) % ring.count]
                guard cross(a,b,c) * direction > epsilon else { continue }
                var occupied = false
                for p in ring where p != a && p != b && p != c {
                    work += 1
                    guard work <= 4_000_000 else { return nil }
                    if cross(a,b,p) * direction >= -epsilon && cross(b,c,p) * direction >= -epsilon && cross(c,a,p) * direction >= -epsilon {
                        occupied = true; break
                    }
                }
                if !occupied { ear = i; break }
            }
            // Keep collinear corners as zero-area triangles, preserving corner attributes
            // and polygon counts. This is also how a repeated adjacent corner is handled.
            if ear == nil {
                ear = ring.indices.first { i in
                    abs(cross(ring[(i + ring.count - 1) % ring.count], ring[i], ring[(i + 1) % ring.count])) <= epsilon
                }
            }
            guard let i = ear else { return nil }
            triangles += [ring[(i + ring.count - 1) % ring.count], ring[i], ring[(i + 1) % ring.count]]
            ring.remove(at: i)
        }
        triangles += ring
        return triangles
    }
}
