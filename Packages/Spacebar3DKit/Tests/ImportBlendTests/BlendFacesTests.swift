@testable import ImportBlend
import simd
import XCTest

/// What a Mirror modifier adds to a mesh's faces.
final class BlendFacesTests: XCTestCase {
    /// One face of four corners; its edges are numbered 0 to 3 from its first corner.
    private func face(_ points: [SIMD3<Float>]) -> BlendFaces {
        var faces = BlendFaces(points: points, edgeCount: 4, numbersEdges: true)
        faces.add(face: 0, corners: 0..<4, vertexOf: { $0 }, edgeOf: { Int32($0) })
        return faces
    }

    private let square: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]

    private func direction(of face: Int, in faces: BlendFaces) -> SIMD3<Float> {
        let ring = (faces.starts[face]..<faces.starts[face + 1]).map { faces.points[Int(faces.vertexOf[$0])] }
        var n = SIMD3<Float>.zero
        for (k, a) in ring.enumerated() {
            let b = ring[(k + 1) % ring.count]
            n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        return simd_normalize(n)
    }

    /// The other side is the same face seen in a mirror, its corners in the opposite order
    /// so that it faces the same way out. Vertices on the mirror are the two sides' own.
    func testAMirrorAddsEachFaceOnTheOtherSideFacingTheSameWay() {
        var faces = face(square)
        faces.mirror(axis: 0, tolerance: 0.001, merges: true)
        XCTAssertEqual(faces.points.count, 6)
        XCTAssertEqual(Array(faces.points[4...]), [SIMD3(-1, 0, 0), SIMD3(-1, 1, 0)])
        XCTAssertEqual(faces.starts, [0, 4, 8])
        XCTAssertEqual(Array(faces.vertexOf[4...]), [3, 5, 4, 0])
        XCTAssertEqual((0..<4).map { faces.corner(1, $0) }, [3, 2, 1, 0], "each corner knows the corner it copies, for its coordinates in the image")
        XCTAssertEqual((0..<4).map { faces.corner(0, $0) }, [0, 1, 2, 3])
        XCTAssertEqual(faces.faceOf, [0, 0])
        XCTAssertEqual(simd_distance(direction(of: 1, in: faces), direction(of: 0, in: faces)), 0, accuracy: 1e-6)
    }

    /// The edge that lies in the mirror is one edge with a face on either side. Every other
    /// edge has a copy of its own.
    func testTheEdgeOnTheMirrorIsSharedAndTheOthersAreCopied() {
        var faces = face(square)
        faces.mirror(axis: 0, tolerance: 0.001, merges: true)
        XCTAssertEqual(faces.edgeOf.map { Array($0[4...]) }, [6, 5, 4, 3])
        XCTAssertEqual(faces.edgeCount, 8)
    }

    /// Not merging, the two sides only touch: every vertex and edge is copied.
    func testWithoutMergingNothingIsShared() {
        var faces = face(square)
        faces.mirror(axis: 0, tolerance: 0.001, merges: false)
        XCTAssertEqual(faces.points.count, 8)
        XCTAssertEqual(faces.edgeOf.map { Array($0[4...]) }, [6, 5, 4, 7])
    }

    /// Mirrored across two axes, a quarter makes the whole.
    func testAcrossTwoAxesThereAreFourOfEachFace() {
        var faces = face(square)
        faces.mirror(axis: 0, tolerance: 0.001, merges: true)
        faces.mirror(axis: 1, tolerance: 0.001, merges: true)
        XCTAssertEqual(faces.faceOf.count, 4)
        XCTAssertEqual(faces.points.count, 9, "nine places: the corners of four squares that meet in the middle")
        let low = faces.points.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }, high = faces.points.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        XCTAssertEqual(low, SIMD3(-1, -1, 0)); XCTAssertEqual(high, SIMD3(1, 1, 0))
        for f in 0..<4 { XCTAssertEqual(simd_distance(direction(of: f, in: faces), SIMD3(0, 0, 1)), 0, accuracy: 1e-6) }
    }

    /// A smooth surface stays smooth across a mirror it is merged on: one slope of a roof,
    /// mirrored, has one direction along its ridge, straight up.
    func testASmoothSurfaceIsSmoothAcrossTheMirror() {
        var faces = face([SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 1)])
        faces.mirror(axis: 0, tolerance: 0.001, merges: true)
        let own = (0..<2).map { direction(of: $0, in: faces) }
        let normals = BlendNormals.corners(points: faces.points, starts: faces.starts, vertexOf: faces.vertexOf, usable: [true, true], faceNormals: own,
                                           smooth: { _ in true }, edgeOf: faces.edgeOf, edgeCount: faces.edgeCount, sharp: { _ in false }, splits: true)
        XCTAssertEqual(simd_distance(normals[0], SIMD3(0, 0, 1)), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(normals[1], own[0]), 0, accuracy: 1e-5, "away from the ridge each slope has its own")
        // A mirror plane that is not the object's own: one unit along x.
        var moved = face(square)
        var plane = matrix_identity_float4x4
        plane.columns.3 = SIMD4(-1, 0, 0, 1)
        moved.mirror(axis: 0, tolerance: 0.001, merges: true, about: plane)
        XCTAssertEqual(Array(moved.points[4...]), [SIMD3(2, 0, 0), SIMD3(2, 1, 0)], "the side at x = 1 is on the mirror now, and the other is copied past it")
    }
}
