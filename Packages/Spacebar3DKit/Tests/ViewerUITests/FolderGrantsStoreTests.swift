import Foundation
import XCTest
@testable import ViewerUI

/// The edges of the grants: stores that cannot be written, keys that no longer open, and
/// the panel's words.
final class FolderGrantsStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-grants-edge-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheUsualStoresAreBuiltWithoutReadingOrWritingAnything() {
        // Only made, never asked: the process's own Application Support is not touched.
        let grants = FolderGrants(role: .app, sharedContainer: root)
        XCTAssertNotNil(grants)
        XCTAssertNotNil(FolderGrants(role: .quickLook, sharedContainer: nil))
    }

    func testAGrantFailsWhereTheStoreCannotBeWritten() throws {
        // A file where the store's folder should be.
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let grants = FolderGrants(role: .quickLook, scopedStore: blocker.appendingPathComponent("folders.plist"), sharedStore: nil)
        XCTAssertFalse(grants.grant(root.appendingPathComponent("models")))
        XCTAssertTrue(grants.folders.isEmpty)
    }

    func testAGrantFailsForAFolderThatIsNotThere() {
        let grants = FolderGrants(role: .quickLook, scopedStore: root.appendingPathComponent("own.plist"), sharedStore: nil)
        XCTAssertFalse(grants.grant(root.appendingPathComponent("nowhere")), "no bookmark of nothing")
    }

    func testRefreshingDropsAFolderWhoseKeyOpensNothingAndKeepsTheOthers() throws {
        let store = root.appendingPathComponent("own.plist"), shared = root.appendingPathComponent("shared.plist")
        let app = FolderGrants(role: .app, scopedStore: store, sharedStore: shared)
        try XCTSkipUnless(app.grant(root.appendingPathComponent("models")), "this process cannot make security-scoped bookmarks")
        // A second key that is only junk.
        var list = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: store), format: nil) as? [String: Data])
        list["/junk"] = Data([1, 2, 3])
        try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0).write(to: store)
        XCTAssertTrue(app.folders.contains("/junk"))
        app.refreshShared()
        XCTAssertEqual(app.folders, [FolderGrants.key(for: root.appendingPathComponent("models"))])
    }

    func testAKeyOfAFolderThatWasMovedIsMadeAgainWhenTheAppStarts() throws {
        let store = root.appendingPathComponent("own.plist"), shared = root.appendingPathComponent("shared.plist")
        let app = FolderGrants(role: .app, scopedStore: store, sharedStore: shared)
        let before = root.appendingPathComponent("models"), after = root.appendingPathComponent("models-renamed")
        try XCTSkipUnless(app.grant(before), "this process cannot make security-scoped bookmarks")
        let first = try Data(contentsOf: store)
        try FileManager.default.moveItem(at: before, to: after)
        app.refreshShared()
        // The key still opens the folder, now from its new place; the bookmark has been written again.
        XCTAssertNotEqual(try Data(contentsOf: store), first)
        // A file under the path it was granted at: the key opens the folder's new place, which is not that path.
        XCTAssertNil(app.beginAccess(forFileAt: before.appendingPathComponent("a.obj")))
        XCTAssertNil(app.beginAccess(forFileAt: after.appendingPathComponent("a.obj")), "stored under the path it had")
    }

    func testQuickLookHasNothingToRefreshAndTheStoreHasARoomLimit() throws {
        let store = root.appendingPathComponent("own.plist")
        let quickLook = FolderGrants(role: .quickLook, scopedStore: store, sharedStore: root.appendingPathComponent("shared.plist"))
        quickLook.refreshShared()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("shared.plist").path), "the shared copy is the app's to write")
        // A full store takes no new folder, but still takes again one it has.
        var full = Dictionary(uniqueKeysWithValues: (0..<FolderGrants.maxFolders).map { ("/full/\($0)", Data([1])) })
        try PropertyListSerialization.data(fromPropertyList: full, format: .binary, options: 0).write(to: store)
        XCTAssertFalse(quickLook.grant(root.appendingPathComponent("models")))
        XCTAssertEqual(quickLook.folders.count, FolderGrants.maxFolders)
        full[FolderGrants.key(for: root.appendingPathComponent("models"))] = Data([1])
        full["/full/0"] = nil
        try PropertyListSerialization.data(fromPropertyList: full, format: .binary, options: 0).write(to: store)
        XCTAssertTrue(quickLook.grant(root.appendingPathComponent("models")))
    }

    func testTheNoticeAskForTheFolderInPlainWords() {
        XCTAssertEqual(MissingFilesNotice.panelPrompt, "Allow")
        let message = MissingFilesNotice.panelMessage(file: "car.obj")
        XCTAssertTrue(message.contains("“car.obj”"))
        XCTAssertTrue(message.contains("read-only access"))
    }
}
