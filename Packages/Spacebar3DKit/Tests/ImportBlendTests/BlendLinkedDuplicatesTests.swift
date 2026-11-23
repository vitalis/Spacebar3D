import Foundation
import ImportBlend
import ModelCore
import simd
import XCTest

/// Objects that share one mesh datablock in Blender (linked duplicates) should share one
/// `ModelScene.Mesh` here, each object a node pointing at it, instead of a copy per object.
/// In the fixture, "Shown", "Child" and "OnBone" all use the mesh "Shape".
final class BlendLinkedDuplicatesTests: XCTestCase {
    private func node(_ scene: ModelScene, _ name: String) throws -> ModelScene.Node { try XCTUnwrap(scene.nodes.first { $0.name == name }, name) }
    private func meshIndex(_ scene: ModelScene, _ name: String) throws -> Int { try XCTUnwrap(try node(scene, name).mesh, name) }

    /// A scene of a hundred linked duplicates (a forest of one tree) held a hundred copies of
    /// the tree's vertices, in the file's memory, in the GPU's and in the time to open it.
    func testObjectsOfOneMeshShareOneMeshInEveryLayout() throws {
        for layout in [BlendFixture.Layout.records, .layers, .attributes] {
            let scene = try BlendReader.scene(from: BlendFixture.make(layout))
            let shown = try meshIndex(scene, "Shown"), child = try meshIndex(scene, "Child"), bone = try meshIndex(scene, "OnBone")
            XCTAssertEqual(shown, child, "\(layout)")
            XCTAssertEqual(shown, bone, "\(layout)")
            XCTAssertEqual(scene.meshes.count, 1, "\(layout): one datablock, one mesh")
        }
    }

    /// Guard: sharing the mesh keeps each object where it stands, under its own node.
    func testSharedObjectsKeepTheirOwnPlacesAndNames() throws {
        let scene = try BlendReader.scene(from: BlendFixture.make(.layers))
        let places = try ["Shown", "Child", "OnBone"].map { try node(scene, $0).transform.columns.3 }
        XCTAssertEqual(Set(places.map { "\($0)" }).count, 3, "three objects, three places: \(places)")
        XCTAssertEqual(try node(scene, "Shown").transform.columns.3, SIMD4(1, 2, 3, 1), "where the file puts it, under the node that turns Z up to Y up")
        XCTAssertEqual(Set(scene.nodes.compactMap { $0.mesh == nil ? nil : $0.name }), ["Shown", "Child", "OnBone"])
        let mesh = scene.meshes[try meshIndex(scene, "Shown")]
        XCTAssertEqual(mesh.parts.count, 2, "the mesh's two material slots")
        XCTAssertEqual(mesh.parts.map { $0.triangleIndices.count }, [6, 3])
    }

    /// Guard: an object that puts its own material over the mesh's does not look like its
    /// neighbours, so it must not share their mesh; those without one still share.
    func testAnObjectWithItsOwnMaterialDoesNotShareWithThoseWithout() throws {
        let scene = try BlendReader.scene(from: BlendFixture.make(.layers, objectMaterial: true))
        let shown = try meshIndex(scene, "Shown"), child = try meshIndex(scene, "Child"), bone = try meshIndex(scene, "OnBone")
        XCTAssertNotEqual(shown, child)
        XCTAssertEqual(child, bone, "the two that keep the mesh's materials share")
        XCTAssertEqual(scene.materials[try XCTUnwrap(scene.meshes[shown].parts[0].material)].name, "Picture")
        XCTAssertEqual(scene.materials[try XCTUnwrap(scene.meshes[child].parts[0].material)].name, "Red")
        XCTAssertEqual(scene.meshes.count, 2)
    }

    /// Guard: a modifier on one object (a mirror across X) changes only that object's shape,
    /// so the object is not shared with its plain neighbours.
    func testAnObjectWithAModifierDoesNotShareWithThoseWithout() throws {
        let scene = try BlendReader.scene(from: BlendFixture.make(.layers, modifiers: [.mirror(flag: 1 << 3)]))
        let shown = try meshIndex(scene, "Shown"), child = try meshIndex(scene, "Child"), bone = try meshIndex(scene, "OnBone")
        XCTAssertNotEqual(shown, child)
        XCTAssertEqual(child, bone)
        XCTAssertGreaterThan(scene.meshes[shown].parts.map(\.positions.count).reduce(0, +), scene.meshes[child].parts.map(\.positions.count).reduce(0, +), "the mirrored object has the mirror image too")
        XCTAssertEqual(scene.meshes.count, 2)
    }
}
