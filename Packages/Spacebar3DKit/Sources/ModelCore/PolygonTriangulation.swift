import simd

/// Triangles of a simple polygon, expressed as indices of its original corners. No corner
/// attributes are merged or moved. Successful output always has (count - 2) triangles.
public enum PolygonTriangulation {
    /// The ear search steps one file may spend on all its concave faces together
    /// (`Budget.fileSteps`, 16 million). A face is capped alone too (`Budget.perFace`, 64 million,
    /// the only cap for callers without a budget), but forty big spirals each under that cap took
    /// over a minute, so a file's whole allowance is a quarter of one face's. Measured: 64 million
    /// steps took about 14 s in Debug for a hostile file; 16 million take about a quarter of that.
    /// Legitimate faces still fit: a 4,000-corner star costs about 3.7 million steps, so the
    /// budget covers four of them, and ordinary concave faces cost a few hundred. A face the budget
    /// cannot finish is fanned from its first corner, so the user sees the whole surface, with
    /// wrong triangles where it is concave (never a hole), instead of a hang.
    public final class Budget {
        /// Most steps one face may take, with or without a file budget.
        public static let perFace = 64_000_000
        /// Steps all the concave faces of one file may take together (the default of `init`).
        public static let fileSteps = 16_000_000
        /// Steps every face may use whatever is left of the file's budget, and which are not charged
        /// to it. Ordinary concave faces cost a few hundred at most (an L 8, a 23-corner comb 161),
        /// so a spent budget never makes them wrong; a flood of tiny faces stays linear in the file
        /// (at most this many steps each); only a face that runs past both is fanned.
        public static let freePerFace = 4_096
        public private(set) var remaining: Int
        public init(steps: Int = Budget.fileSteps) { remaining = steps }
        fileprivate func spend(_ steps: Int) { remaining = max(0, remaining - max(0, steps - Budget.freePerFace)) }
    }

    public static func indices(count: Int, budget: Budget? = nil, position: (Int) -> SIMD3<Float>) -> [Int]? {
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
        // The corners still to be cut off, as a ring in their own order.
        var before = (0..<count).map { ($0 + count - 1) % count }, after = (0..<count).map { ($0 + 1) % count }
        var first = 0, left = count
        var triangles: [Int] = []
        triangles.reserveCapacity((count - 2) * 3)
        // Only a corner that turns the other way, or not at all, can lie in the triangle cut
        // off at another. `inward` lists the corners that ever did; `turnsIn` says which do now.
        var turnsIn = (0..<count).map { cross(before[$0], $0, after[$0]) * direction <= epsilon }
        var inward = (0..<count).filter { turnsIn[$0] }
        var listed = turnsIn
        func same(_ p: Int, _ q: Int) -> Bool { uv[p].x == uv[q].x && uv[p].y == uv[q].y }
        // Bound work on adversarial faces instead of hanging on a huge non-convex polygon.
        var work = 0
        let limit = budget.map { min(Budget.perFace, $0.remaining + Budget.freePerFace) } ?? Budget.perFace
        defer { budget?.spend(work) }
        func giveUp() -> [Int]? { budget == nil ? nil : fan() }
        while left > 3 {
            var ear: Int?
            var b = first
            for _ in 0..<left {
                work += 1
                guard work <= limit else { return giveUp() }
                if !turnsIn[b] {
                    let a = before[b], c = after[b]
                    var occupied = false
                    for p in inward where turnsIn[p] && p != a && p != c {
                        work += 1
                        guard work <= limit else { return giveUp() }
                        // An outline that goes in to a hole and back along one cut passes the
                        // cut's ends twice. The second pass is in nobody's way where it only
                        // stands on one of the triangle's own corners.
                        if same(p, a) || same(p, b) || same(p, c) { continue }
                        if cross(a,b,p) * direction >= -epsilon && cross(b,c,p) * direction >= -epsilon && cross(c,a,p) * direction >= -epsilon {
                            occupied = true; break
                        }
                    }
                    if !occupied { ear = b; break }
                }
                b = after[b]
            }
            // Keep collinear corners as zero-area triangles, preserving corner attributes
            // and polygon counts. This is also how a repeated adjacent corner is handled.
            if ear == nil {
                var b = first
                for _ in 0..<left {
                    if abs(cross(before[b], b, after[b])) <= epsilon { ear = b; break }
                    b = after[b]
                }
            }
            guard let b = ear else { return nil }
            let a = before[b], c = after[b]
            triangles += [a, b, c]
            after[a] = c; before[c] = a; left -= 1
            if b == first { first = c }
            turnsIn[b] = false
            // Its neighbours have a new neighbour each, and may turn the other way now.
            for v in [a, c] {
                turnsIn[v] = cross(before[v], v, after[v]) * direction <= epsilon
                if turnsIn[v], !listed[v] { inward.append(v); listed[v] = true }
            }
        }
        triangles += [first, after[first], after[after[first]]]
        return triangles
    }
}
