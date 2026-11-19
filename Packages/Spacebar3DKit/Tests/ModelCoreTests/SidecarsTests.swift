import Foundation
import ModelCore
import XCTest

final class SidecarsTests: XCTestCase {
    /// The sandbox hands over a file beside a model without the folder only when it has
    /// the model's own name and a declared extension.
    func testAFileWithTheModelsNameAndAnotherExtensionIsRelated() {
        XCTAssertTrue(SidecarFolder.isRelated("ship.mtl", toModelNamed: "ship.obj"))
        XCTAssertTrue(SidecarFolder.isRelated("ship.MTL", toModelNamed: "ship.obj"))
        XCTAssertTrue(SidecarFolder.isRelated("scene.bin", toModelNamed: "scene.gltf"))
        XCTAssertTrue(SidecarFolder.isRelated("my ship.v2.png", toModelNamed: "my ship.v2.fbx"))
        XCTAssertFalse(SidecarFolder.isRelated("wood.png", toModelNamed: "ship.obj"), "another name")
        XCTAssertFalse(SidecarFolder.isRelated("Ship.mtl", toModelNamed: "ship.obj"), "names are compared as written")
        XCTAssertFalse(SidecarFolder.isRelated("ship.exe", toModelNamed: "ship.obj"), "not a declared extension")
        XCTAssertFalse(SidecarFolder.isRelated("ship.png", toModelNamed: "ship.png"), "the model itself")
        XCTAssertFalse(SidecarFolder.isRelated(".mtl", toModelNamed: ".obj"))
        XCTAssertFalse(SidecarFolder.isRelated("ship", toModelNamed: "ship.obj"))
    }

    func testAReadableFileBesideTheModelIsReadAsBefore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-sidecars-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("newmtl a\n".utf8).write(to: folder.appendingPathComponent("ship.mtl"))
        let source = SidecarFolder(modelURL: folder.appendingPathComponent("ship.obj"))
        XCTAssertEqual(source.data(named: "ship.mtl"), Data("newmtl a\n".utf8))
        XCTAssertNil(source.data(named: "absent.mtl"))
        XCTAssertNil(source.data(named: "ship.bin"), "related by name, and not there")
    }
}
