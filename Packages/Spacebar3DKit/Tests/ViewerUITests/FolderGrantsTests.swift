import Foundation
import XCTest
@testable import ViewerUI

final class FolderGrantsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-grants-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models/car/textures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models-old"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("stores"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func grants(_ role: FolderGrants.Role) -> FolderGrants {
        // Each process has its own store; the shared one is the app's to write.
        FolderGrants(role: role, scopedStore: root.appendingPathComponent(role == .app ? "stores/app/folders.plist" : "stores/quicklook/folders.plist"), sharedStore: root.appendingPathComponent("stores/shared.plist"))
    }

    func testTheNearestGrantedFolderAboveCounts() {
        let granted = ["/a/models", "/a/models/car", "/b"]
        XCTAssertEqual(FolderGrants.covering(granted, folder: "/a/models/car/textures"), "/a/models/car")
        XCTAssertEqual(FolderGrants.covering(granted, folder: "/a/models"), "/a/models")
        XCTAssertNil(FolderGrants.covering(granted, folder: "/a/models-old"), "a name that only starts the same is another folder")
        XCTAssertNil(FolderGrants.covering(granted, folder: "/a"))
        XCTAssertEqual(FolderGrants.covering(["/"], folder: "/a/b"), "/")
        XCTAssertEqual(FolderGrants.key(for: URL(fileURLWithPath: "/a/b/../c/")), "/a/c")
    }

    func testAGrantOpensTheFolderForTheAppAndThroughTheSharedStoreForQuickLook() throws {
        let app = grants(.app), quickLook = grants(.quickLook)
        let car = root.appendingPathComponent("models/car"), model = car.appendingPathComponent("car.obj")
        XCTAssertNil(app.beginAccess(forFileAt: model))
        XCTAssertNil(quickLook.beginAccess(forFileAt: model))

        // Quick Look asks for the folder itself and keeps its own key; the app's stores are untouched.
        XCTAssertTrue(quickLook.grant(car))
        XCTAssertEqual(quickLook.folders, [FolderGrants.key(for: car)])
        let own = try XCTUnwrap(quickLook.beginAccess(forFileAt: model))
        XCTAssertEqual(FolderGrants.key(for: own.folder), FolderGrants.key(for: car))
        own.end()
        XCTAssertNotNil(grants(.quickLook).beginAccess(forFileAt: model), "kept for the next preview")
        XCTAssertNil(app.beginAccess(forFileAt: model), "the app has its own")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stores/shared.plist").path), "the shared store is not the extension's to write")
        quickLook.revoke(FolderGrants.key(for: car))
        XCTAssertNil(quickLook.beginAccess(forFileAt: model))

        try XCTSkipUnless(app.grant(car), "this process cannot make security-scoped bookmarks")
        XCTAssertEqual(app.folders, [FolderGrants.key(for: car)])
        XCTAssertEqual(quickLook.folders, app.folders)
        for grants in [app, quickLook] {
            let access = try XCTUnwrap(grants.beginAccess(forFileAt: model))
            XCTAssertEqual(FolderGrants.key(for: access.folder), FolderGrants.key(for: car))
            access.end()
            XCTAssertNotNil(grants.beginAccess(forFileAt: car.appendingPathComponent("textures/wood.png")), "folders inside are covered")
            XCTAssertNil(grants.beginAccess(forFileAt: root.appendingPathComponent("models-old/x.obj")))
            XCTAssertNil(grants.beginAccess(forFileAt: root.appendingPathComponent("models/other.obj")), "the folder above is not")
        }

        // Granting the folder above replaces the one inside it.
        XCTAssertTrue(app.grant(root.appendingPathComponent("models")))
        XCTAssertEqual(app.folders, [FolderGrants.key(for: root.appendingPathComponent("models"))])
        XCTAssertEqual(quickLook.folders, app.folders)
        XCTAssertNotNil(quickLook.beginAccess(forFileAt: model))

        // The shared store is written again from the app's own; a folder that is gone is dropped.
        try FileManager.default.removeItem(at: root.appendingPathComponent("stores/shared.plist"))
        XCTAssertNil(quickLook.beginAccess(forFileAt: model))
        app.refreshShared()
        XCTAssertNotNil(quickLook.beginAccess(forFileAt: model))

        app.revoke(FolderGrants.key(for: root.appendingPathComponent("models")))
        XCTAssertTrue(app.folders.isEmpty)
        XCTAssertNil(quickLook.beginAccess(forFileAt: model))
    }

    func testDamagedStoresAreEmpty() throws {
        try Data("not a list".utf8).write(to: root.appendingPathComponent("stores/shared.plist"))
        XCTAssertTrue(grants(.quickLook).folders.isEmpty)
        XCTAssertNil(grants(.quickLook).beginAccess(forFileAt: root.appendingPathComponent("models/car/car.obj")))
        let junk = try PropertyListSerialization.data(fromPropertyList: [FolderGrants.key(for: root.appendingPathComponent("models")): Data([1, 2, 3])], format: .binary, options: 0)
        try junk.write(to: root.appendingPathComponent("stores/shared.plist"))
        XCTAssertNil(grants(.quickLook).beginAccess(forFileAt: root.appendingPathComponent("models/car/car.obj")), "a key that opens nothing")
    }

    func testTheNoticeSaysWhatIsMissingAndWhatCanBeDone() {
        XCTAssertNil(MissingFilesNotice(missing: [], granted: false, canGrant: true))
        XCTAssertNil(MissingFilesNotice(missing: [""], granted: false, canGrant: true))
        let app = MissingFilesNotice(missing: ["wood.png", "wood.png"], granted: false, canGrant: true)
        XCTAssertEqual(app?.title, "Textures not shown")
        XCTAssertEqual(app?.action, "Show Textures…")
        XCTAssertEqual(app?.detail, "The model references other files that could not be read.")
        let materials = MissingFilesNotice(missing: ["look.MTL"], granted: false, canGrant: true)
        XCTAssertEqual(materials?.title, "Materials not shown")
        XCTAssertEqual(materials?.action, "Show Materials…")
        // Where the folder cannot be asked for, nothing is offered and the text stays short.
        let stuck = MissingFilesNotice(missing: ["look.MTL"], granted: false, canGrant: false)
        XCTAssertNil(stuck?.action)
        XCTAssertEqual(stuck?.detail, "The model references other files that cannot be read here.")
        for notice in [app, materials, stuck] { XCTAssertLessThan(notice?.detail.count ?? 99, 70, "one short line") }
        // With access granted, name the files that still could not be read.
        let absent = MissingFilesNotice(missing: ["a.png", "b.png", "a.png", "c.png", "d.png"], granted: true, canGrant: true)
        XCTAssertEqual(absent?.title, "Textures unavailable")
        XCTAssertEqual(absent?.detail, "Could not read: a.png, b.png, c.png and 1 more.")
        XCTAssertNil(absent?.action)
        // A model that could not be shown at all: the notice is about the model.
        let failed = MissingFilesNotice(missing: ["scene.buffer"], granted: false, canGrant: true, failed: true)
        XCTAssertEqual(failed?.title, "Model not shown")
        XCTAssertEqual(failed?.action, "Show Model…")
        XCTAssertNil(MissingFilesNotice(missing: [], granted: false, canGrant: true, failed: true), "another kind of failure: no notice")
    }
}
