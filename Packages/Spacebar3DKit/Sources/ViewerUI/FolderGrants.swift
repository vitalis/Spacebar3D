import Foundation

/// Folders the user has allowed the app to read, so a model's separate files (an OBJ's
/// `.mtl`, images) can be shown.
///
/// The sandbox lets a process read the one file that was opened, not its neighbours. When
/// the user chooses a folder, the process that asked keeps a key to it in its own
/// container. The app's is a lasting one (a security-scoped bookmark). The Quick Look
/// extension can show the folder panel itself, but its sandbox has no lasting keys: it
/// keeps a plain bookmark, which works until the Mac restarts. For Quick Look the app also
/// leaves a plain bookmark of each of its folders in the shared container, written again
/// whenever the app starts; the extension can read that container but not write it.
public final class FolderGrants: @unchecked Sendable {
    public enum Role: Sendable {
        /// Keeps its grants, and leaves a copy of each for Quick Look.
        case app
        /// Keeps its own grants, and uses what the app has left in the shared container.
        case quickLook
    }

    /// A folder being read. Ended when the model's files have been read.
    public struct Access {
        public let folder: URL
        let started: Bool

        public func end() {
            if started { folder.stopAccessingSecurityScopedResource() }
        }
    }

    public let role: Role
    private let scopedStore: URL?
    private let sharedStore: URL?
    private let lock = NSLock()

    static let maxStoreBytes = 8 * 1024 * 1024
    static let maxFolders = 500

    /// `scopedStore` is the process's own file of lasting keys; `sharedStore` is the file
    /// in the shared container, written by the app and read by the extension.
    public init(role: Role, scopedStore: URL?, sharedStore: URL?) {
        self.role = role
        self.scopedStore = scopedStore
        self.sharedStore = sharedStore
    }

    /// The stores in their usual places: the process's own Application Support folder
    /// (inside its sandbox container) and the given shared container.
    public convenience init(role: Role, sharedContainer: URL?) {
        let own = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FolderGrants", isDirectory: true).appendingPathComponent("folders.plist")
        self.init(role: role, scopedStore: own, sharedStore: sharedContainer?.appendingPathComponent("folder-access.plist"))
    }

    // MARK: Paths

    /// A folder's real location, as the key grants are stored under.
    public static func key(for folder: URL) -> String {
        var path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The granted folder that holds `folder`: itself or the nearest one above it.
    static func covering(_ granted: some Sequence<String>, folder: String) -> String? {
        granted.filter { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }.max { $0.count < $1.count }
    }

    // MARK: Stores

    private func read(_ store: URL?) -> [String: Data] {
        guard let store,
              let size = (try? store.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxStoreBytes,
              let data = try? Data(contentsOf: store),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data]
        else { return [:] }
        return list
    }

    @discardableResult
    private func write(_ list: [String: Data], to store: URL?) -> Bool {
        guard let store, let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return false }
        do {
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: store, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The folders granted so far, by path.
    public var folders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Set(read(scopedStore).keys).union(role == .quickLook ? Set(read(sharedStore).keys) : []).sorted()
    }

    // MARK: Granting

    /// Keeps access to a folder the user has just chosen. False when it cannot be kept.
    @discardableResult
    public func grant(_ folder: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let started = folder.startAccessingSecurityScopedResource()
        defer { if started { folder.stopAccessingSecurityScopedResource() } }
        // Quick Look's sandbox cannot make a security-scoped bookmark; a plain one serves it until a restart.
        let options: URL.BookmarkCreationOptions = role == .app ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : []
        guard let scoped = try? folder.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        let key = Self.key(for: folder)
        var own = read(scopedStore)
        // A folder inside one already granted adds nothing; ones inside the new folder go.
        for known in own.keys where known != key && Self.covering([key], folder: known) != nil { own[known] = nil }
        guard own.count < Self.maxFolders || own[key] != nil else { return false }
        own[key] = scoped
        guard write(own, to: scopedStore) else { return false }
        // The copy for Quick Look is the app's to write.
        guard role == .app else { return true }

        var shared = read(sharedStore).filter { own[$0.key] != nil }
        if let plain = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { shared[key] = plain }
        write(shared, to: sharedStore)
        return true
    }

    /// Takes a folder's grant back.
    public func revoke(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        var own = read(scopedStore)
        own[path] = nil
        write(own, to: scopedStore)
        guard role == .app else { return }
        var shared = read(sharedStore)
        shared[path] = nil
        write(shared, to: sharedStore)
    }

    /// Writes the extension's bookmarks again from the app's lasting ones. Called when the
    /// app starts: the plain bookmarks stop working when the Mac restarts.
    public func refreshShared() {
        guard role == .app else { return }
        lock.lock()
        defer { lock.unlock() }
        var own = read(scopedStore), shared: [String: Data] = [:]
        var changed = false
        for (key, bookmark) in own {
            var stale = false
            guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                // The folder is gone, or the key no longer opens it.
                own[key] = nil
                changed = true
                continue
            }
            let started = folder.startAccessingSecurityScopedResource()
            if stale, let fresh = try? folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                own[key] = fresh
                changed = true
            }
            if let plain = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { shared[key] = plain }
            if started { folder.stopAccessingSecurityScopedResource() }
        }
        if changed { write(own, to: scopedStore) }
        write(shared, to: sharedStore)
    }

    // MARK: Using

    /// Opens the granted folder that holds the file, if there is one. The caller ends the
    /// access when it has read what it needs.
    public func beginAccess(forFileAt url: URL) -> Access? {
        lock.lock()
        defer { lock.unlock() }
        let folder = Self.key(for: url.resolvingSymlinksInPath().deletingLastPathComponent())
        // The process's own keys first, then (Quick Look) what the app has left.
        var stores: [(list: [String: Data], scoped: Bool)] = [(read(scopedStore), role == .app)]
        if role == .quickLook { stores.append((read(sharedStore), false)) }
        for store in stores {
            guard let key = Self.covering(store.list.keys, folder: folder), let bookmark = store.list[key] else { continue }
            var stale = false
            guard let granted = try? URL(resolvingBookmarkData: bookmark, options: store.scoped ? [.withSecurityScope] : [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            // The folder may have been moved; the key then opens another place.
            guard Self.covering([Self.key(for: granted)], folder: folder) != nil else { continue }
            return Access(folder: granted, started: granted.startAccessingSecurityScopedResource())
        }
        return nil
    }
}
