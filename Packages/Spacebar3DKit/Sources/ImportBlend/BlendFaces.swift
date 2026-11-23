import simd

/// A mesh's faces as rings of corners, while an object's modifiers add to them.
struct BlendFaces {
    var points: [SIMD3<Float>]
    /// Where each face's corners begin among all corners, and one more for the end.
    var starts = [0]
    /// The vertex each corner is at.
    var vertexOf: [Int32] = []
    /// The edge each corner runs along to its face's next corner. Nil when the file does
    /// not number its edges.
    var edgeOf: [Int32]?
    var edgeCount = 0
    /// The file's face each face is, or is a copy of.
    var faceOf: [Int32] = []
    /// The file's corner each face begins at, and whether the face runs through the file's
    /// corners backwards (a copy in a mirror does).
    private var firstCorner: [Int32] = []
    private var backwards: [Bool] = []

    init(points: [SIMD3<Float>], edgeCount: Int = 0, numbersEdges: Bool = false) {
        self.points = points; self.edgeCount = edgeCount; edgeOf = numbersEdges ? [] : nil
    }

    /// Adds one of the file's faces: its corners, the vertex each is at, and its edges.
    mutating func add(face: Int, corners: Range<Int>, vertexOf vertex: (Int) -> Int, edgeOf edge: (Int) -> Int32) {
        for c in corners {
            vertexOf.append(Int32(vertex(c)))
            if edgeOf != nil { edgeOf!.append(edge(c)) }
        }
        faceOf.append(Int32(face)); firstCorner.append(Int32(corners.lowerBound)); backwards.append(false)
        starts.append(vertexOf.count)
    }

    /// The file's corner that corner `k` of a face is, or is a copy of: where its
    /// coordinates in an image are.
    func corner(_ face: Int, _ k: Int) -> Int {
        Int(firstCorner[face]) + (backwards[face] ? starts[face + 1] - starts[face] - 1 - k : k)
    }

    /// What a mirror across an axis does to a direction that stands on a surface: such a
    /// direction goes by the transpose of the mirror's inverse, and a mirror is its own inverse.
    static func turn(axis: Int, about plane: simd_float4x4? = nil) -> simd_float3x3 {
        var flip = matrix_identity_float3x3
        flip[axis][axis] = -1
        guard let plane else { return flip }
        func turning(_ m: simd_float4x4) -> simd_float3x3 { simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)) }
        return (turning(simd_inverse(plane)) * flip * turning(plane)).transpose
    }

    /// A value for each corner there is, followed by one for each corner `mirror` would
    /// add, in the order it adds them: `copies` holds, at each corner, the value for its copy.
    func withCopies<Value>(_ values: [Value], _ copies: [Value]) -> [Value] {
        var out = values
        out.reserveCapacity(values.count * 2)
        for f in 0..<faceOf.count { for c in (starts[f]..<starts[f + 1]).reversed() { out.append(copies[c]) } }
        return out
    }

    /// What a Mirror modifier does across one axis: every face again on the other side of
    /// the plane through the origin, its corners in the opposite order so that it faces the
    /// same way out. With `merges`, a vertex within `tolerance` of the plane is one vertex
    /// of both sides, and an edge that lies in the plane one edge with a face on either
    /// side: a smooth surface is smooth across the mirror.
    ///
    /// `plane` takes a point to the space the mirror is in, when that is another object's.
    mutating func mirror(axis: Int, tolerance: Float, merges: Bool, about plane: simd_float4x4? = nil) {
        let back = plane.map { simd_inverse($0) }
        // The vertex on the other side of each vertex; itself where it is on the mirror.
        var twin = [Int32](repeating: 0, count: points.count)
        for v in 0..<twin.count {
            var p = points[v]
            if let plane { let q = plane * SIMD4(p, 1); p = SIMD3(q.x, q.y, q.z) }
            if merges, abs(p[axis]) <= tolerance { twin[v] = Int32(v); continue }
            p[axis] = -p[axis]
            if let back { let q = back * SIMD4(p, 1); p = SIMD3(q.x, q.y, q.z) }
            twin[v] = Int32(points.count)
            points.append(p)
        }
        let faces = faceOf.count
        for f in 0..<faces {
            let start = starts[f], end = starts[f + 1]
            for c in (start..<end).reversed() {
                vertexOf.append(twin[Int(vertexOf[c])])
                guard edgeOf != nil else { continue }
                // From this corner the copy runs back along the edge that led to it.
                let before = c > start ? c - 1 : end - 1
                let a = vertexOf[before], b = vertexOf[c]
                edgeOf!.append(twin[Int(a)] == a && twin[Int(b)] == b ? edgeOf![before] : edgeOf![before] &+ Int32(truncatingIfNeeded: edgeCount))
            }
            faceOf.append(faceOf[f]); firstCorner.append(firstCorner[f]); backwards.append(!backwards[f])
            starts.append(vertexOf.count)
        }
        edgeCount *= 2
    }
}
