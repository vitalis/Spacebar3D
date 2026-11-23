import Foundation
import ImportModelIO
import ImportRouter
import ImportSTL
import ModelCore
import simd
import XCTest

final class STLImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-stl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Binary STL: 80-byte header, triangle count, then normal + three corners + 2 bytes each.
    private func binarySTL(_ triangles: [[SIMD3<Float>]]) -> Data {
        var data = Data(count: 80)
        withUnsafeBytes(of: UInt32(triangles.count).littleEndian) { data.append(contentsOf: $0) }
        for t in triangles {
            let n = simd_normalize(simd_cross(t[1] - t[0], t[2] - t[0]))
            for v in [n] + t { for c in [v.x, v.y, v.z] { withUnsafeBytes(of: c.bitPattern.littleEndian) { data.append(contentsOf: $0) } } }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    private let tetrahedron: [[SIMD3<Float>]] = {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(2, 0, 0), c = SIMD3<Float>(0, 3, 0), d = SIMD3<Float>(0, 0, 4)
        return [[a, c, b], [a, b, d], [a, d, c], [b, c, d]]
    }()

    func testBinarySTLLoadsWithItsTrianglesAndBounds() throws {
        let url = folder.appendingPathComponent("tetra.stl")
        let data = binarySTL(tetrahedron)
        try data.write(to: url)
        XCTAssertEqual(FormatDetector.detect(data, ext: "stl"), .stl)

        let scene = try ImportRouter.load(url, format: .stl)
        XCTAssertEqual(scene.topology.faces, 4)
        XCTAssertEqual(scene.topology.triangles, 4)
        XCTAssertEqual(scene.topology.vertices, 12)
        XCTAssertEqual(scene.topology.label, "Triangle")
        XCTAssertEqual(scene.meshes.flatMap(\.parts).map { $0.triangleIndices.count }.reduce(0, +), 12)
        let bounds = try XCTUnwrap(scene.bounds)
        // Z-up in the file, Y-up in the scene: (x, y, z) becomes (x, z, -y).
        XCTAssertEqual(bounds.min, SIMD3(0, 0, -3), accuracy: 1e-5)
        XCTAssertEqual(bounds.max, SIMD3(2, 4, 0), accuracy: 1e-5)
        for part in scene.meshes.flatMap(\.parts) {
            XCTAssertNil(part.faceSizes)
            XCTAssertTrue(part.normals.isEmpty || part.normals.count == part.positions.count)
        }
    }

    func testTextSTLLoads() throws {
        var text = "solid t\n"
        for t in tetrahedron {
            text += " facet normal 0 0 0\n  outer loop\n"
            for v in t { text += "   vertex \(v.x) \(v.y) \(v.z)\n" }
            text += "  endloop\n endfacet\n"
        }
        text += "endsolid t\n"
        let url = folder.appendingPathComponent("tetra-text.stl")
        try Data(text.utf8).write(to: url)
        let scene = try ImportRouter.load(url, format: .stl)
        XCTAssertEqual(scene.topology.faces, 4)
        XCTAssertEqual(try XCTUnwrap(scene.bounds).max, SIMD3(2, 4, 0), accuracy: 1e-5)
    }

    func testAnSTLWithAnotherExtensionStillLoads() throws {
        for name in ["tetra.3ds", "tetra", "tetra.STL", "tetra.model.bin"] {
            let url = folder.appendingPathComponent(name)
            try binarySTL(tetrahedron).write(to: url)
            XCTAssertEqual(try ImportRouter.load(url, format: .stl).topology.faces, 4, name)
        }
    }

    /// Our reader and Model I/O agree on the same file.
    func testOwnReaderAgreesWithModelIO() throws {
        let url = folder.appendingPathComponent("tetra.stl")
        try binarySTL(tetrahedron).write(to: url)
        let ours = try STLReader.load(url), theirs = try ModelIOImporter.load(url, format: .stl)
        XCTAssertEqual(ours.topology, theirs.topology)
        let a = try XCTUnwrap(ours.bounds), b = try XCTUnwrap(theirs.bounds)
        XCTAssertLessThan(simd_distance(a.min, b.min), 1e-5)
        XCTAssertLessThan(simd_distance(a.max, b.max), 1e-5)
    }

    /// Corners at one position become one vertex; the file's own counts are still reported.
    func testCornersAtTheSamePositionAreMerged() throws {
        for data in [binarySTL(tetrahedron), textSTL(tetrahedron)] {
            let scene = try STLReader.scene(from: data)
            let part = try XCTUnwrap(scene.meshes.first?.parts.first)
            XCTAssertEqual(part.positions.count, 4)
            XCTAssertEqual(part.triangleIndices.count, 12)
            XCTAssertTrue(part.faceted)
            XCTAssertTrue(part.normals.isEmpty)
            XCTAssertEqual(scene.topology.vertices, 12)
            // Every triangle still has the corners the file gave it, in the file's order.
            for (t, triangle) in tetrahedron.enumerated() {
                XCTAssertEqual((0..<3).map { part.positions[Int(part.triangleIndices[t * 3 + $0])] }, triangle)
            }
        }
    }

    func testMergingGrowsPastItsFirstTableAndTreatsMinusZeroAsZero() throws {
        // A strip of 3000 separate triangles (9000 positions), then one that repeats a corner as -0.
        var triangles: [[SIMD3<Float>]] = (0..<3000).map { i in
            let x = Float(i) * 2 + 10
            return [SIMD3(x, 0, 0), SIMD3(x + 1, 0, 0), SIMD3(x, 1, 0)]
        }
        triangles.append([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        triangles.append([SIMD3(-0.0, 0, -0.0), SIMD3(0, -1, 0), SIMD3(1, 0, 0)])
        let part = try XCTUnwrap(STLReader.scene(from: textSTL(triangles)).meshes.first?.parts.first)
        XCTAssertEqual(part.positions.count, 9000 + 4)
        XCTAssertEqual(part.triangleIndices.count, 3002 * 3)
        XCTAssertEqual(part.triangleIndices[3001 * 3], part.triangleIndices[3000 * 3])
        XCTAssertEqual(part.triangleIndices[3001 * 3 + 2], part.triangleIndices[3000 * 3 + 1])
    }

    private func textSTL(_ triangles: [[SIMD3<Float>]]) -> Data {
        var text = "solid t\n"
        for t in triangles {
            text += " facet normal 0 0 0\n  outer loop\n"
            for v in t { text += "   vertex \(v.x) \(v.y) \(v.z)\n" }
            text += "  endloop\n endfacet\n"
        }
        return Data((text + "endsolid t\n").utf8)
    }

    func testABinaryFileCutShortKeepsTheTrianglesThatFit() throws {
        let data = binarySTL(tetrahedron)
        let scene = try STLReader.scene(from: data.prefix(84 + 50 * 2 + 20))
        XCTAssertEqual(scene.topology.faces, 2)
        XCTAssertThrowsError(try STLReader.scene(from: data.prefix(84 + 10)))
        XCTAssertThrowsError(try STLReader.scene(from: Data()))
        XCTAssertThrowsError(try STLReader.scene(from: Data("solid nothing\nendsolid\n".utf8)))
    }

    func testABinaryFileWhoseHeaderStartsWithSolidIsStillBinary() throws {
        var data = binarySTL(tetrahedron)
        data.replaceSubrange(0..<5, with: Array("solid".utf8))
        XCTAssertEqual(try STLReader.scene(from: data).topology.faces, 4)
    }

    func testAFileWithNoTrianglesIsAnError() throws {
        let url = folder.appendingPathComponent("empty.stl")
        try binarySTL([]).write(to: url)
        XCTAssertThrowsError(try ImportRouter.load(url, format: .stl))
    }

    private func corners(ofText text: String) throws -> [SIMD3<Float>] {
        try XCTUnwrap(STLReader.scene(from: Data(text.utf8)).meshes.first?.parts.first).positions
    }

    private func textSTL(_ corners: [String]) -> String {
        "solid a\nfacet normal 0 0 1\nouter loop\n" + corners.map { "vertex \($0)\n" }.joined() + "endloop\nendfacet\nendsolid a\n"
    }

    /// Text STL is read like every other text format: a point is the decimal mark whatever
    /// the computer's own is, and one comma in its place is read as meant.
    func testTextSTLReadsItsNumbersLikeTheOtherTextFormats() throws {
        let expected: [SIMD3<Float>] = [SIMD3(0.5, 0, 0), SIMD3(1.5, 0, 0), SIMD3(0, 2.25, 0)]
        XCTAssertEqual(try corners(ofText: textSTL(["0,5 0 0", "1,5 0 0", "0 2,25 0"])), expected)
        let was = setlocale(LC_NUMERIC, nil).map { String(cString: $0) }
        defer { setlocale(LC_NUMERIC, was) }
        try XCTSkipIf(setlocale(LC_NUMERIC, "de_DE.UTF-8") == nil, "no such locale on this computer")
        XCTAssertEqual(try corners(ofText: textSTL(["0.5 0 0", "1.5 0 0", "0 2.25 0"])), expected)
    }

    /// A part drawn where it stands on its site, millions of units out, with corners a
    /// quarter of a unit apart: brought near the origin before they are rounded to Float.
    func testATextSTLFarFromTheOriginKeepsItsShape() throws {
        let p = try corners(ofText: textSTL(["4194304.10 2097152.20 1048576.30", "4194304.35 2097152.20 1048576.30", "4194304.10 2097152.45 1048576.30"]))
        XCTAssertEqual(simd_distance(p[0], p[1]), 0.25, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(p[0], p[2]), 0.25, accuracy: 1e-5)
        XCTAssertLessThan(simd_reduce_max(simd_abs(p[0])), 1)
    }

    /// A voxel model's corners are whole steps apart. Finding which triangles share a
    /// corner must take no longer for them than for corners scattered anywhere.
    func testCornersAWholeStepApartAreMergedAsFastAsScatteredOnes() throws {
        var lattice: [[SIMD3<Float>]] = [], scattered: [[SIMD3<Float>]] = []
        var generator = SystemRandomNumberGenerator()
        func anywhere() -> SIMD3<Float> { SIMD3(Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator)) }
        for x in 0..<63 { for y in 0..<63 { for z in 0..<64 {
            let at = SIMD3(Float(x), Float(y), Float(z))
            lattice.append([at, at + SIMD3(1, 0, 0), at + SIMD3(0, 1, 0)])
            scattered.append([anywhere(), anywhere(), anywhere()])
        } } }
        func seconds(_ data: Data) throws -> Double {
            let start = Date()
            _ = try STLReader.scene(from: data)
            return Date().timeIntervalSince(start)
        }
        let anyTime = try seconds(binarySTL(scattered)), latticeTime = try seconds(binarySTL(lattice))
        XCTAssertLessThan(latticeTime, anyTime * 5)
    }

    func testOtherFormatsAreRefused() {
        XCTAssertThrowsError(try ImportRouter.load(folder.appendingPathComponent("x.dae"), format: .dae))
        XCTAssertEqual(ImportRouter.importable, [.stl, .ply, .obj, .usd, .threeMF, .threeDS, .fbx, .gltf, .gltfJSON, .blend])
    }
}

private func XCTAssertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThan(simd_length(a - b), accuracy, "\(a) is not \(b)", file: file, line: line)
}
