import Foundation
import ModelCore
import simd

/// Which vertices sit at the same place. STL (and any triangle soup) repeats a position for
/// every triangle that uses it; smooth shading and the wire's duplicate removal need to know.
public enum PositionWelder {
    /// For each vertex, the index of the first vertex at exactly the same position.
    public static func canonicalIDs(_ positions: [SIMD3<Float>]) -> [UInt32] {
        positions.withUnsafeBytes { raw in
            canonicalIDs(floats: raw.bindMemory(to: Float.self).baseAddress!, stride: MemoryLayout<SIMD3<Float>>.stride / 4, count: positions.count)
        }
    }

    /// The same, reading x, y, z straight from a vertex buffer (`stride` floats per vertex,
    /// position first), so a large mesh is not copied to be welded.
    public static func canonicalIDs(floats: UnsafePointer<Float>, stride: Int, count: Int) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: count)
        guard count > 0 else { return result }
        var capacity = 16
        while capacity < count * 2 { capacity <<= 1 }
        let mask = capacity - 1
        var table = [UInt32](repeating: .max, count: capacity)
        table.withUnsafeMutableBufferPointer { t in
            result.withUnsafeMutableBufferPointer { r in
                for i in 0..<count {
                    let x = floats[i * stride], y = floats[i * stride + 1], z = floats[i * stride + 2]
                    var slot = PositionHash.home(x, y, z) & mask
                    while true {
                        let found = t[slot]
                        if found == .max { t[slot] = UInt32(i); r[i] = UInt32(i); break }
                        let q = Int(found) * stride
                        if floats[q] == x && floats[q + 1] == y && floats[q + 2] == z { r[i] = found; break }
                        slot = (slot + 1) & mask
                    }
                }
            }
        }
        return result
    }
}

/// Normals for meshes that come without them.
public enum SmoothNormals {
    /// Default: faces turned further apart than this keep a sharp edge.
    public static let defaultCreaseAngle: Float = 45 * .pi / 180

    /// One normal per triangle corner (`triangleIndices[i]` -> `result[i]`). Corners at the
    /// same position share a normal made from the faces around it that bend away from the
    /// corner's own face by less than `creaseAngle`, weighted by the angle they fill at the vertex, so a cylinder's side
    /// is smooth and its rim and a cube's edges stay sharp.
    public static func generate(positions: [SIMD3<Float>], triangleIndices: [UInt32], creaseAngle: Float = defaultCreaseAngle) -> [SIMD3<Float>] {
        let corners = triangleIndices.count - triangleIndices.count % 3
        let triangles = corners / 3
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: corners)
        guard triangles > 0 else { return normals }

        // Unit face normals, and the angle each corner makes inside its triangle (the
        // weight a face has at a vertex: it does not depend on how a quad was split).
        var unit = [SIMD3<Float>](repeating: .zero, count: triangles)
        var angle = [Float](repeating: 0, count: corners)
        for t in 0..<triangles {
            let a = positions[Int(triangleIndices[t * 3])], b = positions[Int(triangleIndices[t * 3 + 1])], c = positions[Int(triangleIndices[t * 3 + 2])]
            let n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            guard length > 0 else { continue }
            unit[t] = n / length
            func interior(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
                let u = q - p, v = r - p
                let d = simd_length(u) * simd_length(v)
                return d > 0 ? acos(min(1, max(-1, simd_dot(u, v) / d))) : 0
            }
            angle[t * 3] = interior(a, b, c); angle[t * 3 + 1] = interior(b, c, a); angle[t * 3 + 2] = interior(c, a, b)
        }

        // Corners grouped by welded position (counting sort).
        let canon = PositionWelder.canonicalIDs(positions)
        var start = [UInt32](repeating: 0, count: positions.count + 1)
        for i in 0..<corners { start[Int(canon[Int(triangleIndices[i])]) + 1] += 1 }
        for i in 0..<positions.count { start[i + 1] += start[i] }
        var fill = start
        var order = [UInt32](repeating: 0, count: corners)
        for i in 0..<corners {
            let key = Int(canon[Int(triangleIndices[i])])
            order[Int(fill[key])] = UInt32(i)
            fill[key] += 1
        }

        let cosLimit = cos(creaseAngle)
        for key in 0..<positions.count {
            let lo = Int(start[key]), hi = Int(start[key + 1])
            if hi - lo == 0 { continue }
            // Very busy vertices (fans of thousands of triangles): one shared normal.
            let tooBusy = hi - lo > 96
            func contribution(_ k: Int) -> SIMD3<Float> { let c = Int(order[k]); return unit[c / 3] * angle[c] }
            var all = SIMD3<Float>.zero
            if tooBusy || hi - lo == 1 { for k in lo..<hi { all += contribution(k) } }
            for k in lo..<hi {
                let corner = Int(order[k]), own = unit[corner / 3]
                var sum = SIMD3<Float>.zero
                if tooBusy || hi - lo == 1 {
                    sum = all
                } else if own == .zero {
                    for j in lo..<hi { sum += contribution(j) }
                } else {
                    for j in lo..<hi {
                        if simd_dot(own, unit[Int(order[j]) / 3]) >= cosLimit { sum += contribution(j) }
                    }
                }
                let length = simd_length(sum)
                normals[corner] = length > 0 ? sum / length : (own == .zero ? SIMD3(0, 1, 0) : own)
            }
        }
        return normals
    }
}

extension SmoothNormals {
    /// The normals `generate` makes, for a mesh too large to give every corner a vertex of
    /// its own. The file's vertices keep their places and their sharing; a vertex is
    /// repeated, after them, only where its corners need different normals (along a sharp
    /// edge): `repeated` says which vertex each of those is a copy of, and `normals` has
    /// one for every vertex, the file's and then the repeated.
    ///
    /// The triangles' corners among these vertices are written to `indices`, which has room
    /// for as many as `triangleIndices` holds. Written in place, as the mesh is large.
    public static func indexed(positions: [SIMD3<Float>], triangleIndices: [UInt32], creaseAngle: Float = defaultCreaseAngle,
                               indices: UnsafeMutablePointer<UInt32>) -> (normals: [SIMD3<Float>], repeated: [UInt32]) {
        let corners = triangleIndices.count - triangleIndices.count % 3
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: positions.count)
        var repeated: [UInt32] = []
        for i in 0..<triangleIndices.count { indices[i] = triangleIndices[i] }
        guard corners > 0 else { return (normals, repeated) }

        // Corners grouped by welded position (counting sort).
        var canon = PositionWelder.canonicalIDs(positions)
        var start = [UInt32](repeating: 0, count: positions.count + 1)
        for i in 0..<corners { start[Int(canon[Int(triangleIndices[i])]) + 1] += 1 }
        for i in 0..<positions.count { start[i + 1] += start[i] }
        var fill = start
        var order = [UInt32](repeating: 0, count: corners)
        for i in 0..<corners {
            let key = Int(canon[Int(triangleIndices[i])])
            order[Int(fill[key])] = UInt32(i)
            fill[key] += 1
        }
        fill = []; canon = []

        let cosLimit = cos(creaseAngle)
        // Of the corners at one position: each one's face, and that face weighted by the
        // angle it fills there. Worked out as they are needed; kept for a whole mesh they
        // would be as large as the mesh.
        var unit: [SIMD3<Float>] = [], weighted: [SIMD3<Float>] = []
        var placed: [(vertex: UInt32, normal: SIMD3<Float>, index: UInt32)] = []
        for key in 0..<positions.count {
            let lo = Int(start[key]), hi = Int(start[key + 1])
            if hi == lo { continue }
            unit.removeAll(keepingCapacity: true); weighted.removeAll(keepingCapacity: true)
            for k in lo..<hi {
                let corner = Int(order[k]), triangle = corner - corner % 3
                let p = positions[Int(triangleIndices[corner])]
                let q = positions[Int(triangleIndices[triangle + (corner + 1) % 3])], r = positions[Int(triangleIndices[triangle + (corner + 2) % 3])]
                let u = q - p, v = r - p
                let n = simd_cross(u, v), length = simd_length(n)
                guard length > 0 else { unit.append(.zero); weighted.append(.zero); continue }
                let d = simd_length(u) * simd_length(v)
                unit.append(n / length)
                weighted.append(n / length * (d > 0 ? acos(min(1, max(-1, simd_dot(u, v) / d))) : 0))
            }
            // Very busy vertices (fans of thousands of triangles): one shared normal.
            let tooBusy = hi - lo > 96
            var all = SIMD3<Float>.zero
            if tooBusy || hi - lo == 1 { for w in weighted { all += w } }
            placed.removeAll(keepingCapacity: true)
            for k in 0..<(hi - lo) {
                let own = unit[k]
                var sum = SIMD3<Float>.zero
                if tooBusy || hi - lo == 1 {
                    sum = all
                } else if own == .zero {
                    for w in weighted { sum += w }
                } else {
                    for j in 0..<(hi - lo) where simd_dot(own, unit[j]) >= cosLimit { sum += weighted[j] }
                }
                let length = simd_length(sum)
                let normal = length > 0 ? sum / length : (own == .zero ? SIMD3(0, 1, 0) : own)
                let corner = Int(order[lo + k]), vertex = triangleIndices[corner]
                if tooBusy {
                    normals[Int(vertex)] = normal
                } else if let same = placed.first(where: { $0.vertex == vertex && simd_dot($0.normal, normal) > 0.99999 }) {
                    indices[corner] = same.index
                } else if placed.contains(where: { $0.vertex == vertex }) {
                    // The vertex has a normal already, and this corner needs another.
                    placed.append((vertex, normal, UInt32(normals.count)))
                    indices[corner] = UInt32(normals.count)
                    normals.append(normal); repeated.append(vertex)
                } else {
                    placed.append((vertex, normal, vertex))
                    normals[Int(vertex)] = normal
                }
            }
        }
        return (normals, repeated)
    }
}

/// Whether a mesh can be drawn without its back faces.
public enum ClosedSurface {
    /// True when the triangles form closed surfaces with every face turned outward: each
    /// edge belongs to exactly two triangles that run along it in opposite directions, and
    /// every separate piece encloses a positive volume (counter-clockwise faces seen from
    /// outside). From outside such a mesh no back face can be seen, so none need be drawn.
    ///
    /// Vertices must already be merged by position (an index stands for a place; the caller
    /// passes `PositionWelder.canonicalIDs` of each corner). Triangles
    /// that name a vertex twice draw nothing and are ignored. Positions are read from a
    /// vertex buffer, `stride` floats per vertex, position first.
    public static func isClosedAndOutward(indices: UnsafePointer<UInt32>, indexCount: Int, floats: UnsafePointer<Float>, stride: Int, vertexCount: Int) -> Bool {
        let corners = indexCount - indexCount % 3
        guard corners >= 12, vertexCount >= 4, vertexCount < 1 << 31, corners < Int(UInt32.max) else { return false }
        @inline(__always) func degenerate(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> Bool { a == b || b == c || c == a }

        // Edges grouped by their lower vertex (counting sort). An entry is the other vertex
        // times two, plus one when the triangle runs from the higher vertex to the lower.
        var start = [UInt32](repeating: 0, count: vertexCount + 1)
        var used = 0
        var t = 0
        while t < corners {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            t += 3
            if degenerate(a, b, c) { continue }
            start[Int(min(a, b)) + 1] += 1; start[Int(min(b, c)) + 1] += 1; start[Int(min(c, a)) + 1] += 1
            used += 1
        }
        guard used >= 4 else { return false }
        for i in 0..<vertexCount { start[i + 1] += start[i] }
        var paired = true
        do {
            var fill = Array(start.dropLast())
            var entries = [UInt32](repeating: 0, count: used * 3)
            entries.withUnsafeMutableBufferPointer { e in
                @inline(__always) func put(_ u: UInt32, _ v: UInt32) {
                    let low = Int(min(u, v))
                    e[Int(fill[low])] = max(u, v) << 1 | (u > v ? 1 : 0)
                    fill[low] += 1
                }
                var t = 0
                while t < corners {
                    let a = indices[t], b = indices[t + 1], c = indices[t + 2]
                    t += 3
                    if degenerate(a, b, c) { continue }
                    put(a, b); put(b, c); put(c, a)
                }
                // In each group every other vertex must appear exactly twice, once per direction.
                for v in 0..<vertexCount {
                    let lo = Int(start[v]), hi = Int(start[v + 1])
                    if lo == hi { continue }
                    if (hi - lo) % 2 != 0 { paired = false; return }
                    e[lo..<hi].sort()
                    var i = lo
                    while i < hi {
                        if e[i] & 1 != 0 || e[i + 1] != e[i] | 1 { paired = false; return }
                        i += 2
                    }
                }
            }
        }
        guard paired else { return false }

        // Each connected piece must enclose a positive volume.
        var parent = (0..<UInt32(vertexCount)).map { $0 }
        func find(_ x: UInt32) -> UInt32 {
            var r = x
            while parent[Int(r)] != r { parent[Int(r)] = parent[Int(parent[Int(r)])]; r = parent[Int(r)] }
            return r
        }
        t = 0
        while t < corners {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            t += 3
            if degenerate(a, b, c) { continue }
            let ra = find(a), rb = find(b)
            if ra != rb { parent[Int(rb)] = ra }
            let rc = find(c), r = find(a)
            if rc != r { parent[Int(rc)] = r }
        }
        @inline(__always) func position(_ i: UInt32) -> SIMD3<Double> {
            let o = Int(i) * stride
            return SIMD3(Double(floats[o]), Double(floats[o + 1]), Double(floats[o + 2]))
        }
        var volume = [Double](repeating: 0, count: vertexCount)
        let origin = position(indices[0])
        t = 0
        while t < corners {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            t += 3
            if degenerate(a, b, c) { continue }
            volume[Int(find(a))] += simd_dot(position(a) - origin, simd_cross(position(b) - origin, position(c) - origin))
        }
        t = 0
        while t < corners {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            t += 3
            if degenerate(a, b, c) { continue }
            let v = volume[Int(find(a))]
            if !(v > 0) || !v.isFinite { return false }
        }
        return true
    }
}

/// Edges of the wireframe overlay as real line geometry.
public enum WireLines {
    /// How far apart the wire's lines are around each vertex, as a length on the surface:
    /// the area of the triangles that meet at the vertex over the length of the lines that
    /// do (a third of each triangle and half of each line count for each of their ends).
    /// Lines one unit wide and that far apart cover the surface once over.
    ///
    /// `lines` holds pairs of vertices. Vertices with the same entry in `vertexKeys` are one
    /// point and get one answer. Zero for a vertex no line ends at.
    public static func spacing(vertexCount: Int, triangleIndices: [UInt32], lines: [UInt32], vertexKeys: [UInt32]? = nil, position: (Int) -> SIMD3<Float>) -> [Float] {
        var area = [Float](repeating: 0, count: vertexCount), length = [Float](repeating: 0, count: vertexCount)
        @inline(__always) func point(_ vertex: UInt32) -> Int { Int(vertexKeys.map { $0[Int(vertex)] } ?? vertex) }
        for t in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let a = triangleIndices[t], b = triangleIndices[t + 1], c = triangleIndices[t + 2]
            let origin = position(Int(a))
            let third = simd_length(simd_cross(position(Int(b)) - origin, position(Int(c)) - origin)) / 6
            guard third.isFinite else { continue }
            area[point(a)] += third; area[point(b)] += third; area[point(c)] += third
        }
        for l in stride(from: 0, to: lines.count - 1, by: 2) {
            let half = simd_distance(position(Int(lines[l])), position(Int(lines[l + 1]))) / 2
            guard half.isFinite else { continue }
            length[point(lines[l])] += half; length[point(lines[l + 1])] += half
        }
        return (0..<vertexCount).map { vertex in
            let p = point(UInt32(vertex))
            return length[p] > 0 ? area[p] / length[p] : 0
        }
    }

    /// The lines to draw, as pairs of positions in `triangleIndices` (corner `c` stands for
    /// vertex `triangleIndices[c]`). With `faceSizes`, the outline of each source polygon
    /// (a quad's diagonal is not drawn); without it, every triangle edge. An edge shared by
    /// two triangles or polygons comes out once.
    ///
    /// `vertexKeys` says which vertices are the same point (`PositionWelder.canonicalIDs`);
    /// without it, vertices are the same when their indices are equal.
    public static func edges(triangleIndices: [UInt32], faceSizes: [UInt32]?, vertexKeys: [UInt32]? = nil) -> [UInt32] {
        let triangles = triangleIndices.count / 3
        var out: [UInt32] = []
        out.reserveCapacity(triangles * 4)
        var seen = EdgeSet(expected: triangles * 2)
        @inline(__always) func key(_ corner: Int) -> UInt32 {
            let v = triangleIndices[corner]
            return vertexKeys.map { $0[Int(v)] } ?? v
        }
        @inline(__always) func emit(_ a: Int, _ b: Int) {
            let ka = key(a), kb = key(b)
            if ka == kb { return }
            if seen.insert(ka, kb) { out.append(UInt32(a)); out.append(UInt32(b)) }
        }
        @inline(__always) func triangleEdges(_ t: Int) {
            emit(t * 3, t * 3 + 1); emit(t * 3 + 1, t * 3 + 2); emit(t * 3 + 2, t * 3)
        }

        guard let sizes = faceSizes else {
            for t in 0..<triangles { triangleEdges(t) }
            return out
        }
        var t = 0
        for size in sizes {
            let count = Int(size) - 2
            if count < 1 { continue }
            if t + count > triangles { break }
            if count == 1 {
                triangleEdges(t)
            } else if count == 2 {
                // Two triangles; the edge they share is the diagonal and stays out.
                let ea = [(t * 3, t * 3 + 1), (t * 3 + 1, t * 3 + 2), (t * 3 + 2, t * 3)]
                let eb = [((t + 1) * 3, (t + 1) * 3 + 1), ((t + 1) * 3 + 1, (t + 1) * 3 + 2), ((t + 1) * 3 + 2, (t + 1) * 3)]
                func same(_ x: (Int, Int), _ y: (Int, Int)) -> Bool {
                    let (xa, xb, ya, yb) = (key(x.0), key(x.1), key(y.0), key(y.1))
                    return (xa == ya && xb == yb) || (xa == yb && xb == ya)
                }
                for e in ea where !eb.contains(where: { same(e, $0) }) { emit(e.0, e.1) }
                for e in eb where !ea.contains(where: { same(e, $0) }) { emit(e.0, e.1) }
            } else {
                // Any larger polygon: the edges that occur once among its triangles.
                var local: [(lo: UInt32, hi: UInt32, a: Int, b: Int)] = []
                local.reserveCapacity(count * 3)
                for u in t..<(t + count) {
                    for k in 0..<3 {
                        let a = u * 3 + k, b = u * 3 + (k + 1) % 3
                        let ka = key(a), kb = key(b)
                        local.append((min(ka, kb), max(ka, kb), a, b))
                    }
                }
                local.sort { ($0.lo, $0.hi) < ($1.lo, $1.hi) }
                var i = 0
                while i < local.count {
                    var j = i + 1
                    while j < local.count && local[j].lo == local[i].lo && local[j].hi == local[i].hi { j += 1 }
                    if j - i == 1 { emit(local[i].a, local[i].b) }
                    i = j
                }
            }
            t += count
        }
        // Triangles the polygon list does not cover are drawn as they are.
        while t < triangles { triangleEdges(t); t += 1 }
        return out
    }
}

/// Set of unordered vertex-key pairs, open addressing, grows as needed.
struct EdgeSet {
    private var table: [UInt64]
    private var count = 0
    private static let empty = UInt64.max

    init(expected: Int) {
        var capacity = 1024
        while capacity < expected * 2 { capacity <<= 1 }
        table = [UInt64](repeating: Self.empty, count: capacity)
    }

    /// True if the pair was not in the set.
    mutating func insert(_ a: UInt32, _ b: UInt32) -> Bool {
        if (count + 1) * 2 > table.count { grow() }
        let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
        return place(key)
    }

    private mutating func place(_ key: UInt64) -> Bool {
        let mask = table.count - 1
        var slot = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
        while true {
            let found = table[slot]
            if found == Self.empty { table[slot] = key; count += 1; return true }
            if found == key { return false }
            slot = (slot + 1) & mask
        }
    }

    private mutating func grow() {
        let old = table
        table = [UInt64](repeating: Self.empty, count: old.count * 2)
        count = 0
        for key in old where key != Self.empty { _ = place(key) }
    }
}
