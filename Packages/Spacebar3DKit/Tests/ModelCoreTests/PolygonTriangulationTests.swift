import ModelCore
import simd
import XCTest

final class PolygonTriangulationTests: XCTestCase {
    func testConcavePolygonsOnEveryPlaneAtDifferentScales() throws {
        let polygon: [SIMD2<Float>] = [SIMD2(0,2),SIMD2(0,0),SIMD2(2,0),SIMD2(0.5,0.5)]
        for scale: Float in [0.0001, 1, 1000] {
            for plane in 0..<3 {
                let points = polygon.map { p -> SIMD3<Float> in
                    let q = p * scale
                    return plane == 0 ? SIMD3(q.x,q.y,0) : plane == 1 ? SIMD3(0,q.x,q.y) : SIMD3(q.y,0,q.x)
                }
                let triangles = try XCTUnwrap(PolygonTriangulation.indices(count: 4) { points[$0] })
                var area: Float = 0
                for i in stride(from: 0, to: triangles.count, by: 3) {
                    let a = points[triangles[i]], b = points[triangles[i+1]], c = points[triangles[i+2]]
                    area += simd_length(simd_cross(b-a,c-a)) / 2
                }
                XCTAssertEqual(area / (scale * scale), 1, accuracy: 0.00001)
            }
        }
    }

    func testCollinearAndRepeatedCornersRetainTheirIndices() throws {
        let points: [SIMD3<Float>] = [SIMD3(0,2,0),SIMD3(0,1,0),SIMD3(0,0,0),SIMD3(0,0,0),SIMD3(2,0,0),SIMD3(0.5,0.5,0)]
        let triangles = try XCTUnwrap(PolygonTriangulation.indices(count: points.count) { points[$0] })
        XCTAssertEqual(triangles.count, (points.count - 2) * 3)
        XCTAssertEqual(Set(triangles), Set(points.indices))
        let area = stride(from: 0, to: triangles.count, by: 3).reduce(Float(0)) { total, i in
            let a = points[triangles[i]], b = points[triangles[i+1]], c = points[triangles[i+2]]
            return total + simd_length(simd_cross(b-a,c-a)) / 2
        }
        XCTAssertEqual(area, 1, accuracy: 0.00001)
    }

    /// Each triangle's area in the x-y plane, counter-clockwise ones counted as positive.
    private func areas(_ triangles: [Int], _ points: [SIMD3<Float>]) -> [Float] {
        stride(from: 0, to: triangles.count, by: 3).map { i in
            let a = points[triangles[i]], b = points[triangles[i + 1]], c = points[triangles[i + 2]]
            return simd_cross(b - a, c - a).z / 2
        }
    }

    private func covers(_ triangles: [Int], _ points: [SIMD3<Float>], _ place: SIMD3<Float>) -> Bool {
        stride(from: 0, to: triangles.count, by: 3).contains { i in
            let a = points[triangles[i]], b = points[triangles[i + 1]], c = points[triangles[i + 2]]
            return simd_cross(b - a, place - a).z > 0 && simd_cross(c - b, place - b).z > 0 && simd_cross(a - c, place - c).z > 0
        }
    }

    /// A square with a square hole, as a format without holes writes it: one outline that
    /// goes in to the hole along a cut and comes back along it, passing two corners twice.
    func testAFaceWithAHoleJoinedByACutIsSplitAroundTheHole() throws {
        let outline: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4), SIMD2(0, 0),
                                       SIMD2(1, 1), SIMD2(1, 3), SIMD2(3, 3), SIMD2(3, 1), SIMD2(1, 1)]
        let points = outline.map { SIMD3($0.x, $0.y, 0) }
        let triangles = try XCTUnwrap(PolygonTriangulation.indices(count: points.count) { points[$0] })
        XCTAssertEqual(triangles.count, (points.count - 2) * 3)
        let each = areas(triangles, points)
        XCTAssertEqual(each.reduce(0, +), 12, accuracy: 1e-4, "the square less its hole")
        XCTAssertTrue(each.allSatisfy { $0 >= -1e-6 }, "no triangle is turned over")
        XCTAssertFalse(covers(triangles, points, SIMD3(2, 2, 0)), "the hole stays open")
        XCTAssertTrue(covers(triangles, points, SIMD3(0.5, 2, 0)))
        XCTAssertTrue(covers(triangles, points, SIMD3(3.5, 2, 0)))
    }

    /// A star of 4,000 corners, every other one turned inwards.
    func testAnOutlineOfThousandsOfCornersIsSplit() throws {
        let corners = 4000
        let points = (0..<corners).map { i -> SIMD3<Float> in
            let angle = 2 * Float.pi * Float(i) / Float(corners), radius: Float = i % 2 == 0 ? 2 : 1.9
            return SIMD3(cos(angle), sin(angle), 0) * radius
        }
        let triangles = try XCTUnwrap(PolygonTriangulation.indices(count: corners) { points[$0] })
        XCTAssertEqual(triangles.count, (corners - 2) * 3)
        let outline = (0..<corners).reduce(Float(0)) { $0 + simd_cross(points[$1], points[($1 + 1) % corners]).z / 2 }
        let each = areas(triangles, points)
        XCTAssertEqual(each.reduce(0, +), outline, accuracy: outline * 1e-4)
        XCTAssertTrue(each.allSatisfy { $0 >= -1e-6 }, "no triangle is turned over")
    }
}
