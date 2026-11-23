import Foundation
import ModelCore
import ImportOBJ
import ImportPLY
import simd
import XCTest

final class PolygonTests: XCTestCase {
    func testConcaveFacesPreserveAreaWindingAndCornerAttributes() throws {
        let polygon: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(3,0,0), SIMD3(3,3,0), SIMD3(2,3,0), SIMD3(2,1,0), SIMD3(1,1,0), SIMD3(1,3,0), SIMD3(0,3,0)]
        for reversed in [false, true] {
            let points = reversed ? Array(polygon.reversed()) : polygon
            let rows = points.map { "\($0.x) \($0.y) \($0.z)" }
            let obj = "mtllib a.mtl\n" + rows.map { "v " + $0 }.joined(separator: "\n") + "\n"
                + points.map { "vt \($0.x / 3) \($0.y / 3)" }.joined(separator: "\n")
                + "\nvn 0 0 1\nusemtl a\nf " + (1...8).map { "\($0)/\($0)/1" }.joined(separator: " ") + "\n"
            let files = SidecarFiles(["a.mtl": Data("newmtl a\nmap_Kd a.png\n".utf8), "a.png": Data([1])])
            let ply = "ply\nformat ascii 1.0\nelement vertex 8\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n"
                + rows.joined(separator: "\n") + "\n8 0 1 2 3 4 5 6 7\n"
            let scenes = [try OBJReader.scene(from: Data(obj.utf8), sidecars: files), try PLYReader.scene(from: Data(ply.utf8))]
            for (source, scene) in scenes.enumerated() {
                let part = scene.meshes[0].parts[0]
                XCTAssertEqual(part.faceSizes, [8]); XCTAssertEqual(part.triangleIndices.count, 18)
                var area: Float = 0
                for i in stride(from: 0, to: part.triangleIndices.count, by: 3) {
                    let a = part.positions[Int(part.triangleIndices[i])], b = part.positions[Int(part.triangleIndices[i+1])], c = part.positions[Int(part.triangleIndices[i+2])]
                    let cross = simd_cross(b-a, c-a).z
                    XCTAssertGreaterThanOrEqual(cross * (reversed ? -1 : 1), 0)
                    area += abs(cross) / 2
                    let q = SIMD3<Float>(1.5,2,0)
                    let signs = [simd_cross(b-a,q-a).z, simd_cross(c-b,q-b).z, simd_cross(a-c,q-c).z]
                    XCTAssertFalse(signs.allSatisfy { $0 >= 0 } || signs.allSatisfy { $0 <= 0 })
                }
                XCTAssertEqual(area, 7, accuracy: 0.0001)
                if source == 0 {
                    for i in part.positions.indices {
                        XCTAssertEqual(part.uv0[i], SIMD2(part.positions[i].x / 3, 1 - part.positions[i].y / 3))
                        XCTAssertEqual(part.normals[i], SIMD3(0,0,1))
                    }
                }
            }
        }
    }
}
