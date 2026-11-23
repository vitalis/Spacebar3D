import Compression
import Foundation
import simd

/// Reads the binary USD form (`.usdc`, "crate") for one thing: the colour attributes of its
/// meshes, which Model I/O does not hand over (see `USDColorPrimvars`). Written from the
/// published description of the format, not from any other reader's code.
///
/// The file is hostile until proven otherwise. Every offset and count is checked against the
/// file's size, sizes are added with overflow checks, the path tree is walked without recursion
/// and with a step limit, and anything wrong makes the answer `nil` (or drops that one mesh):
/// the model still opens, only without these colours.
///
/// Layout, as far as it is read: an 88-byte header (`PXR-USDC`, three version bytes, the offset of
/// a table of contents); sections named TOKENS, FIELDS, FIELDSETS, PATHS and SPECS, found through
/// that table. Tables are LZ4 blocks; lists of whole numbers are also stored as differences in
/// 2-bit-coded widths. A value is a 64-bit word: array, inlined and compressed flags, a type,
/// and a payload (the value itself, or where it is in the file).
enum USDCrateReader {
    /// Versions 0.8 (the one tried against real Blender files) up to 0.13 are read. Older ones
    /// were never tried, and 0.14 added array edits; anything newer is not known to keep the
    /// parts read here.
    static let supportedMinors = 8...13

    /// The most any table or array may claim, whatever the file's size says. (Each file also
    /// limits itself to what its own length can hold: see `Reader.countLimit`.)
    static let absoluteCountLimit = 16_000_000

    /// For every mesh prim with colour attributes, by its path ("/root/Tri/Tri"): its points,
    /// its `faceVertexIndices` and the colour attributes in the order the prim lists its
    /// properties. `nil` for a file that is not a readable crate file of a known version.
    static func meshes(from data: Data) -> [String: USDColorPrimvars.Mesh]? {
        data.withUnsafeBytes { raw -> [String: USDColorPrimvars.Mesh]? in
            guard raw.count >= 88, raw.count <= USDColorPrimvars.sizeLimit else { return nil }
            var reader = Reader(bytes: raw)
            return reader.read()
        }
    }

    // MARK: Value words

    private struct Rep {
        var word: UInt64
        var isArray: Bool { word >> 63 & 1 == 1 }
        var isInlined: Bool { word >> 62 & 1 == 1 }
        var isCompressed: Bool { word >> 61 & 1 == 1 }
        var isArrayEdit: Bool { word >> 60 & 1 == 1 }
        var type: Int { Int(word >> 48 & 0xff) }
        var payload: Int { Int(word & 0xffff_ffff_ffff) }
    }

    private enum ValueType {
        static let int = 3, token = 11, vec3f = 24, vec4f = 28, tokenVector = 41
    }

    private struct Cursor {
        var at: Int
        let end: Int
    }

    private struct PathNode {
        var parent: Int32 = -1
        var token: Int32 = 0
        var isProperty = false
        var isSet = false
        var parentIndex: Int { Int(parent) }
        var tokenIndex: Int { Int(token) }
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var size: Int { bytes.count }
        /// What any claimed count may be: one entry per byte of the file. A real file spends more
        /// than a byte on each path, spec, field, token and index, while compression could let a
        /// small file claim hundreds of times more; what a call allocates must stay in proportion
        /// to the file (at most about 64 times its size).
        var countLimit: Int
        /// The bytes all the arrays read for meshes may take together (a file can point many
        /// meshes at one array).
        var arrayBudget: Int
        /// Arrays already decoded, by the value word that says where each is stored: meshes that
        /// share a stored array (instances) share one decode, and one copy of it in memory.
        var decodedFloats: [UInt64: [SIMD4<Float>]?] = [:]
        var decodedWholeNumbers: [UInt64: [Int32]?] = [:]
        var decodedPoints: [UInt64: [SIMD3<Float>]] = [:]
        var decodedCorners: [UInt64: [Int]] = [:]
        var finiteColours: [UInt64: Bool] = [:]

        var tokens: [String] = []
        var fieldTokens: [UInt32] = []
        var fieldReps: [Rep] = []
        var fieldSets: [UInt32] = []

        init(bytes: UnsafeRawBufferPointer) {
            self.bytes = bytes
            countLimit = min(USDCrateReader.absoluteCountLimit, bytes.count + 1024)
            arrayBudget = 16 * bytes.count + 65536
        }

        // MARK: Bounds-checked reading

        func u64(_ at: Int) -> UInt64? {
            guard at >= 0, at <= size - 8 else { return nil }
            return bytes.loadUnaligned(fromByteOffset: at, as: UInt64.self)
        }

        func readU64(_ c: inout Cursor) -> Int? {
            guard c.end - c.at >= 8, let v = u64(c.at), v <= UInt64(Int32.max) * 4096 else { return nil }
            c.at += 8
            return Int(v)
        }

        func take(_ c: inout Cursor, _ count: Int) -> UnsafeRawBufferPointer? {
            guard count >= 0, count <= c.end - c.at else { return nil }
            let part = UnsafeRawBufferPointer(rebasing: bytes[c.at..<(c.at + count)])
            c.at += count
            return part
        }

        /// A section's bytes as a cursor, when it lies inside the file.
        func section(start: Int, length: Int) -> Cursor? {
            let (end, overflow) = start.addingReportingOverflow(length)
            guard start >= 88, length >= 0, !overflow, end <= size else { return nil }
            return Cursor(at: start, end: end)
        }

        // MARK: Compression

        /// An LZ4 block in the wrapper OpenUSD puts round it (a chunk count of 0, then one block),
        /// unpacked into at most `limit` bytes. Fewer is fine; more is cut and found wrong later.
        func unpack(_ block: UnsafeRawBufferPointer, limit: Int, atLeast: Int) -> [UInt8]? {
            // LZ4 stretches a block 255 times at most: a claim beyond that is refused before anything is allocated.
            guard limit > 0, limit <= 4 * USDCrateReader.absoluteCountLimit + 64, block.count >= 2, block[0] == 0,
                  atLeast <= 255 * (block.count - 1),
                  let source = block.baseAddress?.advanced(by: 1).assumingMemoryBound(to: UInt8.self) else { return nil }
            var out = [UInt8](repeating: 0, count: limit)
            let written = out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, limit, source, block.count - 1, nil, COMPRESSION_LZ4_RAW)
            }
            guard written > 0 else { return nil }
            out.removeLast(limit - written)
            return out
        }

        /// A list of `count` 32-bit whole numbers stored as differences (the most common
        /// difference, then 2 bits per number telling its width, then the other differences).
        func integers(_ c: inout Cursor, count: Int) -> [Int32]? {
            guard count >= 0, count <= countLimit, let packed = readU64(&c), let block = take(&c, packed) else { return nil }
            if count == 0 { return [] }
            let codeBytes = (count * 2 + 7) / 8
            guard let buffer = unpack(block, limit: 4 + codeBytes + count * 4, atLeast: 4 + codeBytes), buffer.count >= 4 + codeBytes else { return nil }
            func load<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T? {
                let width = MemoryLayout<T>.size
                guard at >= 0, at <= buffer.count - width else { return nil }
                return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: T.self) }
            }
            guard let common: Int32 = load(0, Int32.self) else { return nil }
            var out = [Int32](repeating: 0, count: count)
            var previous: Int32 = 0
            var next = 4 + codeBytes
            for i in 0..<count {
                let code = Int(buffer[4 + i / 4] >> UInt8((i % 4) * 2)) & 3
                let delta: Int32
                switch code {
                case 0: delta = common
                case 1: guard let v: Int8 = load(next, Int8.self) else { return nil }; delta = Int32(v); next += 1
                case 2: guard let v: Int16 = load(next, Int16.self) else { return nil }; delta = Int32(v); next += 2
                default: guard let v: Int32 = load(next, Int32.self) else { return nil }; delta = v; next += 4
                }
                previous = previous &+ delta
                out[i] = previous
            }
            return out
        }

        // MARK: The file

        mutating func read() -> [String: USDColorPrimvars.Mesh]? {
            guard bytes.prefix(8).elementsEqual("PXR-USDC".utf8), bytes[8] == 0, USDCrateReader.supportedMinors.contains(Int(bytes[9])) else { return nil }
            guard let tocAt = u64(16), tocAt >= 88, tocAt <= UInt64(size) else { return nil }
            var toc = Cursor(at: Int(tocAt), end: size)
            guard let sectionCount = readU64(&toc), sectionCount <= 64 else { return nil }
            var sections: [String: Cursor] = [:]
            for _ in 0..<sectionCount {
                guard let nameBytes = take(&toc, 16), let start = readU64(&toc), let length = readU64(&toc),
                      let cursor = section(start: start, length: length) else { return nil }
                let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                sections[name] = cursor
            }
            guard var tokenSection = sections["TOKENS"], var fieldSection = sections["FIELDS"], var setSection = sections["FIELDSETS"],
                  var pathSection = sections["PATHS"], var specSection = sections["SPECS"] else { return nil }
            guard readTokens(&tokenSection), readFields(&fieldSection), readFieldSets(&setSection),
                  let nodes = readPaths(&pathSection), let specs = readSpecs(&specSection) else { return nil }
            let result = meshes(nodes: nodes, specs: specs)
            return result.isEmpty ? nil : result
        }

        mutating func readTokens(_ c: inout Cursor) -> Bool {
            guard let count = readU64(&c), let plain = readU64(&c), let packed = readU64(&c), let block = take(&c, packed),
                  count <= countLimit, plain > 0, count <= plain, plain <= 255 * packed + 64, plain <= 16 * size + 4096,
                  let text = unpack(block, limit: plain, atLeast: plain), text.count == plain else { return false }
            var out: [String] = []
            var start = 0
            for i in 0..<text.count where text[i] == 0 {
                out.append(String(decoding: text[start..<i], as: UTF8.self))
                start = i + 1
            }
            guard out.count == count else { return false }
            tokens = out
            return true
        }

        mutating func readFields(_ c: inout Cursor) -> Bool {
            guard let count = readU64(&c), let indexes = integers(&c, count: count), let packed = readU64(&c), let block = take(&c, packed),
                  count <= countLimit, let raw = unpack(block, limit: count * 8, atLeast: count * 8), raw.count == count * 8 else { return false }
            fieldTokens = indexes.map { UInt32(bitPattern: $0) }
            fieldReps = (0..<count).map { i in
                Rep(word: raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) })
            }
            return fieldTokens.allSatisfy { Int($0) < tokens.count }
        }

        mutating func readFieldSets(_ c: inout Cursor) -> Bool {
            guard let count = readU64(&c), let sets = integers(&c, count: count) else { return false }
            fieldSets = sets.map { UInt32(bitPattern: $0) }
            return true
        }

        /// The path tree, by path number. The tree is stored as a run of elements, each with a
        /// jump that says whether a child and/or a sibling follows; it is walked here with a list of
        /// siblings still to visit, and each element is visited at most once.
        func readPaths(_ c: inout Cursor) -> [PathNode]? {
            guard let pathCount = readU64(&c), let encoded = readU64(&c), pathCount <= encoded, encoded <= countLimit,
                  let pathIndex = integers(&c, count: encoded), let elementToken = integers(&c, count: encoded),
                  let jumps = integers(&c, count: encoded) else { return nil }
            var nodes = [PathNode](repeating: PathNode(), count: pathCount)
            var pending: [(index: Int, parent: Int)] = [(0, -1)]
            var steps = 0
            while let (start, firstParent) = pending.popLast() {
                var i = start
                var parent = firstParent
                while true {
                    steps += 1
                    guard steps <= encoded, i >= 0, i < encoded else { return nil }
                    let here = i
                    i += 1
                    let number = Int(pathIndex[here])
                    guard number >= 0, number < pathCount, !nodes[number].isSet else { return nil }
                    if parent < 0 {
                        // The first element is the root.
                        guard steps == 1 else { return nil }
                        nodes[number] = PathNode(parent: -1, token: 0, isProperty: false, isSet: true)
                    } else {
                        let raw = Int(elementToken[here])
                        let token = raw.magnitude
                        guard Int(token) < tokens.count else { return nil }
                        nodes[number] = PathNode(parent: Int32(parent), token: Int32(token), isProperty: raw < 0, isSet: true)
                    }
                    let jump = Int(jumps[here])
                    let hasChild = jump > 0 || jump == -1
                    let hasSibling = jump >= 0
                    if hasChild, hasSibling {
                        let (sibling, overflow) = here.addingReportingOverflow(jump)
                        guard !overflow else { return nil }
                        pending.append((sibling, parent))
                    }
                    if hasChild { parent = number } else if !hasSibling { break }
                }
            }
            return nodes
        }

        func readSpecs(_ c: inout Cursor) -> [(path: Int32, fields: Int32)]? {
            guard let count = readU64(&c), count <= countLimit,
                  let paths = integers(&c, count: count), let sets = integers(&c, count: count),
                  integers(&c, count: count) != nil else { return nil }
            // Numbers beyond 31 bits are no index into anything: they become -1.
            return (0..<count).map { (max(-1, paths[$0]), max(-1, sets[$0])) }
        }

        // MARK: Fields and values

        /// The value word of the field called `name` in the field set starting at `start`.
        func field(_ name: Int?, in start: Int) -> Rep? {
            guard let name, start >= 0 else { return nil }
            var k = start
            // A real set has a few fields; the limit stops a set that never ends.
            while k < fieldSets.count, k - start < 256, fieldSets[k] != UInt32.max {
                let f = Int(fieldSets[k])
                if f < fieldTokens.count, Int(fieldTokens[f]) == name { return fieldReps[f] }
                k += 1
            }
            return nil
        }

        func tokenValue(_ rep: Rep?) -> String? {
            guard let rep, rep.type == ValueType.token, rep.isInlined, !rep.isArray, rep.payload < tokens.count else { return nil }
            return tokens[rep.payload]
        }

        func tokenList(_ rep: Rep?) -> [String]? {
            guard let rep, rep.type == ValueType.tokenVector, !rep.isInlined, !rep.isArray, rep.payload >= 88 else { return nil }
            var c = Cursor(at: rep.payload, end: size)
            guard let count = readU64(&c), count <= (c.end - c.at) / 4, let raw = take(&c, count * 4) else { return nil }
            var out: [String] = []
            for i in 0..<count {
                let index = Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                guard index < tokens.count else { return nil }
                out.append(tokens[index])
            }
            return out
        }

        /// Where an array's elements are, and how many.
        func arrayBody(_ rep: Rep, type: Int) -> (Cursor, Int)? {
            guard rep.isArray, !rep.isArrayEdit, rep.type == type, !rep.isInlined, rep.payload >= 88, rep.payload < size else { return nil }
            var c = Cursor(at: rep.payload, end: size)
            // Array lengths are 64-bit (since 0.7).
            guard let count = readU64(&c) else { return nil }
            guard count <= countLimit else { return nil }
            return (c, count)
        }

        mutating func floats(_ rep: Rep?, width: Int) -> [SIMD4<Float>]? {
            guard let rep, rep.isArray, !rep.isCompressed else { return nil }
            if rep.isInlined { return rep.payload == 0 && !rep.isArrayEdit ? [] : nil }
            if let known = decodedFloats[rep.word] { return known }
            let decoded = decodeFloats(rep, width: width)
            decodedFloats[rep.word] = .some(decoded)
            return decoded
        }

        private mutating func decodeFloats(_ rep: Rep, width: Int) -> [SIMD4<Float>]? {
            guard let (start, count) = arrayBody(rep, type: width == 3 ? ValueType.vec3f : ValueType.vec4f) else { return nil }
            var c = start
            let stride = width * 4
            guard count <= (c.end - c.at) / stride, count <= arrayBudget / 16, let raw = take(&c, count * stride) else { return nil }
            arrayBudget -= count * 16
            var out: [SIMD4<Float>] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                func f(_ k: Int) -> Float { Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * stride + k * 4, as: UInt32.self)) }
                out.append(SIMD4(f(0), f(1), f(2), width == 4 ? f(3) : 1))
            }
            return out
        }

        mutating func wholeNumbers(_ rep: Rep?) -> [Int32]? {
            guard let rep, rep.isArray, !rep.isArrayEdit else { return nil }
            if rep.isInlined { return rep.payload == 0 ? [] : nil }
            if let known = decodedWholeNumbers[rep.word] { return known }
            let decoded = decodeWholeNumbers(rep)
            decodedWholeNumbers[rep.word] = .some(decoded)
            return decoded
        }

        private mutating func decodeWholeNumbers(_ rep: Rep) -> [Int32]? {
            guard let (start, count) = arrayBody(rep, type: ValueType.int) else { return nil }
            var c = start
            guard count <= arrayBudget / 12 else { return nil }
            arrayBudget -= count * 12
            if rep.isCompressed { return integers(&c, count: count) }
            guard count <= (c.end - c.at) / 4, let raw = take(&c, count * 4) else { return nil }
            return (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self) }
        }

        // MARK: Meshes

        mutating func areFinite(_ values: [SIMD4<Float>], key: UInt64?) -> Bool {
            if let key, let known = finiteColours[key] { return known }
            let ok = values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }
            if let key { finiteColours[key] = ok }
            return ok
        }

        func path(of node: Int, in nodes: [PathNode]) -> String? {
            var names: [String] = []
            var at = node
            // Deeper than this is no scene (and bounds a parent loop).
            for _ in 0..<1024 {
                guard at >= 0, at < nodes.count, nodes[at].isSet else { return nil }
                if nodes[at].parentIndex < 0 { return "/" + names.reversed().joined(separator: "/") }
                names.append(tokens[nodes[at].tokenIndex])
                at = nodes[at].parentIndex
            }
            return nil
        }

        mutating func meshes(nodes: [PathNode], specs: [(path: Int32, fields: Int32)]) -> [String: USDColorPrimvars.Mesh] {
            func index(_ name: String) -> Int? { tokens.firstIndex(of: name) }
            let typeName = index("typeName"), defaultValue = index("default"), interpolation = index("interpolation")
            let colorSpace = index("colorSpace"), properties = index("properties")

            // First pass: which prims are meshes, and the colour space each prim names.
            var isMesh = Set<Int>()
            var spaceOfPrim: [Int: String] = [:]
            var listOfMesh: [Int: [String]] = [:]
            for raw in specs where Int(raw.path) < nodes.count && raw.path >= 0 && nodes[Int(raw.path)].isSet {
                let spec = (path: Int(raw.path), fields: Int(raw.fields))
                let node = nodes[spec.path]
                if !node.isProperty {
                    if tokenValue(field(typeName, in: spec.fields)) == "Mesh" {
                        isMesh.insert(spec.path)
                        if let list = tokenList(field(properties, in: spec.fields)) { listOfMesh[spec.path] = list }
                    }
                } else if tokens[node.tokenIndex] == "colorSpace:name", node.parentIndex >= 0,
                          let space = tokenValue(field(defaultValue, in: spec.fields)) {
                    spaceOfPrim[node.parentIndex] = space
                }
            }

            // Second pass: the parts of each mesh that are wanted.
            var built: [Int: USDColorPrimvars.Mesh] = [:]
            var indexLists: [Int: [String: [Int32]]] = [:]
            for raw in specs where Int(raw.path) < nodes.count && raw.path >= 0 && nodes[Int(raw.path)].isSet && nodes[Int(raw.path)].isProperty {
                let spec = (path: Int(raw.path), fields: Int(raw.fields))
                let node = nodes[spec.path]
                guard node.parentIndex >= 0, isMesh.contains(node.parentIndex) else { continue }
                let name = tokens[node.tokenIndex]
                let wanted = name == "points" || name == "faceVertexIndices" || name.hasPrefix("primvars:")
                guard wanted else { continue }
                let value = field(defaultValue, in: spec.fields)
                var mesh = built[node.parentIndex] ?? USDColorPrimvars.Mesh()
                if name == "points" {
                    if let value, let known = decodedPoints[value.word] {
                        mesh.points = known
                    } else if let raw = floats(value, width: 3), raw.count <= arrayBudget / 16 {
                        // The points are kept as `SIMD3`: a second copy, paid for once like the first.
                        arrayBudget -= raw.count * 16
                        mesh.points = raw.map { SIMD3($0.x, $0.y, $0.z) }
                        if let value { decodedPoints[value.word] = mesh.points }
                    }
                } else if name == "faceVertexIndices" {
                    if let value, let known = decodedCorners[value.word] {
                        mesh.faceVertexIndices = known
                    } else {
                        mesh.faceVertexIndices = (wholeNumbers(value) ?? []).map { Int($0) }
                        if let value { decodedCorners[value.word] = mesh.faceVertexIndices }
                    }
                } else if name.hasSuffix(":indices") {
                    let base = String(name.dropFirst("primvars:".count).dropLast(":indices".count))
                    if let list = wholeNumbers(value) { indexLists[node.parentIndex, default: [:]][base] = list }
                } else if name != "primvars:displayColor", let type = tokenValue(field(typeName, in: spec.fields)),
                          type == "color3f[]" || type == "color4f[]",
                          let values = floats(value, width: type == "color3f[]" ? 3 : 4), areFinite(values, key: value?.word) {
                    var space = tokenValue(field(colorSpace, in: spec.fields))
                    // Without its own, the nearest prim above that names one.
                    var up = node.parentIndex
                    for _ in 0..<1024 where space == nil && up >= 0 {
                        space = spaceOfPrim[up]
                        up = nodes[up].parentIndex
                    }
                    mesh.colours.append(USDColorPrimvars.Primvar(
                        name: String(name.dropFirst("primvars:".count)), typeName: type,
                        interpolation: tokenValue(field(interpolation, in: spec.fields)) ?? "constant",
                        colorSpace: space ?? "", values: values))
                }
                built[node.parentIndex] = mesh
            }

            var result: [String: USDColorPrimvars.Mesh] = [:]
            for (prim, var mesh) in built where !mesh.colours.isEmpty && !mesh.points.isEmpty {
                // Values given through an index list are spread out to what the interpolation counts.
                var kept: [USDColorPrimvars.Primvar] = []
                for var colour in mesh.colours {
                    if let list = indexLists[prim]?[colour.name] {
                        let spread = list.map { $0 >= 0 && Int($0) < colour.values.count ? colour.values[Int($0)] : nil }
                        guard spread.allSatisfy({ $0 != nil }) else { continue }
                        colour.values = spread.map { $0! }
                    }
                    kept.append(colour)
                }
                // The prim's own order of properties; the first one is the one used.
                if let order = listOfMesh[prim] {
                    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                    kept = kept.enumerated().sorted { a, b in
                        let ra = rank["primvars:" + a.element.name] ?? Int.max, rb = rank["primvars:" + b.element.name] ?? Int.max
                        return ra != rb ? ra < rb : a.offset < b.offset
                    }.map(\.element)
                }
                mesh.colours = kept
                if !kept.isEmpty, let path = path(of: prim, in: nodes) { result[path] = mesh }
            }
            return result
        }
    }
}
