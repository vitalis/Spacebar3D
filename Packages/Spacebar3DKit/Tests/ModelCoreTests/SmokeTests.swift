import Foundation
import ModelCore
import XCTest

final class FormatDetectorSmokeTests: XCTestCase {
    func testAFewFormats() {
        XCTAssertEqual(FormatDetector.detect(Data("glTF\u{02}\u{00}\u{00}\u{00}".utf8), ext: "glb"), .gltf)
        XCTAssertEqual(FormatDetector.detect(Data("v 0 0 0\nf 1 2 3\n".utf8), ext: ""), .obj)
        XCTAssertEqual(FormatDetector.detect(Data("ply\nformat ascii 1.0\n".utf8), ext: "ply"), .ply)
        XCTAssertEqual(FormatDetector.detect(Data([1, 2, 3, 4, 5, 6, 7, 8, 9]), ext: ""), .gltf)
        XCTAssertEqual(FormatDetector.detect(Data(), ext: ""), .gltf)
    }

    func testTopologyLabel() {
        XCTAssertEqual(topologyLabel(triangles: 0, quads: 0, ngons: 0), "–")
        XCTAssertEqual(topologyLabel(triangles: 2, quads: 0, ngons: 0), "Triangle")
        XCTAssertEqual(topologyLabel(triangles: 0, quads: 2, ngons: 0), "Quad")
        XCTAssertEqual(topologyLabel(triangles: 0, quads: 0, ngons: 1), "N-gon")
        XCTAssertEqual(topologyLabel(triangles: 1, quads: 1, ngons: 0), "Mixed")
    }
}
