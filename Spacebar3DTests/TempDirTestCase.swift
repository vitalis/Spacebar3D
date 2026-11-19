import XCTest

/// Base class giving every test a private, unique temp tree:
///   <root>/model    - the folder the model lives in
///   <root>/outside  - a sibling folder that must never be read
/// Paths are symlink-resolved up front (/var -> /private/var on macOS) so assertions
/// compare like with like.
class TempDirTestCase: XCTestCase {
    var root: URL!
    var modelDir: URL!
    var outsideDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Spacebar3DTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        modelDir = root.appendingPathComponent("model", isDirectory: true)
        outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil; modelDir = nil; outsideDir = nil
    }

    /// Writes `bytes` to `relativePath` under `dir` (default: the model folder), creating folders.
    @discardableResult
    func put(_ relativePath: String, in dir: URL? = nil, bytes: Data = Data("x".utf8)) throws -> URL {
        let url = (dir ?? modelDir).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    /// A model file in the model folder whose text quotes each of `refs`.
    @discardableResult
    func model(_ name: String, refs: [String]) throws -> URL {
        let text = refs.map { "\"\($0)\"" }.joined(separator: "\n")
        return try put(name, bytes: Data(text.utf8))
    }

    func symlink(_ link: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// A sparse file of the given size (no disk blocks are written).
    @discardableResult
    func sparse(_ relativePath: String, in dir: URL? = nil, size: UInt64) throws -> URL {
        let url = try put(relativePath, in: dir, bytes: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }

    func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
}
