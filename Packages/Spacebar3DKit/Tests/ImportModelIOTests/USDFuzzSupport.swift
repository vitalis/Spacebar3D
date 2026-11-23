import Compression
import Darwin
import MachO
import Foundation
import XCTest
@testable import ImportModelIO

// Shared helpers for the USD fuzz and hostile-file suites (`USDCrateFuzzTests`,
// `USDHostileFileTests`): a fixed-seed generator, the Blender fixtures borrowed from
// `BlenderUSDColourTests.swift`, a tiny crate-file writer, a zip writer, and probes for time
// and memory. Nothing here touches the sources under test.

/// SplitMix64: a small, fixed-seed generator, so every run draws the same numbers.
struct FuzzGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

/// The 64-bit values most likely to break an offset or a count.
enum Nasty {
    static func values(size: Int) -> [UInt64] {
        [0, 1, 2, 7, 8, 87, 88, UInt64(size - 1), UInt64(size), UInt64(size + 1), UInt64(size) * 32 + 4096,
         UInt64(size) * 32 + 4097, 0xFFFF_FFFF, 0x1_0000_0000, 1 << 47, 1 << 48, (1 << 48) - 1, 1 << 62, 1 << 63,
         UInt64(Int64.max), UInt64(Int64.max) - 7, UInt64.max, 16_000_000, 16_000_001, 0x8000_0000, 0x7FFF_FFFF]
    }
}

// MARK: - Fixtures

/// The Blender fixtures, read from the source text of `BlenderUSDColourTests.swift` (its
/// constants are private, and that file stays as it is).
enum USDFuzzFixtures {
    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BlenderUSDColourTests.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { preconditionFailure("cannot read \(url.path)") }
        return text
    }()

    private static func base64(_ name: String) -> Data {
        guard let start = source.range(of: "private static let \(name) = Data(base64Encoded:"),
              let end = source.range(of: ")!", range: start.upperBound..<source.endIndex) else { preconditionFailure("no fixture \(name)") }
        var joined = ""
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b { joined += line[line.index(after: a)..<b] }
        }
        guard let data = Data(base64Encoded: joined) else { preconditionFailure("bad base64 in \(name)") }
        return data
    }

    private static func text(_ name: String) -> Data {
        guard let start = source.range(of: "private static let \(name) = ##\"\"\"\n"),
              let end = source.range(of: "\n\"\"\"##", range: start.upperBound..<source.endIndex) else { preconditionFailure("no fixture \(name)") }
        return Data(source[start.upperBound..<end.lowerBound].utf8)
    }

    static let crates: [(name: String, data: Data)] = [
        ("triCol", base64("triColUSDC")), ("cubePaint", base64("cubePaintUSDC")), ("triPlain", base64("triPlainUSDC")),
    ]
    static let packages: [(name: String, data: Data)] = [
        ("triCol", base64("triColUSDZ")), ("cubePaint", base64("cubePaintUSDZ")), ("triPlain", base64("triPlainUSDZ")),
    ]
    static let texts: [(name: String, data: Data)] = [
        ("triCol", text("triColUSDA")), ("cubePaint", text("cubePaintUSDA")), ("triPlain", text("triPlainUSDA")),
    ]
}

// MARK: - Byte patching

extension Data {
    mutating func put64(_ at: Int, _ v: UInt64) {
        guard at >= 0, at + 8 <= count else { return }
        for k in 0..<8 { self[startIndex + at + k] = UInt8(truncatingIfNeeded: v >> UInt64(8 * k)) }
    }
    mutating func put32(_ at: Int, _ v: UInt32) {
        guard at >= 0, at + 4 <= count else { return }
        for k in 0..<4 { self[startIndex + at + k] = UInt8(truncatingIfNeeded: v >> UInt32(8 * k)) }
    }
    mutating func put16(_ at: Int, _ v: UInt16) {
        guard at >= 0, at + 2 <= count else { return }
        self[startIndex + at] = UInt8(truncatingIfNeeded: v)
        self[startIndex + at + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    func get64(_ at: Int) -> UInt64 {
        guard at >= 0, at + 8 <= count else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + at + $1]) << UInt64(8 * $1) }
    }
    mutating func append64(_ v: UInt64) { for k in 0..<8 { append(UInt8(truncatingIfNeeded: v >> UInt64(8 * k))) } }
    mutating func append32(_ v: UInt32) { for k in 0..<4 { append(UInt8(truncatingIfNeeded: v >> UInt32(8 * k))) } }
    mutating func append16(_ v: UInt16) { append(UInt8(truncatingIfNeeded: v)); append(UInt8(truncatingIfNeeded: v >> 8)) }
}

/// Where the sections of a real crate file are (read from its table of contents).
struct CrateLayout {
    struct Section { var name: String; var entryAt: Int; var start: Int; var size: Int }
    var tocAt: Int
    var sections: [Section]

    init?(_ data: Data) {
        guard data.count >= 104 else { return nil }
        let toc = Int(truncatingIfNeeded: data.get64(16))
        guard toc >= 88, toc + 8 <= data.count else { return nil }
        tocAt = toc
        let n = Int(truncatingIfNeeded: data.get64(toc))
        guard n >= 0, n <= 64, toc + 8 + n * 32 <= data.count else { return nil }
        sections = (0..<n).map { i in
            let at = toc + 8 + i * 32
            let name = String(decoding: data[(data.startIndex + at)..<(data.startIndex + at + 16)].prefix(while: { $0 != 0 }), as: UTF8.self)
            return Section(name: name, entryAt: at, start: Int(truncatingIfNeeded: data.get64(at + 16)), size: Int(truncatingIfNeeded: data.get64(at + 24)))
        }
    }
}

// MARK: - A small crate-file writer

/// Writes a crate file the reader should accept, with every table and value word open to
/// change. The default is one mesh `/root/Tri` with three points, three corners and a
/// "vertex" colour attribute `primvars:Col` (`color4f[]`).
struct CrateBuilder {
    var minor: UInt8 = 8
    var tokens = ["typeName", "default", "interpolation", "colorSpace", "properties", "Mesh", "root", "points",
                  "faceVertexIndices", "primvars:Col", "color4f[]", "vertex", "colorSpace:name", "srgb_rec709_scene", "Tri",
                  "faceVarying", "constant"]
    var fieldTokens: [Int32] = [0, 1, 1, 1, 0, 2]
    var fieldReps: [UInt64] = []
    var fieldSets: [Int32] = [0, -1, 1, -1, 2, -1, 3, 4, 5, -1]
    var pathCount = 6
    var pathIndex: [Int32] = [0, 1, 2, 3, 4, 5]
    var elementToken: [Int32] = [0, 6, 14, -7, -8, -9]
    var jumps: [Int32] = [-1, -1, -1, 0, 0, -2]
    var specPaths: [Int32] = [2, 3, 4, 5]
    var specSets: [Int32] = [0, 2, 4, 6]
    var specTypes: [Int32] = [1, 2, 2, 2]
    /// Bytes placed straight after the header; `addBlob` returns where one starts.
    var blobs = Data()
    var padding = 0
    var skipSection: String?
    /// Replaces the text of the TOKENS section (the count word still says `tokens.count`).
    var rawTokenText: [UInt8]?
    /// Absolute offsets of the size and count words, by name (filled in by `build`).
    var marks: [String: Int] = [:]
    var pointsOffset = 0, indicesOffset = 0, coloursOffset = 0

    static func rep(array: Bool = false, inlined: Bool = false, compressed: Bool = false, edit: Bool = false, type: Int, payload: UInt64) -> UInt64 {
        (array ? 1 << 63 : 0) | (inlined ? 1 << 62 : 0) | (compressed ? 1 << 61 : 0) | (edit ? 1 << 60 : 0) | UInt64(type & 0xff) << 48 | payload & 0xffff_ffff_ffff
    }

    mutating func addBlob(_ d: Data) -> Int {
        let at = 88 + blobs.count
        blobs.append(d)
        return at
    }

    func arrayBlob(count: UInt64, body: [UInt8]) -> Data {
        var d = Data()
        if minor >= 7 { d.append64(count) } else { d.append32(UInt32(truncatingIfNeeded: count)) }
        d.append(contentsOf: body)
        return d
    }

    static func floatBytes(_ f: [Float]) -> [UInt8] { f.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v.bitPattern >> UInt32(8 * $0)) } } }
    static func intBytes(_ f: [Int32]) -> [UInt8] { f.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: v) >> UInt32(8 * $0)) } } }

    /// The default scene. `colours` is the number of colour values, `interpolation` a token index
    /// (11 "vertex", 15 "faceVarying", 16 "constant").
    init(minor: UInt8 = 8, points: Int = 3, colours: Int = 3, indices: [Int32] = [0, 1, 2], interpolation: Int32 = 11) {
        self.minor = minor
        let p: [Float] = (0..<points).flatMap { (i: Int) -> [Float] in [Float(i), Float(i % 2), 0] }
        pointsOffset = addBlob(arrayBlob(count: UInt64(points), body: Self.floatBytes(p)))
        indicesOffset = addBlob(arrayBlob(count: UInt64(indices.count), body: Self.intBytes(indices)))
        let c: [Float] = (0..<colours).flatMap { (i: Int) -> [Float] in [Float(i) / 4, 0.5, 0.25, 1] }
        coloursOffset = addBlob(arrayBlob(count: UInt64(colours), body: Self.floatBytes(c)))
        fieldReps = [
            Self.rep(inlined: true, type: 11, payload: 5),
            Self.rep(array: true, type: 24, payload: UInt64(pointsOffset)),
            Self.rep(array: true, type: 3, payload: UInt64(indicesOffset)),
            Self.rep(array: true, type: 28, payload: UInt64(coloursOffset)),
            Self.rep(inlined: true, type: 11, payload: 10),
            Self.rep(inlined: true, type: 11, payload: UInt64(interpolation)),
        ]
    }

    // LZ4 inside the wrapper the reader expects: a 0 byte, then one raw block.
    static func lz4(_ raw: [UInt8]) -> [UInt8] {
        guard !raw.isEmpty else { return [0] }
        var out = [UInt8](repeating: 0, count: raw.count + raw.count / 255 + 64)
        let n = raw.count < 64 ? 0 : compression_encode_buffer(&out, out.count, raw, raw.count, nil, COMPRESSION_LZ4_RAW)
        if n > 0 { return [0] + out[0..<n] }
        // The system encoder refuses short input: one block of literals only is valid LZ4.
        var block: [UInt8] = [0, raw.count < 15 ? UInt8(raw.count << 4) : 0xF0]
        if raw.count >= 15 {
            var rest = raw.count - 15
            while rest >= 255 { block.append(255); rest -= 255 }
            block.append(UInt8(rest))
        }
        return block + raw
    }

    /// Differences coded as the format does: the most common one, 2 bits per number, the rest.
    static func encodeIntegers(_ v: [Int32]) -> [UInt8] {
        var deltas: [Int32] = []
        var previous: Int32 = 0
        for x in v { deltas.append(x &- previous); previous = x }
        var tally: [Int32: Int] = [:]
        for d in deltas { tally[d, default: 0] += 1 }
        let common = tally.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key ?? 0
        var out = intBytes([common])
        var codes = [UInt8](repeating: 0, count: (v.count * 2 + 7) / 8)
        var rest: [UInt8] = []
        for (i, d) in deltas.enumerated() {
            var code = 0
            if d == common { code = 0 } else if d >= -128 && d <= 127 { code = 1; rest.append(UInt8(bitPattern: Int8(d))) } else if d >= -32768 && d <= 32767 {
                code = 2; rest += [UInt8(truncatingIfNeeded: d), UInt8(truncatingIfNeeded: d >> 8)]
            } else { code = 3; rest += intBytes([d]) }
            codes[i / 4] |= UInt8(code << ((i % 4) * 2))
        }
        return out + codes + rest
    }

    /// An integer list claiming `count` numbers, all zero, in a few bytes (the block unpacks to
    /// about 1/4 of a byte per number).
    static func zeroIntegers(count: Int) -> [UInt8] { [UInt8](repeating: 0, count: 4 + (count * 2 + 7) / 8) }

    private func word(_ s: inout Data, _ name: String, _ base: Int, _ v: UInt64, _ marks: inout [String: Int]) {
        marks[name] = base + s.count
        s.append64(v)
    }

    /// `ints` as the writer's own bytes, or any raw (already encoded) bytes.
    mutating func build(rawIntegers: [String: [UInt8]] = [:]) -> Data {
        var m: [String: Int] = [:]
        var file = Data("PXR-USDC".utf8)
        file.append(contentsOf: [0, minor, 0, 0, 0, 0, 0, 0])
        file.append64(0)
        file.append(Data(count: 88 - file.count))
        file.append(blobs)
        file.append(Data(count: padding))

        func block(_ s: inout Data, _ name: String, _ base: Int, _ v: [Int32], raw: [UInt8]? = nil) {
            let z = Self.lz4(raw ?? rawIntegers[name] ?? Self.encodeIntegers(v))
            word(&s, name, base, UInt64(z.count), &m)
            s.append(contentsOf: z)
        }
        var sections: [(String, Data)] = []
        func make(_ name: String, _ body: (inout Data, Int) -> Void) {
            guard skipSection != name else { return }
            var s = Data()
            body(&s, file.count)
            sections.append((name, s))
            file.append(s)
        }
        make("TOKENS") { s, base in
            let text = rawTokenText ?? Array(tokens.joined(separator: "\0").utf8) + [0]
            let z = Self.lz4(text)
            word(&s, "TOKENS.count", base, UInt64(tokens.count), &m)
            word(&s, "TOKENS.plain", base, UInt64(text.count), &m)
            word(&s, "TOKENS.packed", base, UInt64(z.count), &m)
            s.append(contentsOf: z)
        }
        make("FIELDS") { s, base in
            word(&s, "FIELDS.count", base, UInt64(fieldReps.count), &m)
            block(&s, "FIELDS.indexes", base, fieldTokens)
            let reps = fieldReps.flatMap { r in (0..<8).map { UInt8(truncatingIfNeeded: r >> UInt64(8 * $0)) } }
            let z = Self.lz4(rawIntegers["FIELDS.reps"] ?? reps)
            word(&s, "FIELDS.reps", base, UInt64(z.count), &m)
            s.append(contentsOf: z)
        }
        make("FIELDSETS") { s, base in
            word(&s, "FIELDSETS.count", base, UInt64(fieldSets.count), &m)
            block(&s, "FIELDSETS.sets", base, fieldSets)
        }
        make("PATHS") { s, base in
            word(&s, "PATHS.pathCount", base, UInt64(pathCount), &m)
            word(&s, "PATHS.encoded", base, UInt64(pathIndex.count), &m)
            block(&s, "PATHS.index", base, pathIndex)
            block(&s, "PATHS.token", base, elementToken)
            block(&s, "PATHS.jump", base, jumps)
        }
        make("SPECS") { s, base in
            word(&s, "SPECS.count", base, UInt64(specPaths.count), &m)
            block(&s, "SPECS.paths", base, specPaths)
            block(&s, "SPECS.sets", base, specSets)
            block(&s, "SPECS.types", base, specTypes)
        }
        // Table of contents.
        let tocAt = file.count
        file.put64(16, UInt64(tocAt))
        file.append64(UInt64(sections.count))
        var cursor = tocAt - sections.reduce(0) { $0 + $1.1.count }
        for (name, s) in sections {
            var nameBytes = Array(name.utf8)
            nameBytes += [UInt8](repeating: 0, count: 16 - nameBytes.count)
            file.append(contentsOf: nameBytes)
            m["TOC." + name + ".start"] = file.count
            file.append64(UInt64(cursor))
            m["TOC." + name + ".size"] = file.count
            file.append64(UInt64(s.count))
            cursor += s.count
        }
        m["TOC.count"] = tocAt
        marks = m
        return file
    }
}

// MARK: - Zip writer

/// A zip archive with stored (or, on request, labelled-deflate) entries.
struct ZipBuilder {
    struct Entry { var name: String; var payload: Data; var method: UInt16 = 0; var claimedSize: UInt32?; var alignTo = 0 }
    var entries: [Entry]
    private(set) var localAt: [Int] = []
    private(set) var directoryAt = 0
    private(set) var directoryEntryAt: [Int] = []
    private(set) var endAt = 0

    init(_ entries: [Entry]) { self.entries = entries }

    mutating func build() -> Data {
        var d = Data()
        localAt = []
        directoryEntryAt = []
        for e in entries {
            localAt.append(d.count)
            let nameLength = e.name.utf8.count
            var extra = 0
            if e.alignTo > 0 { extra = (e.alignTo - (d.count + 30 + nameLength) % e.alignTo) % e.alignTo }
            d.append32(0x0403_4b50); d.append16(10); d.append16(0); d.append16(e.method); d.append16(0); d.append16(0)
            d.append32(0); d.append32(e.claimedSize ?? UInt32(e.payload.count)); d.append32(e.claimedSize ?? UInt32(e.payload.count))
            d.append16(UInt16(nameLength)); d.append16(UInt16(extra))
            d.append(Data(e.name.utf8)); d.append(Data(count: extra)); d.append(e.payload)
        }
        directoryAt = d.count
        for (i, e) in entries.enumerated() {
            directoryEntryAt.append(d.count)
            d.append32(0x0201_4b50); d.append16(20); d.append16(10); d.append16(0); d.append16(e.method); d.append16(0); d.append16(0)
            d.append32(0); d.append32(e.claimedSize ?? UInt32(e.payload.count)); d.append32(e.claimedSize ?? UInt32(e.payload.count))
            d.append16(UInt16(e.name.utf8.count)); d.append16(0); d.append16(0); d.append16(0); d.append16(0); d.append32(0)
            d.append32(UInt32(localAt[i])); d.append(Data(e.name.utf8))
        }
        let size = d.count - directoryAt
        endAt = d.count
        d.append32(0x0605_4b50); d.append16(0); d.append16(0); d.append16(UInt16(entries.count)); d.append16(UInt16(entries.count))
        d.append32(UInt32(size)); d.append32(UInt32(directoryAt)); d.append16(0)
        return d
    }
}

// MARK: - Probes

/// Times calls and remembers the slowest; fails any single call over a second.
final class USDFuzzProbe {
    nonisolated(unsafe) static var worstSeconds = 0.0
    nonisolated(unsafe) static var worstLabel = ""
    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var noted: [(Double, String)] = []
    nonisolated(unsafe) static var notedMemory: [(Int, String)] = []
    static func note(_ seconds: Double, _ label: String) { noted.append((seconds, label)) }
    static func noteMemory(_ bytes: Int, _ label: String) { notedMemory.append((bytes, label)) }

    @discardableResult
    static func crate(_ data: Data, _ label: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) -> [String: USDColorPrimvars.Mesh]? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = USDCrateReader.meshes(from: data)
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        calls += 1
        if dt > worstSeconds { worstSeconds = dt; worstLabel = label() }
        if dt > 1 { XCTFail("took \(dt) s: \(label())", file: file, line: line) }
        return result
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ok == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Bytes the allocator holds for live blocks, all zones (what the code has asked for and not yet freed).
    static func mallocInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// Runs `body` while a thread samples the process footprint and the allocator's live bytes; returns
    /// the growth of each over its value at the start (footprint: pages touched; malloc: bytes asked for,
    /// touched or not), in bytes, and the seconds taken. `bytes` is the larger of the two.
    static func peakGrowth(_ body: () -> Void) -> (bytes: Int, footprint: Int, malloc: Int, seconds: Double) {
        final class Box: @unchecked Sendable { let lock = NSLock(); var peakFootprint = 0; var peakMalloc = 0; var stop = false }
        let box = Box()
        // Pages freed by the caller's set-up (big arrays) are still counted until the allocator hands them back.
        malloc_zone_pressure_relief(nil, 0)
        let baseFootprint = footprint(), baseMalloc = mallocInUse()
        box.peakFootprint = baseFootprint
        box.peakMalloc = baseMalloc
        let done = DispatchSemaphore(value: 0)
        let sampler = Thread {
            while true {
                let f = footprint(), m = mallocInUse()
                box.lock.lock(); box.peakFootprint = max(box.peakFootprint, f); box.peakMalloc = max(box.peakMalloc, m); let s = box.stop; box.lock.unlock()
                if s { break }
                usleep(200)
            }
            done.signal()
        }
        sampler.start()
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        box.lock.lock(); box.stop = true; box.lock.unlock()
        done.wait()
        let f = max(0, box.peakFootprint - baseFootprint), m = max(0, box.peakMalloc - baseMalloc)
        return (max(f, m), f, m, seconds)
    }
}
