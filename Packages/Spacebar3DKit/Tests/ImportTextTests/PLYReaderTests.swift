import Foundation
import ImportPLY
import ImportRouter
import ModelCore
import simd
import XCTest

final class PLYReaderTests: XCTestCase {
    func testInvalidASCIIListCountsAreRejectedInEveryElement() throws {
        for value in ["nan", "inf", "-inf", "1e100", "-1", "1.5", "256"] {
            for element in ["vertex", "face", "ignored"] {
                let fields = element == "vertex" ? "property float x\nproperty float y\nproperty float z\n" : ""
                let prefix = element == "vertex" ? "0 0 0 " : ""
                // Enough remaining values to distinguish uchar range validation from truncation.
                let data = "ply\nformat ascii 1.0\nelement \(element) 1\n\(fields)property list uchar int vertex_indices\nend_header\n\(prefix)\(value) " + String(repeating: "0 ", count: 300)
                XCTAssertThrowsError(try PLYReader.scene(from: Data(data.utf8)), "\(element): \(value)") {
                    XCTAssertEqual($0 as? PLYReader.Failure, .truncated)
                }
            }
        }
    }

    private let header = """
    ply
    format ascii 1.0
    comment made by hand
    element vertex 4
    property float x
    property float y
    property float z
    property uchar red
    property uchar green
    property uchar blue
    element face 1
    property list uchar int vertex_indices
    end_header

    """

    /// The colours a file gives its vertices are how it looks. The grey that stands in for
    /// a material the format does not have must not darken them, on faces any more than on
    /// points; a mesh with no colours of its own is still that grey.
    func testColouredFacesAreNotTintedByTheStandInGrey() throws {
        let grey = SIMD4<Float>(Float(0xb4) / 255, Float(0xb4) / 255, Float(0xb8) / 255, 1)
        let coloured = try PLYReader.scene(from: Data((header + "0 0 0 255 0 0\n1 0 0 0 255 0\n1 1 0 0 0 255\n0 1 0 255 255 255\n4 0 1 2 3\n").utf8))
        XCTAssertEqual(coloured.materials.first?.baseColor, SIMD4(1, 1, 1, 1))
        let plain = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 2\n"
        XCTAssertEqual(try PLYReader.scene(from: Data(plain.utf8)).materials.first?.baseColor, grey)
    }

    func testTextQuadKeepsItsPolygonAndColours() throws {
        let text = header + "0 0 0 255 0 0\n1 0 0 0 255 0\n1 1 0 0 0 255\n0 1 0 255 255 255\n4 0 1 2 3\n"
        let scene = try PLYReader.scene(from: Data(text.utf8))
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        XCTAssertEqual(part.positions, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)])
        XCTAssertEqual(part.colors, [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1), SIMD4(1, 1, 1, 1)])
        XCTAssertEqual(part.triangleIndices, [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(part.faceSizes, [4])
        XCTAssertTrue(part.normals.isEmpty)
        XCTAssertEqual(scene.topology.faces, 1)
        XCTAssertEqual(scene.topology.quads, 1)
        XCTAssertEqual(scene.topology.vertices, 4)
        XCTAssertEqual(scene.topology.label, "Quad")
        XCTAssertTrue(scene.hasTexturedAppearance)
        XCTAssertEqual(FormatDetector.detect(Data(text.utf8), ext: "ply"), .ply)
    }

    /// The same triangle in both byte orders, with normals, a property to pass over, an
    /// element to pass over before the faces, and doubles for the positions.
    func testBinaryInBothByteOrders() throws {
        for big in [false, true] {
            var data = Data("""
            ply
            format \(big ? "binary_big_endian" : "binary_little_endian") 1.0
            element vertex 3
            property double x
            property double y
            property double z
            property float nx
            property float ny
            property float nz
            property float quality
            element extra 2
            property list uchar short values
            element face 1
            property uchar flags
            property list uchar uint vertex_index
            end_header

            """.utf8)
            func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: big ? v.bigEndian : v.littleEndian) { data.append(contentsOf: $0) } }
            for p in [SIMD3<Double>(0, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 3, 0)] {
                for c in [p.x, p.y, p.z] { put(c.bitPattern) }
                for c in [Float(0), 0, 1, 0.5] { put(c.bitPattern) }
            }
            put(UInt8(2)); put(Int16(7)); put(Int16(8)); put(UInt8(0))
            put(UInt8(9)); put(UInt8(3)); put(UInt32(0)); put(UInt32(1)); put(UInt32(2))
            let scene = try PLYReader.scene(from: data)
            let part = try XCTUnwrap(scene.meshes.first?.parts.first)
            XCTAssertEqual(part.positions, [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 3, 0)], "\(big)")
            XCTAssertEqual(part.normals, [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)])
            XCTAssertEqual(part.triangleIndices, [0, 1, 2])
            XCTAssertNil(part.faceSizes)
            XCTAssertTrue(part.colors.isEmpty)
            XCTAssertFalse(scene.hasTexturedAppearance)
            XCTAssertEqual(scene.topology.label, "Triangle")
        }
    }

    func testAFileWithNoFacesIsAPointCloud() throws {
        let text = "ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nend_header\n0 0 0\n1 2 3\n"
        let scene = try PLYReader.scene(from: Data(text.utf8))
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        XCTAssertEqual(part.primitive, .points)
        XCTAssertEqual(part.positions.count, 2)
        XCTAssertEqual(scene.topology.faces, 0)
        XCTAssertEqual(scene.topology.vertices, 2)
        XCTAssertEqual(try XCTUnwrap(scene.bounds).max, SIMD3(1, 2, 3))
    }

    func testFacesThatPointOutsideTheVerticesAreLeftOut() throws {
        let text = header.replacingOccurrences(of: "element face 1", with: "element face 3")
            + "0 0 0 1 1 1\n1 0 0 1 1 1\n1 1 0 1 1 1\n0 1 0 1 1 1\n3 0 1 9\n3 0 1 2\n2 0 1\n"
        let scene = try PLYReader.scene(from: Data(text.utf8))
        XCTAssertEqual(scene.meshes[0].parts[0].triangleIndices, [0, 1, 2])
        XCTAssertEqual(scene.topology.faces, 1)
    }

    func testDamagedFilesFailCleanly() throws {
        XCTAssertThrowsError(try PLYReader.scene(from: Data("solid x".utf8))) { XCTAssertEqual($0 as? PLYReader.Failure, .notPLY) }
        XCTAssertThrowsError(try PLYReader.scene(from: Data("ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\n".utf8)))
        XCTAssertThrowsError(try PLYReader.scene(from: Data((header + "0 0 0 1 1 1\n").utf8))) { XCTAssertEqual($0 as? PLYReader.Failure, .truncated) }
        // A count far beyond what the file holds must not be allocated for.
        let huge = "ply\nformat binary_little_endian 1.0\nelement vertex 4000000000\nproperty float x\nproperty float y\nproperty float z\nend_header\n"
        XCTAssertThrowsError(try PLYReader.scene(from: Data(huge.utf8))) { XCTAssertEqual($0 as? PLYReader.Failure, .truncated) }
        let noFormat = "ply\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n0 0 0\n"
        XCTAssertThrowsError(try PLYReader.scene(from: Data(noFormat.utf8)))
        XCTAssertThrowsError(try PLYReader.scene(from: Data("ply\nformat ascii 1.0\nelement vertex 0\nproperty float x\nproperty float y\nproperty float z\nend_header\n".utf8))) { XCTAssertEqual($0 as? PLYReader.Failure, .empty) }
    }

    func testTheRouterReadsPLYAndOBJFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ply = folder.appendingPathComponent("quad.ply"), obj = folder.appendingPathComponent("tri.obj")
        try Data((header + "0 0 0 255 0 0\n1 0 0 0 255 0\n1 1 0 0 0 255\n0 1 0 255 255 255\n4 0 1 2 3\n").utf8).write(to: ply)
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: obj)
        XCTAssertEqual(try ImportRouter.load(ply, format: .ply).topology.faces, 1)
        XCTAssertEqual(try ImportRouter.load(obj, format: .obj).topology.faces, 1)
    }

    /// A scan keeps its points where they are on the map, in text or in 64-bit numbers.
    /// Brought near the origin before they are rounded to Float, they keep what lies
    /// between the half units a Float that large comes in.
    func testAModelFarFromTheOriginKeepsItsShape() throws {
        let corners = [SIMD3<Double>(4194304.10, 2097152.20, 1048576.30), SIMD3(4194304.35, 2097152.20, 1048576.30), SIMD3(4194304.10, 2097152.45, 1048576.30)]
        func header(_ format: String) -> String {
            "ply\nformat \(format) 1.0\nelement vertex 3\nproperty double x\nproperty double y\nproperty double z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n"
        }
        let text = Data((header("ascii") + corners.map { "\($0.x) \($0.y) \($0.z)\n" }.joined() + "3 0 1 2\n").utf8)
        var binary = Data(header("binary_little_endian").utf8)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { binary.append(contentsOf: $0) } }
        for c in corners { put(c.x.bitPattern); put(c.y.bitPattern); put(c.z.bitPattern) }
        put(UInt8(3)); put(Int32(0)); put(Int32(1)); put(Int32(2))
        for (data, name) in [(text, "text"), (binary, "binary")] {
            let p = try XCTUnwrap(PLYReader.scene(from: data).meshes.first?.parts.first).positions
            XCTAssertEqual(simd_distance(p[0], p[1]), 0.25, accuracy: 1e-5, name)
            XCTAssertEqual(simd_distance(p[0], p[2]), 0.25, accuracy: 1e-5, name)
            XCTAssertLessThan(simd_reduce_max(simd_abs(p[0])), 1, name)
        }
    }
}
