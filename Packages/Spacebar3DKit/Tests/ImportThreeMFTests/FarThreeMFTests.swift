import Foundation
import ModelCore
import simd
import XCTest
import zlib
@testable import ImportThreeMF

/// 3MF writes its corners as XML text, which holds any number of digits, so a far model is
/// not limited by Float in the file; the reader must not be either.
final class FarThreeMFTests: XCTestCase {
    private func package(vertices: [(x: String, y: String, z: String)]) -> Data {
        let verts = vertices.map { "<vertex x=\"\($0.x)\" y=\"\($0.y)\" z=\"\($0.z)\"/>" }.joined()
        let model = "<?xml version=\"1.0\"?>\n<model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources><object id=\"1\"><mesh><vertices>\(verts)</vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh></object></resources><build><item objectid=\"1\"/></build></model>"
        let rels = "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>"
        func le(_ v: Int, _ n: Int, _ d: inout Data) { for i in 0..<n { d.append(UInt8((v >> (8 * i)) & 0xff)) } }
        var out = Data(), directory = Data()
        for file in [(name: "_rels/.rels", data: Data(rels.utf8)), (name: "3D/3dmodel.model", data: Data(model.utf8))] {
            let name = Array(file.name.utf8), body = [UInt8](file.data)
            let crc = Int(body.withUnsafeBufferPointer { crc32(0, $0.baseAddress, UInt32($0.count)) })
            let offset = out.count
            le(0x0403_4b50, 4, &out); le(20, 2, &out); le(0, 8, &out)
            le(crc, 4, &out); le(body.count, 4, &out); le(body.count, 4, &out); le(name.count, 2, &out); le(0, 2, &out)
            out.append(contentsOf: name); out.append(contentsOf: body)
            le(0x0201_4b50, 4, &directory); le(20, 2, &directory); le(20, 2, &directory); le(0, 8, &directory)
            le(crc, 4, &directory); le(body.count, 4, &directory); le(body.count, 4, &directory); le(name.count, 2, &directory)
            le(0, 12, &directory); le(offset, 4, &directory)
            directory.append(contentsOf: name)
        }
        let start = out.count
        out.append(directory)
        le(0x0605_4b50, 4, &out); le(0, 4, &out); le(2, 2, &out); le(2, 2, &out); le(directory.count, 4, &out); le(start, 4, &out); le(0, 2, &out)
        return out
    }

    /// A part placed where it stands in a survey, a quarter of a unit across, four million
    /// units out: its 0.25 edges came out 0.5 or 0, because the corners were rounded to Float
    /// (steps of half a unit) in the file's own frame before the node that stands the model
    /// up and the move to the origin were applied.
    func testA3MFFarFromTheOriginKeepsItsShape() throws {
        let scene = try ThreeMFReader.scene(from: package(vertices: [
            ("4194304.10", "2097152.20", "1048576.30"), ("4194304.35", "2097152.20", "1048576.30"), ("4194304.10", "2097152.45", "1048576.30")])).movedNearTheOrigin()
        let node = try XCTUnwrap(scene.nodes.firstIndex { $0.mesh != nil })
        let world = scene.worldTransform(of: node)
        let p = scene.meshes[scene.nodes[node].mesh!].parts[0].positions.prefix(3).map { v -> SIMD3<Float> in let w = world * SIMD4(v, 1); return SIMD3(w.x, w.y, w.z) }
        print("P3D-FAR3MF edges \(simd_distance(p[0], p[1])) \(simd_distance(p[0], p[2])) \(simd_distance(p[1], p[2])) local \(scene.meshes[0].parts[0].positions.prefix(3))")
        XCTAssertEqual(simd_distance(p[0], p[1]), 0.25, accuracy: 1e-3)
        XCTAssertEqual(simd_distance(p[0], p[2]), 0.25, accuracy: 1e-3)
        XCTAssertEqual(simd_distance(p[1], p[2]), Float(0.125).squareRoot(), accuracy: 1e-3)
    }
}
