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
}
