import Foundation
import simd

/// The colour attributes of a USD file that Model I/O does not hand over. It gives a
/// mesh's colours only from `primvars:displayColor`; Blender writes each colour attribute
/// under its own name (`color4f[] primvars:Col`, "Paint", ...) and no `displayColor`. They are
/// read here per mesh prim path: from the text of a `.usda`, or from a binary `.usdc` (also
/// the one inside a `.usdz`) by `USDCrateReader`.
struct USDColorPrimvars {
    struct Primvar {
        var name: String
        /// "color3f[]" or "color4f[]".
        var typeName: String
        /// "vertex", "varying", "faceVarying", "uniform" or "constant"; "uniform" (per face) is not used.
        var interpolation: String
        /// The colour space the file names for it ("lin_rec709_scene", "srgb_rec709_scene", ...), or "".
        var colorSpace: String
        /// Already expanded through `primvars:NAME:indices` when the file has them (binary files).
        var values: [SIMD4<Float>]
        /// Whether the file says the numbers are already what is seen, not an amount of light.
        var isSRGB: Bool { colorSpace.lowercased().contains("srgb") }
    }

    struct Mesh {
        var points: [SIMD3<Float>] = []
        var faceVertexIndices: [Int] = []
        var colours: [Primvar] = []
    }

    /// Mesh prims by their path ("/root/Tri/Tri").
    private(set) var meshes: [String: Mesh] = [:]

    /// A file this large is not scanned for colours.
    static let sizeLimit = 256_000_000

    /// The colours of a `.usda`, `.usdc` or `.usdz` (what the file starts with says which).
    init?(url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < Self.sizeLimit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.starts(with: Data("PXR-USDC".utf8)) {
            guard let found = USDCrateReader.meshes(from: data) else { return nil }
            meshes = found
        } else if data.starts(with: Data("PK\u{3}\u{4}".utf8)) {
            // A package: the first layer in it, which must be a crate file.
            guard let layer = ZipStore(url: url)?.firstLayer(withExtension: "usdc"),
                  let found = USDCrateReader.meshes(from: layer) else { return nil }
            meshes = found
        } else if data.starts(with: Data("#usda ".utf8)) {
            scan(Array(data))
        } else {
            return nil
        }
        if meshes.isEmpty { return nil }
    }

    /// The mesh's colour at each of its `count` vertices, where the file's values can be
    /// matched to them, in sRGB. `source` is the mesh's own points, which must be the file's
    /// points (or, for an unwelded mesh, the points by corner) in order. The rule for several
    /// colour attributes: the file does not mark Blender's active or render colour, so the first
    /// one it writes is taken (Blender writes its attributes in its own order).
    func colours(forPath path: String, positions: [SIMD3<Float>]) -> [SIMD4<Float>]? {
        // The first one whose interpolation can be used.
        guard let mesh = meshes[path],
              let chosen = mesh.colours.first(where: { ["constant", "vertex", "varying", "faceVarying"].contains($0.interpolation) }) else { return nil }
        func convert(_ c: SIMD4<Float>) -> SIMD4<Float> {
            chosen.isSRGB ? c : SIMD4(USDScene.Builder.toSRGB(SIMD3(c.x, c.y, c.z)), c.w)
        }
        let corners = mesh.faceVertexIndices
        func same(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance_squared(a, b) < 1e-10 }
        switch chosen.interpolation {
        case "constant":
            guard let one = chosen.values.first else { return nil }
            return [SIMD4<Float>](repeating: convert(one), count: positions.count)
        case "vertex", "varying":
            // The mesh is in the file's point order.
            guard chosen.values.count == mesh.points.count, positions.count == mesh.points.count,
                  zip(positions, mesh.points).allSatisfy({ same($0, $1) }) else { return nil }
            return chosen.values.map(convert)
        case "faceVarying":
            guard chosen.values.count == corners.count, corners.allSatisfy({ $0 >= 0 && $0 < mesh.points.count }) else { return nil }
            if positions.count == corners.count, zip(positions, corners).allSatisfy({ same($0, mesh.points[$1]) }) {
                // Unwelded: a vertex for every corner.
                return chosen.values.map(convert)
            }
            guard positions.count == mesh.points.count, zip(positions, mesh.points).allSatisfy({ same($0, $1) }) else { return nil }
            // Welded: a point takes the mean of its corners' colours (it cannot hold several).
            var sum = [SIMD4<Float>](repeating: .zero, count: positions.count), seen = [Float](repeating: 0, count: positions.count)
            for (corner, point) in corners.enumerated() { sum[point] += chosen.values[corner]; seen[point] += 1 }
            return (0..<positions.count).map { convert(seen[$0] > 0 ? sum[$0] / seen[$0] : SIMD4(1, 1, 1, 1)) }
        default:
            return nil
        }
    }

    // MARK: Reading the text

    /// The numbers in a bracketed list, `.nan` for what is not a finite number. Read from the
    /// bytes (a list can be 10 MB long), one token at a time.
    private static func numbers(_ s: Substring) -> [Float] {
        var out: [Float] = []
        var token: [UInt8] = []
        func flush() {
            guard !token.isEmpty else { return }
            token.append(0)
            let value: Float = token.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { start in
                    var end: UnsafeMutablePointer<CChar>? = nil
                    let v = strtof(start, &end)
                    guard let end, UnsafePointer(end) == start + buffer.count - 1, v.isFinite else { return Float.nan }
                    return v
                }
            }
            out.append(value)
            token.removeAll(keepingCapacity: true)
        }
        for b in s.utf8 {
            if b == 40 || b == 41 || b == 44 || b == 32 || b == 10 || b == 9 || b == 13 { flush() } else { token.append(b) }
        }
        flush()
        return out
    }

    private mutating func scan(_ bytes: [UInt8]) {
        // Walk the braces, keeping the names of the prims that are open, and cut out each
        // Mesh prim's own text (its children's are left to them).
        var stack: [(name: String, isMesh: Bool, start: Int)] = []
        var pending: (name: String, isMesh: Bool)?
        var i = 0
        let n = bytes.count
        var statementStart = true
        // A hostile file can nest meshes inside meshes: cut the depth, and the text copied out.
        var copied = 0
        // Braces inside parentheses (a prim's metadata, `customData = { ... }`) are values, not a prim's body.
        var parentheses = 0
        func skipString(_ at: Int) -> Int {
            let q = bytes[at]
            if at + 2 < n, bytes[at + 1] == q, bytes[at + 2] == q {
                var j = at + 3
                while j + 2 < n, !(bytes[j] == q && bytes[j + 1] == q && bytes[j + 2] == q) { j += 1 }
                return min(n, j + 3)
            }
            var j = at + 1
            while j < n, bytes[j] != q { if bytes[j] == UInt8(ascii: "\\") { j += 1 }; j += 1 }
            return min(n, j + 1)
        }
        func word(_ at: Int) -> (String, Int) {
            var j = at
            while j < n, bytes[j] > 32, bytes[j] != UInt8(ascii: "\""), bytes[j] != UInt8(ascii: "{"), bytes[j] != UInt8(ascii: "("), bytes[j] != UInt8(ascii: "[") { j += 1 }
            return (String(decoding: bytes[at..<j], as: UTF8.self), j)
        }
        while i < n {
            let b = bytes[i]
            switch b {
            case UInt8(ascii: "#"):
                while i < n, bytes[i] != 10 { i += 1 }
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                i = skipString(i)
                statementStart = false
            case UInt8(ascii: "("):
                parentheses += 1
                i += 1
                statementStart = false
            case UInt8(ascii: ")"):
                parentheses = max(0, parentheses - 1)
                i += 1
                statementStart = false
            case UInt8(ascii: "{") where parentheses > 0, UInt8(ascii: "}") where parentheses > 0:
                i += 1
            case UInt8(ascii: "{"):
                if stack.count >= 1024 { return }
                if let pending { stack.append((pending.name, pending.isMesh, i + 1)) } else { stack.append(("", false, i + 1)) }
                pending = nil
                i += 1
                statementStart = true
            case UInt8(ascii: "}"):
                if let top = stack.popLast(), top.isMesh, !top.name.isEmpty, copied <= 2 * n + 1_000_000 {
                    copied += i - top.start
                    let path = "/" + (stack.map(\.name) + [top.name]).filter { !$0.isEmpty }.joined(separator: "/")
                    meshes[path] = Self.mesh(String(decoding: bytes[top.start..<i], as: UTF8.self))
                }
                i += 1
                statementStart = true
            case 10, 13:
                i += 1
                statementStart = true
            case 32, 9:
                i += 1
            default:
                if statementStart, b == UInt8(ascii: "d") || b == UInt8(ascii: "o") || b == UInt8(ascii: "c") {
                    let (first, after) = word(i)
                    if first == "def" || first == "over" || first == "class" {
                        // `def Mesh "Name"`, or `def "Name"` with no type.
                        var j = after
                        while j < n, bytes[j] == 32 || bytes[j] == 9 { j += 1 }
                        var type = ""
                        if j < n, bytes[j] != UInt8(ascii: "\"") { (type, j) = word(j); while j < n, bytes[j] == 32 || bytes[j] == 9 { j += 1 } }
                        if j < n, bytes[j] == UInt8(ascii: "\"") {
                            let end = skipString(j)
                            pending = (String(decoding: bytes[(j + 1)..<max(j + 1, end - 1)], as: UTF8.self), type == "Mesh")
                            i = end
                            statementStart = false
                            continue
                        }
                    }
                }
                statementStart = false
                i += 1
            }
        }
    }

    private static let colourPattern = try! NSRegularExpression(
        pattern: #"color([34])f\[\]\s+primvars:([A-Za-z_][A-Za-z0-9_:]*)\s*=\s*\[([^\]]*)\]\s*(?:\(([^()]*)\))?"#)
    private static let pointsPattern = try! NSRegularExpression(pattern: #"point3f\[\]\s+points\s*=\s*\[([^\]]*)\]"#)
    private static let cornersPattern = try! NSRegularExpression(pattern: #"int\[\]\s+faceVertexIndices\s*=\s*\[([^\]]*)\]"#)
    private static let spacePattern = try! NSRegularExpression(pattern: #"token\s+colorSpace:name\s*=\s*"([^"]*)""#)

    private static func mesh(_ body: String) -> Mesh {
        var mesh = Mesh()
        let whole = NSRange(body.startIndex..., in: body)
        func group(_ match: NSTextCheckingResult, _ k: Int) -> Substring? { Range(match.range(at: k), in: body).map { body[$0] } }
        if let m = pointsPattern.firstMatch(in: body, range: whole), let g = group(m, 1) {
            let v = numbers(g)
            mesh.points = stride(from: 0, to: v.count - 2, by: 3).map { SIMD3(v[$0], v[$0 + 1], v[$0 + 2]) }
        }
        if let m = cornersPattern.firstMatch(in: body, range: whole), let g = group(m, 1) {
            // A number outside the range of an index is no index (and converting it would trap).
            mesh.faceVertexIndices = numbers(g).map { $0.isFinite && abs($0) < 2_000_000_000 ? Int($0) : -1 }
        }
        let meshSpace = spacePattern.firstMatch(in: body, range: whole).flatMap { group($0, 1) }.map(String.init) ?? ""
        for m in colourPattern.matches(in: body, range: whole) {
            guard let width = group(m, 1).flatMap({ Int($0) }), let name = group(m, 2), let g = group(m, 3) else { continue }
            let meta = group(m, 4).map(String.init) ?? ""
            // Values that are indexed, or that change with time, are not read.
            if name.hasSuffix(":indices") || name == "displayColor" { continue }
            let v = numbers(g)
            guard v.count % width == 0, v.allSatisfy(\.isFinite) else { continue }
            let colours = stride(from: 0, to: v.count, by: width).map { SIMD4(v[$0], v[$0 + 1], v[$0 + 2], width == 4 ? v[$0 + 3] : 1) }
            var interpolation = "constant"
            if let r = meta.range(of: #"interpolation\s*=\s*"([A-Za-z]+)""#, options: .regularExpression) {
                interpolation = String(meta[r]).split(separator: "\"").dropFirst().first.map(String.init) ?? "constant"
            }
            // An attribute's own colour space wins over the prim's; "srgb" names mean seen colours.
            var space = meshSpace
            if let r = meta.range(of: #"colorSpace\s*=\s*"([^"]*)""#, options: .regularExpression) {
                space = String(meta[r]).split(separator: "\"").dropFirst().first.map(String.init) ?? space
            }
            mesh.colours.append(Primvar(name: String(name), typeName: "color\(width)f[]", interpolation: interpolation, colorSpace: space, values: colours))
        }
        return mesh
    }
}
