import Foundation
@testable import ImportOBJ
@testable import ImportPLY
import ModelCore
import XCTest

/// Odd corners of the PLY and OBJ readers.
final class TextGapsTests: XCTestCase {
    func testPLYListsOnVerticesFacesAndOtherElementsAreStepped() throws {
        let text = """
        ply
        format ascii 1.0
        element vertex 3
        property float x
        property float y
        property float z
        property list uchar float extra
        element face 1
        property list uchar int vertex_indices
        property list uchar float weights
        element edge 2
        property int a
        property list uchar int ends
        end_header
        0 0 0 2 7 8
        1 0 0 0
        0 1 0 1 9
        3 0 1 2 2 5 6
        4 2 0 1
        5 1 3 4 5
        """
        let scene = try PLYReader.scene(from: Data(text.utf8))
        let part = try XCTUnwrap(scene.meshes.first?.parts.first)
        XCTAssertEqual(part.positions.count, 3)
        XCTAssertEqual(part.positions[2], SIMD3(0, 1, 0))
        XCTAssertEqual(part.triangleIndices, [0, 1, 2])
        XCTAssertEqual(scene.topology.faces, 1)
    }

    func testPLYWithAScalarOnlyElementAfterTheFaces() throws {
        let text = """
        ply
        format ascii 1.0
        element vertex 3
        property float x
        property float y
        property float z
        element face 1
        property list uchar int vertex_indices
        element material 1
        property int id
        end_header
        0 0 0
        1 0 0
        0 1 0
        3 0 1 2
        7
        """
        XCTAssertEqual(try PLYReader.scene(from: Data(text.utf8)).topology.faces, 1)
    }

    func testPLYWithAListCountBelowZeroIsTruncated() {
        let text = "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty list char float extra\nend_header\n0 0 0 -3\n"
        XCTAssertThrowsError(try PLYReader.scene(from: Data(text.utf8))) { XCTAssertEqual($0 as? PLYReader.Failure, .truncated) }
    }

    func testPLYFailuresHaveMessages() {
        let all: [PLYReader.Failure] = [.notPLY, .header("x"), .truncated, .empty]
        XCTAssertEqual(Set(all.map { $0.errorDescription ?? "" }).count, 4)
        XCTAssertTrue(all[1].errorDescription?.contains("x") == true)
    }

    func testOBJWordsThatMerelyStartWithMtllibAreNotLibraries() throws {
        let text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl a\nf 1/1 2/2 3/3\nmtllibrary nothing\nmtllib real.mtl\n"
        let files = SidecarFiles(["real.mtl": Data("newmtl a\nKd 0 1 0\n".utf8)])
        let scene = try OBJReader.scene(from: Data(text.utf8), sidecars: files)
        XCTAssertEqual(scene.materials[0].baseColor, SIMD4(0, 1, 0, 1))
    }

    func testOBJHasAMessageForNothingToShow() {
        XCTAssertThrowsError(try OBJReader.scene(from: Data("# nothing\n".utf8))) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "The file contains no geometry.")
        }
    }
}
