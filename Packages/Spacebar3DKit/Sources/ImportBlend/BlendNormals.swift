import simd

/// The direction a mesh is lit from at each corner of each face, as Blender works it out.
///
/// A flat face has its own direction at every corner. Smooth faces that meet at a vertex
/// share one where they are joined: each adds its own direction, weighted by the angle it
/// fills at the vertex. Two faces are joined across an edge when they are the only two on
/// it, both are smooth, they are wound the same way round, and the edge is not marked sharp.
///
/// Corners joined so at a vertex are a fan. A custom normal is kept for a fan, packed into
/// two numbers that say how far it leans from the fan's own direction and which way.
enum BlendNormals {
    /// Faces that meet at more than an angle are parted, as the Smooth by Angle modifier
    /// parts them (what "Shade Auto Smooth" adds to an object since Blender 4.1).
    struct ByAngle {
        /// Radians between the two faces' own directions.
        var limit: Float
        /// The modifier's "Ignore Sharpness": edges marked sharp and faces set flat are joined all the same.
        var ignoresMarks = false
    }

    /// What a fan's custom normal is measured in: the fan's own direction, its first edge
    /// swung square to that, a third direction square to both, and the room there is to
    /// lean from the first and to turn about it.
    private struct Frame {
        var own: SIMD3<Float>, ahead: SIMD3<Float>, aside: SIMD3<Float>
        /// The mean angle from the fan's own direction to its edges.
        var room: Float
        /// The angle from the fan's first edge round to its last, about its own direction.
        var round: Float

        private static let aligned: Float = 1 - 1e-4, turn = 2 * Float.pi
        private static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(min(1, max(-1, simd_dot(a, b)))) }

        /// Nil for a fan with an end edge along its own direction: nothing to measure from.
        init?(own: SIMD3<Float>, first: SIMD3<Float>, last: SIMD3<Float>, room: Float) {
            let alongFirst = simd_dot(first, own), alongLast = simd_dot(last, own)
            guard abs(alongFirst) < Frame.aligned, abs(alongLast) < Frame.aligned else { return nil }
            self.own = own; self.room = room
            ahead = simd_normalize(first - own * alongFirst)
            aside = simd_normalize(simd_cross(own, ahead))
            let other = simd_normalize(last - own * alongLast)
            round = Frame.turn
            if simd_dot(ahead, other) < Frame.aligned {
                round = Frame.angle(ahead, other)
                if simd_dot(aside, other) < 0 { round = Frame.turn - round }
            }
            guard room > 0, round > 0, room.isFinite, round.isFinite else { return nil }
        }

        /// The direction two stored numbers stand for; nil where they say there is none.
        func unpacked(_ stored: SIMD2<Int>) -> SIMD3<Float>? {
            guard stored.x != 0 else { return nil }
            let lean = Float(stored.x) / 32767, leant = (lean > 0 ? room : Frame.turn - room) * lean
            let turned = Float(stored.y) / 32767
            var direction = own * cos(leant)
            if turned == 0 {
                direction += ahead * sin(leant)
            } else {
                let about = (turned > 0 ? round : Frame.turn - round) * turned
                direction += (ahead * cos(about) + aside * sin(about)) * sin(leant)
            }
            let length = simd_length(direction)
            return length > 0 && length.isFinite ? direction / length : nil
        }

        /// The two numbers that stand for a direction, as Blender packs them.
        func packed(_ direction: SIMD3<Float>) -> SIMD2<Int16> {
            // The fan's own direction is kept as no custom normal.
            let apart = simd_abs(direction - own)
            guard max(apart.x, apart.y, apart.z) > 1e-4 else { return .zero }
            func share(_ part: Float) -> Int16 { part.isFinite ? Int16(max(-32767, min(32767, (part * 32767 + 0.5).rounded(.down)))) : 0 }
            let leant = Frame.angle(own, direction)
            let lean = leant > room ? -(Frame.turn - leant) / (Frame.turn - room) : leant / room
            let level = simd_normalize(direction - own * simd_dot(own, direction))
            var turned: Float = 0
            if simd_dot(ahead, level) < Frame.aligned {
                var about = Frame.angle(ahead, level)
                if simd_dot(aside, level) < 0 { about = Frame.turn - about }
                turned = about > round ? -(Frame.turn - about) / (Frame.turn - round) : about / round
            }
            return SIMD2(share(lean), share(turned))
        }
    }

    /// A mirror about to copy the mesh, which packs each corner's custom normal again for
    /// the corner's copy.
    struct Copying {
        /// What the mirror does to a direction that stands on a surface.
        var turn: simd_float3x3
        /// Is given each corner, and the two numbers for its copy.
        var keep: (Int, SIMD2<Int16>) -> Void
    }

    /// - Parameters:
    ///   - starts: where each face's corners begin among all corners, and one more for the end.
    ///   - vertexOf: the vertex each corner is at.
    ///   - usable: faces with corners to read; the others keep `faceNormals`.
    ///   - smooth: whether a face is shaded smooth.
    ///   - edgeOf: for each corner, the edge from it to its face's next corner, as the
    ///     file numbers its edges. Without it, smooth faces at a vertex are all joined.
    ///   - sharp: whether an edge is marked sharp.
    ///   - splits: false for a file from before Blender 4.1 with auto smooth off. Blender
    ///     then gave a smooth face the one direction of its vertex, shared with every face
    ///     there, flat ones and across sharp edges too.
    ///   - byAngle: the object's Smooth by Angle modifier, when it has one. It needs the
    ///     file's numbering of the edges.
    ///   - custom: the custom normal stored for a corner, as Blender packs it into two
    ///     numbers; two zeros where there is none. It needs the numbering of the edges too.
    ///   - copying: a mirror that is to copy the mesh, to be given what each copy keeps.
    static func corners(points: [SIMD3<Float>], starts: [Int], vertexOf corners: [Int32], usable: [Bool], faceNormals: [SIMD3<Float>],
                        smooth: (Int) -> Bool, edgeOf: [Int32]?, edgeCount: Int, sharp: (Int) -> Bool, splits: Bool, byAngle: ByAngle? = nil,
                        custom: ((Int) -> SIMD2<Int16>)? = nil, copying: Copying? = nil) -> [SIMD3<Float>] {
        let cornerCount = corners.count, faceCount = usable.count
        @inline(__always) func vertexOf(_ c: Int) -> Int { Int(corners[c]) }
        var normals = [SIMD3<Float>](repeating: .zero, count: cornerCount)
        var faceOf = [Int32](repeating: -1, count: cornerCount)
        // The modifier shades every face smooth; what was flat before is kept as a mark.
        var isSmooth = [Bool](repeating: false, count: faceCount), wasFlat = isSmooth
        for f in 0..<faceCount where usable[f] {
            wasFlat[f] = !smooth(f)
            isSmooth[f] = splits && byAngle != nil ? true : !wasFlat[f]
            for c in starts[f]..<starts[f + 1] { faceOf[c] = Int32(f) }
        }
        @inline(__always) func next(_ c: Int) -> Int { let f = Int(faceOf[c]); return c + 1 < starts[f + 1] ? c + 1 : starts[f] }
        @inline(__always) func previous(_ c: Int) -> Int { let f = Int(faceOf[c]); return c > starts[f] ? c - 1 : starts[f + 1] - 1 }
        /// What a face adds at one of its corners: its direction, by the angle it fills there.
        @inline(__always) func share(_ c: Int) -> SIMD3<Float> {
            let p = points[vertexOf(c)], u = points[vertexOf(next(c))] - p, v = points[vertexOf(previous(c))] - p
            let d = simd_length(u) * simd_length(v)
            return d > 0 && d.isFinite ? faceNormals[Int(faceOf[c])] * acos(min(1, max(-1, simd_dot(u, v) / d))) : .zero
        }

        if !splits {
            var sums = [SIMD3<Float>](repeating: .zero, count: points.count)
            for c in 0..<cornerCount where faceOf[c] >= 0 { sums[vertexOf(c)] += share(c) }
            for c in 0..<cornerCount where faceOf[c] >= 0 {
                let f = Int(faceOf[c]), sum = sums[vertexOf(c)], length = simd_length(sum)
                normals[c] = isSmooth[f] && length > 0 && length.isFinite ? sum / length : faceNormals[f]
            }
            return normals
        }

        // Corners joined into one group share a direction.
        var group = (0..<Int32(cornerCount)).map { $0 }
        func root(_ c: Int) -> Int {
            var r = c
            while Int(group[r]) != r { r = Int(group[r]) }
            var at = c
            while Int(group[at]) != r { let up = Int(group[at]); group[at] = Int32(r); at = up }
            return r
        }
        func join(_ a: Int, _ b: Int) { let ra = root(a), rb = root(b); if ra != rb { group[max(ra, rb)] = Int32(min(ra, rb)) } }

        // The first two corners that start along each edge, and whether it joins them.
        var first: [Int32] = [], second: [Int32] = [], joins: [Bool] = []
        if let edgeOf, edgeCount > 0, edgeOf.count == cornerCount {
            first = [Int32](repeating: -1, count: edgeCount); second = first
            joins = [Bool](repeating: true, count: edgeCount)
            for c in 0..<cornerCount where faceOf[c] >= 0 {
                let e = Int(edgeOf[c])
                guard e >= 0, e < edgeCount else { continue }
                if !isSmooth[Int(faceOf[c])] || (wasFlat[Int(faceOf[c])] && byAngle?.ignoresMarks != true) { joins[e] = false }
                if first[e] < 0 { first[e] = Int32(c) } else if second[e] < 0 { second[e] = Int32(c) } else { joins[e] = false }
            }
            for e in 0..<edgeCount where joins[e] {
                joins[e] = false
                guard second[e] >= 0, byAngle?.ignoresMarks == true || !sharp(e) else { continue }
                let a = Int(first[e]), b = Int(second[e])
                // Wound the same way round, the two faces run along the edge in opposite directions.
                guard vertexOf(next(a)) == vertexOf(b), vertexOf(next(b)) == vertexOf(a) else { continue }
                if let limit = byAngle?.limit {
                    // The angle as Blender takes it, from the distance between the two
                    // directions: where faces meet at the limit itself (a twelve-sided
                    // pipe at thirty degrees), rounding decides, there as here.
                    let n = faceNormals[Int(faceOf[a])], m = faceNormals[Int(faceOf[b])]
                    let angle = simd_dot(n, m) >= 0 ? 2 * asin(min(1, simd_length(n - m) / 2)) : .pi - 2 * asin(min(1, simd_length(n + m) / 2))
                    if angle > limit { continue }
                }
                join(a, next(b)); join(next(a), b)
                joins[e] = true
            }
        } else {
            var seen = [Int32](repeating: -1, count: points.count)
            for c in 0..<cornerCount where faceOf[c] >= 0 && isSmooth[Int(faceOf[c])] {
                let v = vertexOf(c)
                if seen[v] < 0 { seen[v] = Int32(c) } else { join(Int(seen[v]), c) }
            }
        }

        // Each group's sum is gathered at its first corner, then given to the others.
        for c in 0..<cornerCount where faceOf[c] >= 0 && isSmooth[Int(faceOf[c])] { normals[root(c)] += share(c) }
        for c in 0..<cornerCount where faceOf[c] >= 0 {
            let f = Int(faceOf[c])
            guard isSmooth[f] else { normals[c] = faceNormals[f]; continue }
            let r = root(c)
            if r == c {
                let length = simd_length(normals[c])
                normals[c] = length > 0 && length.isFinite ? normals[c] / length : faceNormals[f]
            } else {
                // A group's first corner comes first, and is of unit length by now.
                normals[c] = normals[r]
            }
        }
        guard let custom, let edgeOf, !joins.isEmpty else { return normals }

        // A custom normal is stored for a fan: the corners at a vertex that are joined one
        // to the next. It is two angles, each as a share of what there is room for: how far
        // the normal leans from the fan's own direction, and how far round from the fan's
        // first edge it leans. A fan between two edges that part starts at the corner whose
        // own edge parts; one all the way round a vertex, at its first corner in the file.
        @inline(__always) func joinsAfter(_ c: Int) -> Bool { let e = Int(edgeOf[c]); return e >= 0 && e < edgeCount && joins[e] }
        /// The other corner that starts along a corner's edge: in the face on its far side.
        @inline(__always) func across(_ c: Int) -> Int { let e = Int(edgeOf[c]); return Int(first[e]) == c ? Int(second[e]) : Int(first[e]) }
        @inline(__always) func towards(_ c: Int, from p: SIMD3<Float>) -> SIMD3<Float> {
            let d = points[vertexOf(c)] - p, length = simd_length(d)
            return length > 0 && length.isFinite ? d / length : .zero
        }
        @inline(__always) func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(min(1, max(-1, simd_dot(a, b)))) }
        var done = [Bool](repeating: false, count: cornerCount)
        var fan: [Int] = []
        for c in 0..<cornerCount where faceOf[c] >= 0 && !done[c] {
            var start = c
            while joinsAfter(start) {
                start = next(across(start))
                if start == c { break }
            }
            let own = normals[c], place = points[vertexOf(start)]
            let reference = towards(next(start), from: place)
            var last = reference, leans = angle(reference, own), edges = 1
            var sum = SIMD2<Int>.zero, alike = true, allRound = false
            let one = custom(start)
            fan.removeAll(keepingCapacity: true)
            var at = start
            while true {
                let before = previous(at)
                last = towards(before, from: place)
                fan.append(at); done[at] = true
                let value = custom(at)
                sum &+= SIMD2(Int(value.x), Int(value.y)); alike = alike && value == one
                allRound = edgeOf[before] == edgeOf[start]
                if !allRound { leans += angle(last, own); edges += 1 }
                if allRound || !joinsAfter(before) { break }
                at = across(before)
                if done[at] { break }
            }
            // Corners of a fan that differ are given what Blender gives them: their average, in whole numbers.
            let stored = alike ? SIMD2(Int(one.x), Int(one.y)) : SIMD2(sum.x / fan.count, sum.y / fan.count)
            let room = fan.count == 1 ? (angle(reference, own) + angle(last, own)) / 2 : leans / Float(edges)
            var direction = own
            if let unpacked = Frame(own: own, first: reference, last: last, room: room)?.unpacked(stored) {
                direction = unpacked
                for member in fan { normals[member] = direction }
            }
            guard let copying else { continue }
            // The copy's fan runs the other way round: it starts along the copy of this
            // one's last edge, or all the way round a vertex, of the edge that leads to
            // this one's first corner.
            let edge = copying.turn.transpose
            let copiedFirst = simd_normalize(edge * (allRound ? towards(previous(start), from: place) : last))
            let copy = Frame(own: simd_normalize(copying.turn * own), first: copiedFirst, last: allRound ? copiedFirst : simd_normalize(edge * reference), room: room)
            let kept = copy?.packed(simd_normalize(copying.turn * direction)) ?? .zero
            for member in fan { copying.keep(member, kept) }
        }
        return normals
    }
}
