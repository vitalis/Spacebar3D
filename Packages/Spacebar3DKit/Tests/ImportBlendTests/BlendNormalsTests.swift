@testable import ImportBlend
import simd
import XCTest

/// The direction at each corner of a Blender mesh. What is expected here is what Blender
/// 5.2 gives for the same shapes (`Mesh.corner_normals`).
final class BlendNormalsTests: XCTestCase {
    /// A mesh from its faces, with its edges numbered as they are first met.
    private struct Shape {
        var points: [SIMD3<Float>]
        var starts = [0], vertexOf: [Int] = [], edgeOf: [Int32] = [], faceNormals: [SIMD3<Float>] = []
        private var edges: [SIMD2<Int>: Int32] = [:]

        init(points: [SIMD3<Float>], faces: [[Int]]) {
            self.points = points
            for face in faces {
                var n = SIMD3<Float>.zero
                for (k, v) in face.enumerated() {
                    let w = face[(k + 1) % face.count], a = points[v], b = points[w]
                    n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
                    let key = SIMD2(min(v, w), max(v, w))
                    if edges[key] == nil { edges[key] = Int32(edges.count) }
                    vertexOf.append(v); edgeOf.append(edges[key]!)
                }
                faceNormals.append(simd_normalize(n)); starts.append(vertexOf.count)
            }
        }

        func edge(_ v: Int, _ w: Int) -> Int { Int(edges[SIMD2(min(v, w), max(v, w))]!) }

        func normals(smooth: (Int) -> Bool = { _ in true }, sharp: Set<Int> = [], splits: Bool = true, withEdges: Bool = true, byAngle: BlendNormals.ByAngle? = nil,
                     custom: [SIMD2<Int16>]? = nil, copying: BlendNormals.Copying? = nil) -> [SIMD3<Float>] {
            BlendNormals.corners(points: points, starts: starts, vertexOf: vertexOf.map(Int32.init), usable: [Bool](repeating: true, count: faceNormals.count), faceNormals: faceNormals,
                                 smooth: smooth, edgeOf: withEdges ? edgeOf : nil, edgeCount: edges.count, sharp: { sharp.contains($0) }, splits: splits, byAngle: byAngle,
                                 custom: custom.map { values in { values[$0] } }, copying: copying)
        }
    }

    /// A can of twelve sides: the bottom ring is vertices 0 to 11, the top ring 12 to 23.
    /// Faces 0 to 11 are its sides, 12 its top and 13 its bottom, all wound to face out.
    private var can: Shape {
        let ring = (0..<12).map { i -> SIMD2<Float> in let a = 2 * Float.pi * Float(i) / 12; return SIMD2(cos(a), sin(a)) }
        let points = ring.map { SIMD3($0.x, $0.y, -1) } + ring.map { SIMD3($0.x, $0.y, 1) }
        let sides = (0..<12).map { [$0, ($0 + 1) % 12, ($0 + 1) % 12 + 12, $0 + 12] }
        return Shape(points: points, faces: sides + [Array(12..<24), Array((0..<12).reversed())])
    }

    /// A cube from -1 to 1. Faces: bottom, top, front (-y), back, right (+x), left.
    private var cube: Shape {
        let points: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
        return Shape(points: points, faces: [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]])
    }

    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(simd_distance(a, b), 0, accuracy: 1e-4, "\(a) is not \(b) \(message)", file: file, line: line)
    }

    /// A smooth side beside a flat end does not lean towards the end: it is lit as a
    /// round wall right up to its rim.
    func testASmoothSideDoesNotLeanTowardsAFlatEnd() {
        let can = can
        let normals = can.normals(smooth: { $0 < 12 })
        for c in 0..<48 {
            let p = can.points[can.vertexOf[c]]
            assertEqual(normals[c], SIMD3(p.x, p.y, 0), "corner \(c)")
        }
        for c in 48..<60 { assertEqual(normals[c], SIMD3(0, 0, 1)) }
        for c in 60..<72 { assertEqual(normals[c], SIMD3(0, 0, -1)) }
    }

    /// Faces that are all smooth share by the angle each fills at the vertex, not by their
    /// area: at the rim of a can, the end's 150 degrees and each of two sides' 90.
    func testFacesShareByTheAngleTheyFillAtAVertex() {
        let can = can
        let normals = can.normals()
        // Corner 3 is at vertex 12, the top of the first side; sides 0 and 11 meet there.
        XCTAssertEqual(can.vertexOf[3], 12)
        let expected = simd_normalize(SIMD3<Float>(0, 0, 1) * (150 * .pi / 180) + (can.faceNormals[0] + can.faceNormals[11]) * (.pi / 2))
        assertEqual(normals[3], expected)
        assertEqual(normals[48], expected, "the end's own corner there")
    }

    /// An edge marked sharp parts the faces on its two sides. A cube whose top is ringed
    /// with sharp edges has a flat top and sides that are still rounded into each other.
    func testAnEdgeMarkedSharpPartsTheFacesBesideIt() {
        let cube = cube
        let ring: Set<Int> = [cube.edge(4, 5), cube.edge(5, 6), cube.edge(6, 7), cube.edge(7, 4)]
        let normals = cube.normals(sharp: ring)
        for c in 4..<8 { assertEqual(normals[c], SIMD3(0, 0, 1), "top corner \(c)") }
        // The front face's corners: vertices 0, 1, 5, 4.
        assertEqual(normals[10], simd_normalize(SIMD3(1, -1, 0)), "at the top, the front and the right side")
        assertEqual(normals[9], simd_normalize(SIMD3(1, -1, -1)), "at the bottom, the bottom as well")
        // With no edge marked, all three faces of a corner share.
        assertEqual(cube.normals()[10], simd_normalize(SIMD3(1, -1, 1)))
    }

    /// Before Blender 4.1, with auto smooth off, a smooth face had its vertex's one
    /// direction, shared with flat faces too and across sharp edges.
    func testAnOlderFileSharesAcrossFlatFacesAndSharpEdges() {
        let cube = cube
        let ring: Set<Int> = [cube.edge(4, 5), cube.edge(5, 6), cube.edge(6, 7), cube.edge(7, 4)]
        let normals = cube.normals(smooth: { $0 != 1 }, sharp: ring, splits: false)
        for c in 4..<8 { assertEqual(normals[c], SIMD3(0, 0, 1), "the flat top keeps its own") }
        assertEqual(normals[10], simd_normalize(SIMD3(1, -1, 1)), "the sides lean towards it")
    }

    /// Two faces wound against each other are not joined: which way is out is not agreed.
    func testFacesWoundAgainstEachOtherDoNotShare() {
        let points: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 1)]
        let agreed = Shape(points: points, faces: [[0, 1, 2], [2, 1, 3]]), against = Shape(points: points, faces: [[0, 1, 2], [1, 2, 3]])
        XCTAssertGreaterThan(simd_distance(agreed.normals()[1], agreed.faceNormals[0]), 0.1, "joined")
        assertEqual(against.normals()[1], against.faceNormals[0])
        assertEqual(against.normals()[3], against.faceNormals[1])
    }

    /// Smooth by Angle at 40 degrees on a can that is smooth all over: the sides, thirty
    /// degrees apart, stay joined, and the ends, at a right angle to them, are parted.
    func testFacesAtMoreThanTheModifiersAngleAreParted() {
        let can = can
        let normals = can.normals(byAngle: .init(limit: 40 * .pi / 180))
        for c in 0..<48 {
            let p = can.points[can.vertexOf[c]]
            assertEqual(normals[c], SIMD3(p.x, p.y, 0), "corner \(c)")
        }
        for c in 48..<60 { assertEqual(normals[c], SIMD3(0, 0, 1)) }
        // Below the angle between the sides, they are parted too.
        assertEqual(can.normals(byAngle: .init(limit: 20 * .pi / 180))[0], can.faceNormals[0])
    }

    /// The modifier shades every face smooth and keeps the marks as edges that part: a face
    /// that was flat stands apart from its neighbours, and so do the two sides of an edge
    /// marked sharp. Told to ignore them, it goes by the angle alone.
    func testTheModifierKeepsMarksUnlessToldToIgnoreThem() {
        let can = can
        // Side 3 is flat, and the edge between sides 6 and 7 (up from vertex 7) is sharp.
        let flat: (Int) -> Bool = { $0 != 3 }, marked: Set<Int> = [can.edge(7, 19)]
        let kept = can.normals(smooth: flat, sharp: marked, byAngle: .init(limit: 40 * .pi / 180))
        // Side 3's corners are 12 to 15; side 2's second corner (9) is at vertex 3, which they share.
        assertEqual(kept[12], can.faceNormals[3])
        XCTAssertEqual(can.vertexOf[9], 3)
        assertEqual(kept[9], can.faceNormals[2], "side 2 stops at the face that was flat")
        // Side 6's second corner (25) is at vertex 7, on the marked edge.
        XCTAssertEqual(can.vertexOf[25], 7)
        assertEqual(kept[25], can.faceNormals[6], "sides 6 and 7 are parted by the mark")
        let ignored = can.normals(smooth: flat, sharp: marked, byAngle: .init(limit: 40 * .pi / 180, ignoresMarks: true))
        for c in [12, 9, 25] {
            let p = can.points[can.vertexOf[c]]
            assertEqual(ignored[c], SIMD3(p.x, p.y, 0), "corner \(c)")
        }
    }

    /// Custom normals are stored as two numbers a corner: how far the normal leans from the
    /// one its fan of faces would have, and which way round. Read back, they are the
    /// directions Blender shows, for a corner alone, a fan between two flat faces, and a
    /// fan all the way round a vertex.
    func testCustomNormalsAreTheDirectionsBlenderShows() {
        for one in BlenderCase.all {
            let shape = Shape(points: one.points, faces: one.faces)
            let sharp = Set(one.sharp.map { shape.edge($0.x, $0.y) })
            let normals = shape.normals(smooth: { one.smooth[$0] }, sharp: sharp, custom: one.custom)
            var worst: Float = 0
            for c in normals.indices { worst = max(worst, acos(min(1, simd_dot(simd_normalize(normals[c]), simd_normalize(one.expected[c])))) * 180 / .pi) }
            XCTAssertLessThan(worst, 0.2, "\(one.name): degrees from Blender's own")
            // Without them, the same mesh is lit differently: the numbers are what is read.
            let plain = shape.normals(smooth: { one.smooth[$0] }, sharp: sharp)
            XCTAssertGreaterThan(simd_distance(plain[0], one.expected[0]), 0.05, one.name)
        }
    }

    /// A Mirror modifier packs each custom normal again for the copy it makes, measured in
    /// the copy's own fan, which runs the other way round. Read back in the copy, what it
    /// keeps is the original's direction turned over.
    func testWhatAMirrorKeepsForACopyReadsBackAsTheNormalTurnedOver() {
        var across = matrix_identity_float3x3
        across[0][0] = -1
        for one in BlenderCase.all {
            let shape = Shape(points: one.points, faces: one.faces)
            var kept = [SIMD2<Int16>](repeating: .zero, count: one.custom.count)
            let normals = shape.normals(smooth: { one.smooth[$0] }, custom: one.custom, copying: .init(turn: across, keep: { kept[$0] = $1 }))
            // The copy: every point across X, every face with its corners in the opposite order.
            let copy = Shape(points: one.points.map { across * $0 }, faces: one.faces.map { $0.reversed() })
            let original = one.faces.indices.flatMap { f in (shape.starts[f]..<shape.starts[f + 1]).reversed() }
            let read = copy.normals(smooth: { one.smooth[$0] }, custom: original.map { kept[$0] })
            var worst: Float = 0
            for (c, from) in original.enumerated() { worst = max(worst, acos(min(1, simd_dot(read[c], across * normals[from]))) * 180 / .pi) }
            XCTAssertLessThan(worst, 0.2, "\(one.name): degrees from the original's, turned over")
        }
    }

    /// Two zeros are no custom normal: the corner keeps the direction of its fan.
    func testACornerWithNoCustomNormalKeepsItsFansDirection() {
        let can = can
        let none = [SIMD2<Int16>](repeating: SIMD2(0, 0), count: can.vertexOf.count)
        XCTAssertEqual(can.normals(smooth: { $0 < 12 }, custom: none), can.normals(smooth: { $0 < 12 }))
    }

    /// A file that does not say which edge each corner runs along: smooth faces at a
    /// vertex all share, and flat ones stay out of it.
    func testWithoutEdgesSmoothFacesAtAVertexShare() {
        let can = can
        let normals = can.normals(smooth: { $0 < 12 }, withEdges: false)
        let p = can.points[12]
        assertEqual(normals[3], SIMD3(p.x, p.y, 0))
        assertEqual(normals[48], SIMD3(0, 0, 1))
    }
}
