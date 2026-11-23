import XCTest

/// The list behind File > Open Recent, kept in a defaults store of the test's own: the
/// app's and the user's defaults are never passed, and never touched.
final class RecentModelsTests: TempDirTestCase {
    private var store: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        (store, suite) = try isolatedDefaults()
    }

    override func tearDownWithError() throws {
        forget(suite)
        store = nil
        try super.tearDownWithError()
    }

    private var names: [String] { RecentModels.urls(in: store).map(\.lastPathComponent) }
    private var kept: [Data] { store.array(forKey: RecentModels.key) as? [Data] ?? [] }

    func testNothingHasBeenOpenedAtFirst() {
        XCTAssertEqual(RecentModels.urls(in: store), [])
        XCTAssertNil(store.object(forKey: RecentModels.key))
    }

    func testTheNewestFileComesFirst() throws {
        for name in ["a.stl", "b.obj", "c.glb"] { RecentModels.note(try put(name), in: store) }
        XCTAssertEqual(names, ["c.glb", "b.obj", "a.stl"])
        // The whole location comes back, not only the name.
        XCTAssertEqual(RecentModels.urls(in: store).first?.resolvingSymlinksInPath().path, modelDir.appendingPathComponent("c.glb").path)
    }

    func testAFileOpenedAgainMovesToTheFrontAndIsListedOnce() throws {
        let a = try put("a.stl"), b = try put("b.stl")
        RecentModels.note(a, in: store)
        RecentModels.note(b, in: store)
        RecentModels.note(a, in: store)
        XCTAssertEqual(names, ["a.stl", "b.stl"])
        XCTAssertEqual(kept.count, 2)
        // The same file reached by another spelling of its path is still the same file.
        try put("sub/other.stl")
        RecentModels.note(modelDir.appendingPathComponent("sub/../b.stl"), in: store)
        XCTAssertEqual(names, ["b.stl", "a.stl"])
        XCTAssertEqual(kept.count, 2)
    }

    func testTheListKeepsTheTenNewest() throws {
        XCTAssertEqual(RecentModels.most, 10)
        for index in 1...12 { RecentModels.note(try put("m\(index).stl"), in: store) }
        XCTAssertEqual(names, (3...12).reversed().map { "m\($0).stl" })
        XCTAssertEqual(kept.count, 10)
    }

    /// What is kept is a bookmark for each file, under the one key, so the list is there at
    /// the next launch.
    func testTheListIsStillThereWhenTheStoreIsOpenedAgain() throws {
        RecentModels.note(try put("a.stl"), in: store)
        RecentModels.note(try put("b.stl"), in: store)
        XCTAssertEqual(RecentModels.key, "recentModels")
        let again = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(RecentModels.urls(in: again).map(\.lastPathComponent), ["b.stl", "a.stl"])
        XCTAssertEqual((again.array(forKey: "recentModels") as? [Data])?.count, 2)
        // The store is a file in the test's own folder, not one of the user's preferences.
        XCTAssertEqual(suite, root.appendingPathComponent("defaults/store").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: suite + ".plist"))
    }

    func testAFileThatHasGoneIsLeftOutAndForgottenAtTheNextOpening() throws {
        let gone = try put("gone.stl")
        RecentModels.note(gone, in: store)
        RecentModels.note(try put("stays.stl"), in: store)
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(names, ["stays.stl"])
        XCTAssertEqual(kept.count, 2, "reading the list does not rewrite it")
        RecentModels.note(try put("new.stl"), in: store)
        XCTAssertEqual(names, ["new.stl", "stays.stl"])
        XCTAssertEqual(kept.count, 2, "the bookmark that leads nowhere is dropped")
    }

    /// A bookmark follows its file, so a model renamed since is listed under its new name.
    func testARenamedFileIsListedUnderItsNewName() throws {
        let old = try put("old.stl")
        RecentModels.note(old, in: store)
        try FileManager.default.moveItem(at: old, to: modelDir.appendingPathComponent("new.stl"))
        XCTAssertEqual(names, ["new.stl"])
        // Opened under the new name, it is still one file in the list.
        RecentModels.note(modelDir.appendingPathComponent("new.stl"), in: store)
        XCTAssertEqual(names, ["new.stl"])
        XCTAssertEqual(kept.count, 1)
    }

    /// A stale bookmark still opens its file but may stop: it is made again, in the store.
    func testAStaleBookmarkIsMadeAgainAndAFreshOneIsLeftAlone() throws {
        let file = try put("ship.stl")
        RecentModels.note(file, in: store)
        let first = try XCTUnwrap(kept.first)
        XCTAssertNil(RecentModels.renew(first, for: file, stale: false), "a good one is kept as it is")
        // What the store holds is replaced only by a bookmark that still leads to the file.
        let odd = Data("not the bookmark that was made".utf8)
        let fresh = try XCTUnwrap(RecentModels.renew(odd, for: file, stale: true))
        var stale = false
        let there = try URL(resolvingBookmarkData: fresh, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(there.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertFalse(stale)
        // A file that has gone cannot be bookmarked again: the old one stays.
        XCTAssertNil(RecentModels.renew(first, for: modelDir.appendingPathComponent("gone.stl"), stale: true))
        // Reading the list leaves good bookmarks exactly as they were.
        XCTAssertEqual(names, ["ship.stl"])
        XCTAssertEqual(kept, [first])
    }

    func testAFileThatIsNotThereCannotBeNoted() throws {
        RecentModels.note(try put("a.stl"), in: store)
        RecentModels.note(modelDir.appendingPathComponent("never.stl"), in: store)
        XCTAssertEqual(names, ["a.stl"])
        XCTAssertEqual(kept.count, 1)
    }

    func testWhatIsNotABookmarkIsIgnored() throws {
        store.set([Data("not a bookmark".utf8), Data()], forKey: RecentModels.key)
        XCTAssertEqual(RecentModels.urls(in: store), [])
        store.set(["a string", 7], forKey: RecentModels.key)
        XCTAssertEqual(RecentModels.urls(in: store), [])
        store.set("not a list", forKey: RecentModels.key)
        XCTAssertEqual(RecentModels.urls(in: store), [])
        // And the next file opened replaces it.
        RecentModels.note(try put("a.stl"), in: store)
        XCTAssertEqual(names, ["a.stl"])
        XCTAssertEqual(kept.count, 1)
    }

    func testClearingEmptiesTheList() throws {
        RecentModels.note(try put("a.stl"), in: store)
        RecentModels.clear(in: store)
        XCTAssertEqual(RecentModels.urls(in: store), [])
        XCTAssertNil(store.object(forKey: RecentModels.key))
        RecentModels.clear(in: store)  // nothing to clear, nothing wrong
        XCTAssertEqual(RecentModels.urls(in: store), [])
    }

    /// The store given is the only one written: another store knows nothing of it.
    func testOnlyTheGivenStoreIsWritten() throws {
        let (other, otherSuite) = try isolatedDefaults("other")
        defer { forget(otherSuite) }
        RecentModels.note(try put("a.stl"), in: store)
        XCTAssertEqual(RecentModels.urls(in: other), [])
        XCTAssertNil(other.persistentDomain(forName: otherSuite)?[RecentModels.key])
        XCTAssertNotNil(store.persistentDomain(forName: suite)?[RecentModels.key])
    }
}
