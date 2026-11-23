import Foundation
import XCTest
@testable import ImportModelIO

/// Files that claim exactly the most the reader accepts, and one less, with data that really decodes to
/// that many entries (blocks of zero codes, repeated tokens, a walkable path tree), so the reader does
/// its whole job on them. The limit for a count is `min(16M, file size + 1024)`; the array budget is
/// `16 × file size + 64 KB`. For each kind (tokens, fields, field sets, paths, path arrays, specs,
/// compressed corner numbers, and the budget spent across many meshes sharing one array), at 64 KB and
/// 1 MB, the call must add at most 64 MB per MB of file (4 MB at 64 KB) and finish in a few seconds at
/// most (Debug; the target is one second in Release). The measured figures are printed as
/// `LIMIT kind ...` lines.
final class USDCrateLimitTests: XCTestCase {
    private static let sizes = [64 << 10, 1 << 20]

    // MARK: Building

    /// Integers stored as the format does, from a function, without any search for the common step:
    /// `common` is the usual difference, everything else is written out.
    private static func compact(count: Int, common: Int32, _ value: (Int) -> Int32) -> [UInt8] {
        var out = CrateBuilder.intBytes([common])
        var codes = [UInt8](repeating: 0, count: (count * 2 + 7) / 8)
        var rest: [UInt8] = []
        var previous: Int32 = 0
        for i in 0..<count {
            let v = value(i)
            let d = v &- previous
            previous = v
            if d == common { continue }
            var code = 3
            if d >= -128 && d <= 127 { code = 1; rest.append(UInt8(bitPattern: Int8(d))) } else if d >= -32768 && d <= 32767 {
                code = 2; rest += [UInt8(truncatingIfNeeded: d), UInt8(truncatingIfNeeded: d >> 8)]
            } else { rest += CrateBuilder.intBytes([d]) }
            codes[i / 4] |= UInt8(code << ((i % 4) * 2))
        }
        return out + codes + rest
    }

    private static let kinds = ["tokens", "fields", "fieldSets", "paths", "pathArrays", "specs", "corners"]

    /// A file of `target` bytes whose `kind` table claims `min(16M, target + 1024) + offset` entries and
    /// really holds them.
    private func make(_ kind: String, target requested: Int, offset: Int) -> (data: Data, claim: Int) {
        var target = requested
        for _ in 0..<3 {
            let claim = min(16_000_000, target + 1024) + offset
            var b = CrateBuilder()
            var raw: [String: [UInt8]] = [:]
            switch kind {
            case "tokens":
                var text = [UInt8](); text.reserveCapacity(claim * 2)
                for _ in 0..<claim { text.append(UInt8(ascii: "t")); text.append(0) }
                b.rawTokenText = text
            case "fields":
                raw["FIELDS.indexes"] = CrateBuilder.zeroIntegers(count: claim)
                raw["FIELDS.reps"] = [UInt8](repeating: 0, count: claim * 8)
            case "fieldSets":
                raw["FIELDSETS.sets"] = CrateBuilder.zeroIntegers(count: claim)
            case "paths":
                // Path numbers 0...N-1, the root a parent of one long run of siblings.
                b.pathCount = claim
                raw["PATHS.index"] = Self.compact(count: claim, common: 1) { Int32($0) }
                raw["PATHS.token"] = Self.compact(count: claim, common: 0) { _ in 6 }
                raw["PATHS.jump"] = Self.compact(count: claim, common: 0) { $0 == 0 ? -1 : $0 == claim - 1 ? -2 : 0 }
            case "pathArrays":
                for k in ["PATHS.index", "PATHS.token", "PATHS.jump"] { raw[k] = CrateBuilder.zeroIntegers(count: claim) }
            case "specs":
                for k in ["SPECS.paths", "SPECS.sets", "SPECS.types"] { raw[k] = CrateBuilder.zeroIntegers(count: claim) }
            case "corners":
                let block = CrateBuilder.lz4(CrateBuilder.zeroIntegers(count: claim))
                var blob = Data()
                blob.append64(UInt64(claim)); blob.append64(UInt64(block.count)); blob.append(contentsOf: block)
                b.fieldReps[2] = CrateBuilder.rep(array: true, compressed: true, type: 3, payload: UInt64(b.addBlob(blob)))
            default: preconditionFailure(kind)
            }
            b.padding = 0
            let unpadded = b.build(rawIntegers: raw).count
            if unpadded > target { target = unpadded; continue }
            b.padding = target - unpadded
            var d = b.build(rawIntegers: raw)
            let m = b.marks
            switch kind {
            case "tokens": d.put64(m["TOKENS.count"]!, UInt64(claim))
            case "fields": d.put64(m["FIELDS.count"]!, UInt64(claim))
            case "fieldSets": d.put64(m["FIELDSETS.count"]!, UInt64(claim))
            case "paths", "pathArrays": d.put64(m["PATHS.encoded"]!, UInt64(claim))
            case "specs": d.put64(m["SPECS.count"]!, UInt64(claim))
            default: break
            }
            return (d, claim)
        }
        preconditionFailure("cannot size \(kind)")
    }

    // MARK: Measuring

    private func measure(_ label: String, _ data: Data, claim: Int, ceilingBytes: Int, file: StaticString = #filePath, line: UInt = #line) -> [String: USDColorPrimvars.Mesh]? {
        var result: [String: USDColorPrimvars.Mesh]?
        let r = USDFuzzProbe.peakGrowth { result = USDCrateReader.meshes(from: data) }
        USDFuzzProbe.note(r.seconds, "limit \(label)")
        USDFuzzProbe.noteMemory(r.bytes, "limit \(label)")
        let ratio = Double(r.bytes) / Double(data.count)
        print("LIMIT \(label): file \(data.count) bytes, claim \(claim), allocated +\(String(format: "%.1f", Double(r.malloc) / 1_048_576)) MB, footprint +\(String(format: "%.1f", Double(r.footprint) / 1_048_576)) MB, \(String(format: "%.0f", ratio))x the file, \(String(format: "%.3f", r.seconds)) s, \(result == nil ? "nil" : "\(result!.count) mesh(es)")")
        XCTAssertLessThan(r.bytes, ceilingBytes, "\(label): +\(r.bytes >> 20) MB for a \(data.count)-byte file (\(Int(ratio))x), ceiling \(ceilingBytes >> 20) MB", file: file, line: line)
        // Debug code runs several times slower than Release: three seconds here stands for the one second wanted.
        XCTAssertLessThan(r.seconds, 3, "\(label): \(r.seconds) s", file: file, line: line)
        return result
    }

    private func ceiling(_ size: Int) -> Int { 64 * (1 << 20) * size / (1 << 20) }

    // MARK: Tests

    /// For tokens, fields, field sets, paths (a walkable tree of that many elements), path arrays, specs
    /// and compressed corner numbers, a file of 64 KB and of 1 MB that claims exactly the limit and one less,
    /// with real data behind the claim: at most 64 MB per MB of file, in a few seconds.
    func testTablesThatClaimExactlyTheLimitAndOneLessStayWithinTheMemoryAndTimeBounds() {
        for kind in Self.kinds {
            for size in Self.sizes {
                for offset in [0, -1] {
                    let (data, claim) = make(kind, target: size, offset: offset)
                    XCTAssertEqual(claim, min(16_000_000, data.count + 1024) + offset, "\(kind) claims the limit for its own size")
                    let result = measure("\(kind) \(size >> 10) KB limit\(offset == 0 ? "" : "\(offset)")", data, claim: claim, ceilingBytes: ceiling(size))
                    if kind == "corners" { XCTAssertEqual(result?["/root/Tri"]?.faceVertexIndices.count, claim, "the corner numbers all decode") }
                }
            }
        }
    }

    // MARK: Array budget

    /// Many meshes in one file. Every mesh uses the same points. Mesh `k` has its own colour array when
    /// `ownColours` (the colour values differ by mesh), otherwise the shared one; its corner numbers are the
    /// shared small array, or, when `cornerCount` is given, an array of its own (a compressed zero-code
    /// block of that many numbers, made different for each mesh by its step).
    private func manyMeshes(_ meshes: Int, points p: Int, ownColours: Bool = false, cornerCount: Int? = nil, sharedCorners: Bool = true, padTo: Int = 0) -> Data {
        var b = CrateBuilder(points: p, colours: p, indices: [0, 1, 2])
        b.tokens += (0..<meshes).map { "m\($0)" }
        let first = Int32(b.tokens.count - meshes)
        let n = 2 + 4 * meshes
        b.pathCount = n
        b.pathIndex = (0..<n).map { Int32($0) }
        b.elementToken = [0, 6] + (0..<meshes).flatMap { [first + Int32($0), -7, -8, -9] }
        b.jumps = [-1, -1] + (0..<meshes).flatMap { [$0 == meshes - 1 ? -1 : 4, 0, 0, -2] as [Int32] }
        b.specPaths = (0..<meshes).flatMap { k in (0..<4).map { Int32(2 + 4 * k + $0) } }
        b.specTypes = [Int32](repeating: 1, count: 4 * meshes)
        var specSets: [Int32] = []
        var firstCornerSet: Int32 = 4
        for k in 0..<meshes {
            var cornerSet: Int32 = 4, colourSet: Int32 = 6
            if let count = cornerCount, !(sharedCorners && k > 0) {
                let step = Int32(k + 1)
                let block = CrateBuilder.lz4(Self.compact(count: count, common: step) { Int32(($0 + 1)) &* step })
                var blob = Data()
                blob.append64(UInt64(count)); blob.append64(UInt64(block.count)); blob.append(contentsOf: block)
                b.fieldTokens.append(1)
                b.fieldReps.append(CrateBuilder.rep(array: true, compressed: true, type: 3, payload: UInt64(b.addBlob(blob))))
                cornerSet = Int32(b.fieldSets.count)
                b.fieldSets += [Int32(b.fieldReps.count - 1), -1]
                if k == 0 { firstCornerSet = cornerSet }
            }
            if cornerCount != nil, sharedCorners, k > 0 { cornerSet = firstCornerSet }
            if ownColours, k > 0 {
                let values: [Float] = (0..<p).flatMap { (i: Int) -> [Float] in [Float(k) / 100, Float(i % 10) / 10, 0.25, 1] }
                b.fieldTokens.append(1)
                b.fieldReps.append(CrateBuilder.rep(array: true, type: 28, payload: UInt64(b.addBlob(b.arrayBlob(count: UInt64(p), body: CrateBuilder.floatBytes(values))))))
                colourSet = Int32(b.fieldSets.count)
                b.fieldSets += [Int32(b.fieldReps.count - 1), 4, 5, -1]
            }
            specSets += [0, 2, cornerSet, colourSet]
        }
        b.specSets = specSets
        if padTo > 0 {
            b.padding = 0
            b.padding = max(0, padTo - b.build().count)
        }
        return b.build()
    }

    /// Meshes that point at the same stored points and colour arrays are decoded once, so instances cost
    /// nothing extra: 1, 3 and 10 times as many meshes as the old budget (16 × file size + 64 KB) paid for, at
    /// 64 KB and 1 MB of arrays, all come back with their colours, the memory stays near one decode (inside 64
    /// MB per MB) and the time inside the limit.
    func testMeshesSharingOneStoredArrayAreDecodedOnceAndAllKeepTheirColours() {
        for size in Self.sizes {
            let p = size / 40
            let perMeshOldCost = 32 * p + 36
            for factor in [1, 3, 10] {
                let guess = manyMeshes(1, points: p)
                let meshes = max(1, factor * ((16 * guess.count + 65536) / perMeshOldCost))
                let data = manyMeshes(meshes, points: p)
                let result = measure("shared array \(factor)x budget \(size >> 10) KB, \(meshes) meshes sharing \(p) points", data, claim: meshes, ceilingBytes: ceiling(size))
                XCTAssertEqual(result?.count, meshes, "\(factor)x \(size >> 10) KB: every instance comes back")
                for (path, mesh) in result ?? [:] {
                    XCTAssertEqual(mesh.points.count, p, path)
                    XCTAssertEqual(mesh.colours.first?.values.count, p, "\(path) keeps its colours")
                }
            }
        }
    }

    /// The guard: meshes with DISTINCT arrays (each its own compressed list of corner numbers, 12 bytes of
    /// budget a number, a different block for each) are still cut off once the budget is spent. 30 meshes ask
    /// for far more than 16 × file size + 64 KB; only as many corner lists as the budget pays for are read (the
    /// others' meshes open without corner numbers), and the memory and time stay inside the bounds.
    func testDistinctArraysBeyondTheBudgetAreStillCutOff() {
        for size in Self.sizes {
            let corners = size / 8
            let data = manyMeshes(30, points: 100, cornerCount: corners, sharedCorners: false, padTo: size)
            let budget = 16 * data.count + 65536
            let affordable = budget / (12 * corners)
            let result = measure("distinct corner lists \(size >> 10) KB, 30 meshes of \(corners) corners (budget pays for \(affordable))", data, claim: 30, ceilingBytes: ceiling(size))
            let read = (result ?? [:]).values.filter { !$0.faceVertexIndices.isEmpty }.count
            XCTAssertLessThanOrEqual(read, affordable, "\(size >> 10) KB: no more lists than the budget pays for")
            XCTAssertGreaterThanOrEqual(read, affordable - 2, "\(size >> 10) KB: the budget is used")
            XCTAssertLessThan(read, 30, "\(size >> 10) KB: the budget cuts something off")
        }
    }

    /// Two meshes that share one `faceVertexIndices` array but have different colour arrays each get their
    /// own colours (the shared decode is of the array, not of the mesh's colours).
    func testMeshesSharingCornersButNotColoursEachGetTheirOwnColours() throws {
        let data = manyMeshes(3, points: 50, ownColours: true, cornerCount: 40, sharedCorners: true)
        let result = try XCTUnwrap(USDCrateReader.meshes(from: data))
        XCTAssertEqual(result.count, 3)
        let reds = result.values.compactMap { $0.colours.first?.values.first?.x }.sorted()
        XCTAssertEqual(reds.count, 3)
        XCTAssertEqual(Set(reds).count, 3, "three different colour arrays: \(reds)")
        for mesh in result.values {
            XCTAssertEqual(mesh.faceVertexIndices.count, 40, "each has the shared corner list")
            XCTAssertEqual(mesh.colours.first?.values.count, 50)
        }
    }
}
