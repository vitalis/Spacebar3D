import Foundation

/// Files a model keeps beside itself (an OBJ's `.mtl`, images), by the name the model
/// uses for them. Importers ask here and never open such files on their own.
public protocol SidecarSource: Sendable {
    /// The file's bytes, or nil when it is not there, may not be read, or is over a limit.
    func data(named name: String) -> Data?
}

/// The folder a model file is in, read under fixed rules whatever the model says: only
/// the folder itself and the usual texture folders inside it, never through a link that
/// leads elsewhere, and within limits of size and number.
///
/// In the sandbox the folder can be read only after the user has granted it; without the
/// grant every request simply comes back empty.
public final class SidecarFolder: SidecarSource, @unchecked Sendable {
    /// Folders beside a model where its textures are commonly kept.
    public static let textureFolders = ["textures", "Textures", "images", "Images", "maps", "Maps", "tex", "source"]
    public static let maxFileBytes = 64 * 1024 * 1024
    public static let maxTotalBytes = 256 * 1024 * 1024
    public static let maxFiles = 256

    private let folder: URL
    private let root: String
    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private var total = 0

    /// The folder FBX tools unpack a file's images into: the file's name with `.fbm`.
    private let mediaFolder: String

    public init(modelURL: URL) {
        mediaFolder = modelURL.deletingPathExtension().lastPathComponent + ".fbm"
        modelFile = modelURL.resolvingSymlinksInPath()
        folder = modelFile.deletingLastPathComponent()
        root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    }

    /// The name as a model writes it, brought to a plain relative path: no drive, no
    /// scheme, forward slashes. Nil when nothing usable is left.
    public static func cleaned(_ name: String) -> String? {
        var name = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if name.count >= 2, name.first == "\"", name.last == "\"" { name = String(name.dropFirst().dropLast()) }
        if let scheme = name.range(of: "file://") { name = String(name[scheme.upperBound...]) }
        while name.hasPrefix("./") { name.removeFirst(2) }
        return name.isEmpty ? nil : name
    }

    public func data(named name: String) -> Data? {
        guard let name = Self.cleaned(name) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[name] { return known }
        guard cache.count < Self.maxFiles else { return nil }

        let last = (name as NSString).lastPathComponent
        guard !last.isEmpty, last != ".", last != ".." else { return nil }
        // As written when that is a plain relative path, then by name in the usual places.
        var candidates: [URL] = []
        if !name.hasPrefix("/"), !name.contains(":") { candidates.append(folder.appendingPathComponent(name)) }
        candidates.append(folder.appendingPathComponent(last))
        candidates += (Self.textureFolders + [mediaFolder]).map { folder.appendingPathComponent($0).appendingPathComponent(last) }

        for candidate in candidates {
            // Compare real locations: a link inside the folder must not lead out of it.
            let file = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size <= Self.maxFileBytes, total + size <= Self.maxTotalBytes,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  data.count <= Self.maxFileBytes
            else { continue }
            total += data.count
            cache[name] = data
            return data
        }
        // Not readable as it is. A file with the model's own name and another extension
        // (`ship.obj` and `ship.mtl`) is one the sandbox lets through without the folder.
        if let data = related(last) {
            total += data.count
            cache[name] = data
            return data
        }
        return nil
    }

    /// Extensions of files that may stand beside a model under its own name. The app
    /// declares the same list as related document types (`project.yml`). Quick Look's
    /// sandbox does not honour the pairing (tried 2026-11-12: the read is denied), so there
    /// such a file still needs the folder.
    public static let relatedExtensions: Set<String> = ["mtl", "bin", "png", "jpg", "jpeg", "tga", "bmp", "webp"]

    private let modelFile: URL

    /// True for a file name that is the model's own with one of the related extensions
    /// (`ship.mtl` for `ship.obj`); the pairing the sandbox goes by.
    public static func isRelated(_ name: String, toModelNamed model: String) -> Bool {
        let file = name as NSString, main = model as NSString
        let ext = file.pathExtension.lowercased()
        return relatedExtensions.contains(ext) && ext != main.pathExtension.lowercased()
            && !file.deletingPathExtension.isEmpty && file.deletingPathExtension == main.deletingPathExtension
    }

    /// A file beside the model that has the model's name and another extension, read the
    /// way the sandbox allows for such pairs: through a file coordinator that presents the
    /// model as the main item. In the app this works without the folder having been granted.
    private func related(_ last: String) -> Data? {
        guard Self.isRelated(last, toModelNamed: modelFile.lastPathComponent) else { return nil }
        let wanted = folder.appendingPathComponent(last)
        // The same rule as for any file beside the model: a link must not lead out of the folder.
        guard wanted.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { return nil }
        let presenter = RelatedFilePresenter(main: modelFile, related: wanted)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var found: Data?
        var failure: NSError?
        let limit = min(Self.maxFileBytes, Self.maxTotalBytes - total)
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: wanted, options: [.withoutChanges], error: &failure) { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let size = values.fileSize, size <= limit,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= limit
            else { return }
            found = data
        }
        return found
    }
}

/// Presents a model as the main item of a file beside it, which is what lets a sandboxed
/// process read that one file.
private final class RelatedFilePresenter: NSObject, NSFilePresenter {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    init(main: URL, related: URL) {
        primaryPresentedItemURL = main
        presentedItemURL = related
    }
}

/// An error that says a model could not be shown because files beside it could not be read.
/// The viewer then offers to ask for the model's folder.
public protocol MissingFilesReporting: Error {
    var missingFiles: [String] { get }
}

/// Sidecars held in memory, for tests and for files that arrive without a folder.
public struct SidecarFiles: SidecarSource {
    public var files: [String: Data]

    public init(_ files: [String: Data] = [:]) { self.files = files }

    public func data(named name: String) -> Data? {
        guard let name = SidecarFolder.cleaned(name) else { return nil }
        return files[name] ?? files[(name as NSString).lastPathComponent]
    }
}
