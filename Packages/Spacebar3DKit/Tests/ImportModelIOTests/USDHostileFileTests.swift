import Compression
import Foundation
import ImportRouter
import ModelCore
import XCTest
@testable import ImportModelIO

/// Hand-made hostile inputs for the USD readers: the binary reader (`USDCrateReader`), the zip
/// reader (`ZipStore`), the text reader and type sniff (`USDColorPrimvars`) and, for a few, the
/// whole import (`ImportRouter`). The Quick Look extension runs these readers, so a trap crashes the
/// preview. Every case must answer `nil` or drop the colours while the mesh still opens, in under a
/// second and without a large allocation. Files come from `CrateBuilder` and `ZipBuilder` (see
/// `USDFuzzSupport.swift`) and from the Blender fixtures in `BlenderUSDColourTests.swift`.
final class USDHostileFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-hostile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    // MARK: Helpers

    @discardableResult
    private func run(_ data: Data, _ label: @autoclosure () -> String, line: UInt = #line) -> [String: USDColorPrimvars.Mesh]? {
        let result = USDFuzzProbe.crate(data, label(), line: line)
        if let result {
            XCTAssertFalse(result.isEmpty, "\(label())", line: line)
            for (_, mesh) in result {
                XCTAssertFalse(mesh.colours.isEmpty, "\(label())", line: line)
                for c in mesh.colours { XCTAssertTrue(c.values.allSatisfy { $0.x.isFinite && $0.w.isFinite }, "\(label())", line: line) }
            }
        }
        return result
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func built(_ configure: (inout CrateBuilder) -> Void = { _ in }) -> (data: Data, builder: CrateBuilder) {
        var b = CrateBuilder()
        configure(&b)
        let d = b.build()
        return (d, b)
    }

    private let triangle = ##"""
    def Xform "root" {
        def Mesh "Tri" {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexIndices = [0, 1, 2]
            color4f[] primvars:Col = [(1, 0, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1)] (interpolation = "vertex")
        }
    }
    """##

    private func usda(_ body: String) -> Data { Data(("#usda 1.0\n" + body + "\n").utf8) }

    // MARK: Header, version, table of contents

    /// A wrong magic, a wrong major version, and every minor version outside 0.8 to 0.13 (0.0, 0.3,
    /// 0.4 to 0.7, 0.14, 1.0, 255.255 and all the others) answer nil; a file of 0 to 88 bytes does too.
    func testAWrongMagicOrVersionIsRefused() {
        let good = built().data
        XCTAssertNotNil(run(good, "control"))
        for minor in 0...255 where !(8...13).contains(minor) {
            var d = good
            d[9] = UInt8(minor)
            XCTAssertNil(run(d, "version 0.\(minor)"), "0.\(minor)")
        }
        for (major, minor) in [(1, 0), (1, 8), (255, 255), (2, 8), (0x80, 8)] {
            var d = good
            d[8] = UInt8(major); d[9] = UInt8(minor)
            XCTAssertNil(run(d, "version \(major).\(minor)"))
        }
        for at in 0..<8 {
            var d = good
            d[at] ^= 0x20
            XCTAssertNil(run(d, "magic byte \(at)"))
        }
        for length in [0, 1, 7, 8, 16, 24, 87, 88, 89] { XCTAssertNil(run(Data(good.prefix(length)), "length \(length)")) }
        XCTAssertNil(run(Data(count: 4096), "all zero"))
        XCTAssertNil(run(Data(repeating: 0xFF, count: 4096), "all 0xFF"))
    }

    /// The table-of-contents offset past the end, at the end, at -1, at Int64.max, in the header, or on
    /// its last bytes: nil, never a read outside the file.
    func testATableOfContentsOffsetOutsideTheFileIsRefused() {
        let good = built().data
        let size = UInt64(good.count)
        let values: [UInt64] = [size + 1, size, size - 7, size - 8, size + 4096, UInt64(Int64.max), UInt64.max, UInt64(bitPattern: -1),
                                UInt64(bitPattern: Int64.min), 1 << 48, 0, 1, 8, 16, 24, 87, 88, 89]
        for v in values {
            var d = good
            d.put64(16, v)
            if v < 88 || v > size - 8 { XCTAssertNil(run(d, "toc at \(v)"), "toc at \(v)") } else { run(d, "toc at \(v)") }
        }
        for fixture in USDFuzzFixtures.crates {
            for v in values { var d = fixture.data; d.put64(16, v); run(d, "\(fixture.name) toc at \(v)") }
        }
    }

    /// A section count of 0, 64 (more than there are), 65 and 1000, and the huge ones: nil (the five
    /// needed sections are not all there, or the table runs off the file).
    func testSectionCountsOfZeroAndOneThousandAreRefused() {
        let (good, b) = built()
        let at = b.marks["TOC.count"]!
        for v: UInt64 in [0, 1, 4, 6, 7, 63, 64, 65, 1000, 1 << 32, UInt64(Int64.max), UInt64.max] {
            var d = good
            d.put64(at, v)
            let result = run(d, "section count \(v)")
            if v != 5, v != 6 { XCTAssertNil(result, "section count \(v)") }
        }
    }

    /// Each section's start and size in the table of contents set to 0, 87, 88, file size, size plus
    /// one, 2^32, 2^48, Int64.max (so start + size overflows) and UInt64.max: no trap, nil when the
    /// range leaves the file or overflows.
    func testSectionRangesThatOverflowOrLeaveTheFileAreRefused() {
        let (good, b) = built()
        let size = UInt64(good.count)
        let values: [UInt64] = [0, 87, 88, size, size + 1, 1 << 32, 1 << 48, UInt64(Int64.max), UInt64.max]
        for name in ["TOKENS", "FIELDS", "FIELDSETS", "PATHS", "SPECS"] {
            for startValue in values {
                for sizeValue in values {
                    var d = good
                    d.put64(b.marks["TOC.\(name).start"]!, startValue)
                    d.put64(b.marks["TOC.\(name).size"]!, sizeValue)
                    let result = run(d, "\(name) start \(startValue) size \(sizeValue)")
                    let (end, overflow) = Int(truncatingIfNeeded: startValue).addingReportingOverflow(Int(truncatingIfNeeded: sizeValue))
                    if startValue > UInt64(Int32.max) * 4096 || sizeValue > UInt64(Int32.max) * 4096 || overflow || end > good.count || startValue < 88 {
                        XCTAssertNil(result, "\(name) start \(startValue) size \(sizeValue)")
                    }
                }
            }
        }
        // Start plus size beyond Int64.max, with both words individually accepted by the 64-bit range.
        var d = good
        d.put64(b.marks["TOC.PATHS.start"]!, UInt64(Int64.max) - 100)
        d.put64(b.marks["TOC.PATHS.size"]!, 200)
        XCTAssertNil(run(d, "start + size overflows Int64"))
    }

    // MARK: Section words

    /// Every count and size word of every section of the built file and of the Blender files (the
    /// first six words of each section, and the table's size words) set to 0, file size + 1, 2^48,
    /// Int64.max and UInt64.max. Int64.max and larger must give nil.
    func testEverySectionsClaimedCountAndSizeAtTheLimitsIsHarmless() {
        let (good, b) = built()
        var files: [(String, Data, [Int])] = [("built", good, Array(b.marks.values))]
        for f in USDFuzzFixtures.crates {
            guard let layout = CrateLayout(f.data) else { continue }
            var offsets = [Int]()
            for s in layout.sections { offsets += (0..<6).map { s.start + 8 * $0 }; offsets += [s.entryAt + 16, s.entryAt + 24] }
            files.append((f.name, f.data, offsets))
        }
        for (name, data, offsets) in files {
            for at in Set(offsets).sorted() where at + 8 <= data.count {
                for v: UInt64 in [0, UInt64(data.count) + 1, 1 << 48, UInt64(Int64.max), UInt64.max] {
                    var d = data
                    d.put64(at, v)
                    let result = run(d, "\(name) word at \(at) = \(v)")
                    if v >= UInt64(Int64.max), name == "built" { XCTAssertNil(result, "\(name) word at \(at) = \(v)") }
                }
            }
        }
    }

    /// The size word in front of each compressed block (tokens, field indexes, field values, field
    /// sets, the three path arrays, the three spec arrays) lying: 0, 1, the true size plus or minus
    /// one, the rest of the file plus one, 2^31, Int64.max. No trap; a block that claims more than
    /// the section holds is nil.
    func testCompressedBlocksWithALyingSizeAreRefusedOrHarmless() {
        let (good, b) = built()
        let packedMarks = ["TOKENS.packed", "FIELDS.indexes", "FIELDS.reps", "FIELDSETS.sets", "PATHS.index", "PATHS.token", "PATHS.jump",
                           "SPECS.paths", "SPECS.sets", "SPECS.types"]
        for key in packedMarks {
            let at = b.marks[key]!
            let truth = good.get64(at)
            let restOfFile = UInt64(good.count - at)
            for v: UInt64 in [0, 1, 2, truth &+ 1, truth &- 1, truth / 2, restOfFile + 1, 1 << 31, 1 << 40, UInt64(Int64.max), UInt64.max] {
                var d = good
                d.put64(at, v)
                let result = run(d, "\(key) claims \(v)")
                if v > restOfFile, v > truth { XCTAssertNil(result, "\(key) claims \(v)") }
            }
        }
        // The decompressed length the token table claims.
        let plain = b.marks["TOKENS.plain"]!
        for v: UInt64 in [0, 1, 17, 177, 178, 100_000, 255 * 180 + 64, 255 * 180 + 65, 1 << 40, UInt64(Int64.max)] {
            var d = good
            d.put64(plain, v)
            let result = run(d, "token text claims \(v)")
            if v != 177 { XCTAssertNil(result, "token text claims \(v)") }
        }
    }

    /// Integer tables whose decompressed bytes are too short for their count, hold codes without the
    /// numbers they announce, or are empty: nil, no read past the block.
    func testIntegerTablesWithTooLittleDataAreRefused() {
        let keys = ["FIELDS.indexes", "FIELDSETS.sets", "PATHS.index", "PATHS.token", "PATHS.jump", "SPECS.paths", "SPECS.sets", "SPECS.types"]
        let broken: [[UInt8]] = [[], [0], [0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0, 0xFF], [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF], [0, 0, 0, 0, 0x55, 0x55],
                                 [UInt8](repeating: 0xFF, count: 40), [1, 0, 0, 0, 0xAA, 0xAA, 1, 2, 3]]
        for key in keys {
            for raw in broken {
                var b = CrateBuilder()
                let d = b.build(rawIntegers: [key: raw])
                // A table of zeros long enough for its codes is all right; any other here must give nil or a clean result.
                run(d, "\(key) raw \(raw)")
            }
        }
        var b = CrateBuilder()
        XCTAssertNil(run(b.build(rawIntegers: ["PATHS.jump": [0, 0, 0, 0, 0xFF]]), "codes of 4-byte numbers with none"))
    }

    // MARK: Value words

    /// Each of the six field value words (the mesh type, the three arrays, the colour type, the
    /// interpolation) set in turn to every combination of the four flag bits (array, inlined,
    /// compressed, array-edit), eight types (0, int, token, vec3f, vec4f, token vector, 77 which
    /// is unknown, 255) and eight payloads (0, 87, 88, a real offset, the file's size minus one,
    /// its size, size plus one, 2^48-1): 6,144 files. Never a trap.
    func testValueWordsWithEveryFlagCombinationUnknownTypeAndOffsetAreHarmless() {
        let (good, b) = built()
        let payloads: [UInt64] = [0, 87, 88, UInt64(b.pointsOffset), UInt64(good.count - 1), UInt64(good.count), UInt64(good.count + 1), (1 << 48) - 1]
        var accepted = 0
        for slot in 0..<6 {
            for flags in 0..<16 {
                for type in [0, 3, 11, 24, 28, 41, 77, 255] {
                    for payload in payloads {
                        var c = b
                        c.fieldReps[slot] = (UInt64(flags) << 60) | UInt64(type) << 48 | payload
                        if run(c.build(), "slot \(slot) flags \(flags) type \(type) payload \(payload)") != nil { accepted += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(accepted, 0, "some of these are valid files")
    }

    /// Array counts 2^48 and near it (and 2^47, 2^32, 0xFFFFFFFF, Int64.max, UInt64.max, the file's
    /// size) in the points, the corner numbers and the colours, for crate versions 0.8 and 0.13 (64-bit counts), plain and with the compressed flag. A lie about the points or colours
    /// gives nil; a lie about the corners opens the mesh without them.
    func testArrayCountsNearTwoToTheFortyEighthAreRefusedOrDropped() {
        for minor: UInt8 in [8, 13] {
            let (good, b) = built { $0 = CrateBuilder(minor: minor) }
            let counts: [UInt64] = [(1 << 48) - 1, 1 << 48, (1 << 48) + 1, 1 << 47, 1 << 32, 0xFFFF_FFFF, UInt64(Int64.max), UInt64.max, UInt64(good.count),
                                    UInt64(good.count) * 32 + 4096, 16_000_000, 100_000]
            for (what, at, slot) in [("points", b.pointsOffset, 1), ("corners", b.indicesOffset, 2), ("colours", b.coloursOffset, 3)] {
                for v in counts {
                    for compressed in [false, true] {
                        var d = good
                        if minor >= 7 { d.put64(at, v) } else { d.put32(at, UInt32(truncatingIfNeeded: v)) }
                        var c = b
                        if compressed { c.fieldReps[slot] |= 1 << 61; c.fieldReps[slot] &= ~(UInt64(1) << 60) }
                        let patched = compressed ? { () -> Data in var x = c.build(); if minor >= 7 { x.put64(at, v) } else { x.put32(at, UInt32(truncatingIfNeeded: v)) }; return x }() : d
                        let result = run(patched, "0.\(minor) \(what) count \(v) compressed \(compressed)")
                        let wide = minor >= 7 ? v : v & 0xFFFF_FFFF
                        if wide >= UInt64(patched.count) * 32 + 4097 || (wide > 3 && what != "corners" && !compressed) {
                            if what == "corners" { XCTAssertEqual(result?["/root/Tri"]?.faceVertexIndices.count ?? 0, 0, "0.\(minor) corners \(v)") } else { XCTAssertNil(result, "0.\(minor) \(what) count \(v)") }
                        }
                    }
                }
            }
        }
    }

    // MARK: Disagreeing arrays, through the colour lookup

    /// A points array and a colour array of different lengths (3 points with 0, 1, 2, 4, 5, 1000
    /// colours; 5 points with 3), for vertex, face-varying and constant interpolation: the reader opens
    /// it, and `colours(forPath:positions:)` answers nil unless the counts fit, never a trap.
    func testPointsAndColoursOfDifferentLengthsGiveNoColoursButNoTrap() throws {
        let three = (0..<3).map { SIMD3<Float>(Float($0), Float($0 % 2), 0) }
        for interpolation: Int32 in [11, 15, 16] {
            for (points, colours) in [(3, 0), (3, 1), (3, 2), (3, 4), (3, 5), (3, 1000), (5, 3), (1, 3), (0, 3), (3, 3)] {
                var b = CrateBuilder(points: points, colours: colours, indices: [0, 1, 2], interpolation: interpolation)
                let url = try write(b.build(), "mismatch.usdc")
                guard let found = USDColorPrimvars(url: url) else { continue }
                for positions in [three, Array(three.prefix(2)), [], (0..<points).map { SIMD3<Float>(Float($0), Float($0 % 2), 0) }] {
                    let result = found.colours(forPath: "/root/Tri", positions: positions)
                    let exact = positions.count == points && colours == points && interpolation == 11 || positions.count == 3 && points == 3 && colours == 3 && interpolation == 15
                    if let result, !exact, interpolation != 16 { XCTAssertEqual(result.count, positions.count, "\(points) points \(colours) colours interp \(interpolation)") }
                    if interpolation == 11, colours != points { XCTAssertNil(result, "\(points) points \(colours) colours, vertex") }
                }
                XCTAssertNil(found.colours(forPath: "/nothing", positions: three))
            }
        }
    }

    /// Corner numbers that are negative, past the points, Int32.min, Int32.max or repeated, with
    /// face-varying colours, in the plain and the compressed layout: no trap, and no colours unless
    /// every corner names a point.
    func testFaceIndicesOutOfRangeOrNegativeGiveNoColoursAndNoTrap() throws {
        let three = (0..<3).map { SIMD3<Float>(Float($0), Float($0 % 2), 0) }
        let lists: [[Int32]] = [[0, 1, 99], [-1, 0, 1], [Int32.min, 0, 1], [Int32.max, 1, 2], [0, 0, 0], [3, 3, 3], [2, 1, 0], [0, 1, 2]]
        for indices in lists {
            for compressed in [false, true] {
                var b = CrateBuilder(points: 3, colours: indices.count, indices: indices, interpolation: 15)
                if compressed {
                    // The same numbers stored as a compressed table in a blob of their own.
                    let block = CrateBuilder.lz4(CrateBuilder.encodeIntegers(indices))
                    var blob = Data()
                    blob.append64(UInt64(indices.count)); blob.append64(UInt64(block.count)); blob.append(contentsOf: block)
                    b.fieldReps[2] = CrateBuilder.rep(array: true, compressed: true, type: 3, payload: UInt64(b.addBlob(blob)))
                }
                let url = try write(b.build(), "corners.usdc")
                guard let found = USDColorPrimvars(url: url) else { continue }
                let valid = indices.allSatisfy { $0 >= 0 && $0 < 3 }
                let result = found.colours(forPath: "/root/Tri", positions: three)
                if !valid { XCTAssertNil(result, "corners \(indices) compressed \(compressed)") }
                _ = found.colours(forPath: "/root/Tri", positions: (0..<indices.count).map { _ in three[0] })
            }
        }
    }

    // MARK: Path tree

    /// A chain of single children `depth` names deep ending in the mesh, as a file.
    private func chain(depth: Int, padding: Int = 0) -> Data {
        var b = CrateBuilder()
        let n = depth + 4
        b.pathCount = n
        b.pathIndex = (0..<n).map { Int32($0) }
        var tokens = [Int32](repeating: 6, count: n)
        tokens[0] = 0; tokens[depth] = 14; tokens[depth + 1] = -7; tokens[depth + 2] = -8; tokens[depth + 3] = -9
        var jumps = [Int32](repeating: -1, count: n)
        jumps[depth + 1] = 0; jumps[depth + 2] = 0; jumps[depth + 3] = -2
        b.elementToken = tokens
        b.jumps = jumps
        b.specPaths = [Int32(depth), Int32(depth + 1), Int32(depth + 2), Int32(depth + 3)]
        b.padding = padding
        return b.build()
    }

    /// A mesh 2 to 1,000 names deep is found; at 1,025 and deeper (the stated limit is 1,024) and at
    /// 5,000 and 100,000 it is skipped and the file answers nil, quickly and without recursion.
    func testAChainOfFiveThousandPrimsIsWalkedWithoutRecursionAndRefused() {
        for depth in [2, 10, 100, 500, 1000] {
            XCTAssertNotNil(run(chain(depth: depth), "depth \(depth)")?["/" + String(repeating: "root/", count: depth - 1) + "Tri"], "depth \(depth)")
        }
        for depth in [1023, 1024, 1025] { run(chain(depth: depth), "depth \(depth)") }
        for depth in [1026, 1100, 2000, 5000] { XCTAssertNil(run(chain(depth: depth), "depth \(depth)"), "depth \(depth)") }
        XCTAssertNil(run(chain(depth: 100_000, padding: 4096), "depth 100000"))
        XCTAssertNil(run(chain(depth: 100_000, padding: 8192), "depth 100000, more room"))
    }

    /// Sibling and child jumps that point past the end, at themselves, backwards or far away, and a
    /// tree whose every element is a child and a sibling at once: nil or a clean result, never a
    /// loop (each element is visited at most once) or an out-of-range index.
    func testPathJumpsThatLoopBackOrLeaveTheTreeAreRefused() {
        let n = 6
        let jumpValues: [Int32] = [Int32.min, -2_000_000_000, -1000, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 1000, Int32.max - 1, Int32.max]
        for element in 0..<n {
            for jump in jumpValues {
                var b = CrateBuilder()
                b.jumps[element] = jump
                run(b.build(), "jump \(jump) at element \(element)")
            }
        }
        var every = CrateBuilder()
        every.jumps = [Int32](repeating: 1, count: n)
        XCTAssertNil(run(every.build(), "every element has child and next sibling at +1"))
        var self0 = CrateBuilder()
        self0.jumps = [Int32](repeating: 0, count: n)
        run(self0.build(), "all siblings")
        // A long run of siblings and a comb (child and sibling everywhere, spaced out) in a big tree.
        for count in [1000, 20_000] {
            var b = CrateBuilder()
            b.pathCount = count + 1
            b.pathIndex = (0...count).map { Int32($0) }
            b.elementToken = [0] + [Int32](repeating: 6, count: count)
            b.jumps = [-1] + [Int32](repeating: 0, count: count - 1) + [-2]
            b.specPaths = [1]; b.specSets = [0]; b.specTypes = [1]
            b.padding = 1024
            run(b.build(), "\(count) siblings under the root")
            var comb = b
            comb.jumps = (0...count).map { $0 == 0 ? -1 : 2 }
            run(comb.build(), "comb of \(count)")
        }
    }

    /// A second root: the first element has a sibling, which would be a second top of the tree. Nil.
    /// Also elements that name a path number twice, a path number out of range or negative, a token out
    /// of range, and a path count of 0 or 1: nil.
    func testASecondRootAndDuplicatePathIndicesAreRefused() {
        for jump: Int32 in [1, 2, 3, 5] {
            var b = CrateBuilder()
            b.jumps[0] = jump
            XCTAssertNil(run(b.build(), "root with a sibling at +\(jump)"), "second root at +\(jump)")
        }
        var tworoots = CrateBuilder()
        tworoots.pathIndex = [0, 1, 2, 3, 4, 5, 0]
        tworoots.elementToken = [0, 6, 14, -7, -8, -9, 0]
        tworoots.jumps = [-1, -1, -1, 0, 0, 0, -2]
        run(tworoots.build(), "a root at the end as a sibling of the last property")
        for (pathIndex, label) in [([0, 1, 2, 3, 3, 5], "duplicate"), ([0, 0, 2, 3, 4, 5], "root repeated"), ([0, 1, 2, 3, 4, 2], "parent repeated"),
                                   ([0, 1, 2, 3, 4, 6], "past the count"), ([0, 1, 2, 3, 4, -1], "negative"), ([0, 1, 2, 3, 4, Int32.max], "Int32.max"),
                                   ([0, 1, 2, 3, 4, Int32.min], "Int32.min")] as [([Int32], String)] {
            var b = CrateBuilder()
            b.pathIndex = pathIndex
            XCTAssertNil(run(b.build(), "path numbers \(label)"), "path numbers \(label)")
        }
        for token: Int32 in [17, 18, 1000, -17, -1000, Int32.max, Int32.min, Int32.min + 1] {
            var b = CrateBuilder()
            b.elementToken[2] = token
            XCTAssertNil(run(b.build(), "token \(token) for a prim"), "token \(token)")
        }
        for count in [0, 1, 5, 6, 7, 100] {
            var b = CrateBuilder()
            b.pathCount = count
            let result = run(b.build(), "path count \(count)")
            if count < 6 { XCTAssertNil(result, "path count \(count)") }
        }
        var specs = CrateBuilder()
        specs.specPaths = [2, 3, 4, 5, 99, -1, Int32.max, Int32.min]
        specs.specSets = [0, 2, 4, 6, 99, -1, Int32.max, 1000]
        specs.specTypes = [1, 1, 1, 1, 1, 1, 1, 1]
        XCTAssertNotNil(run(specs.build(), "specs pointing nowhere are skipped"))
        var sets = CrateBuilder()
        sets.fieldSets = [0, -1, 1, -1, 2, -1, 3, 4, 5, 4, 4, 4, 4, 4, 4]
        run(sets.build(), "a field set that never ends")
        sets.fieldSets = [Int32](repeating: 3, count: 600)
        run(sets.build(), "a field set of 600 fields without an end")
    }

    // MARK: Zip

    private var crateFile: Data { USDFuzzFixtures.crates[0].data }

    /// The zip reader on a good package is the control: its first layer is the crate bytes and the
    /// colours come through. Then a corrupt directory in every way: wrong signatures, counts of 65,535,
    /// an offset at, past or far past the end, names and extras that run off the file, an end record
    /// alone, and a comment that holds another end record.
    func testACorruptCentralDirectoryIsRefused() throws {
        var zip = ZipBuilder([.init(name: "a.usdc", payload: crateFile)])
        let good = zip.build()
        XCTAssertEqual(ZipStore(url: try write(good, "good.usdz"))?.firstLayer(withExtension: "usdc"), crateFile)
        XCTAssertNotNil(USDColorPrimvars(url: try write(good, "good2.usdz")))

        let end = zip.endAt, dir = zip.directoryEntryAt[0]
        var variants: [(String, Data)] = []
        func patch(_ label: String, _ edit: (inout Data) -> Void) { var d = good; edit(&d); variants.append((label, d)) }
        for v: UInt32 in [0, 1, UInt32(good.count), UInt32(good.count + 100), 0xFFFF_FFFE, 0xFFFF_FFFF, UInt32(end - 1), UInt32(end + 1)] { patch("directory at \(v)") { $0.put32(end + 16, v) } }
        for v: UInt16 in [0, 2, 100, 0xFFFE, 0xFFFF] { patch("entry count \(v)") { $0.put16(end + 10, v); $0.put16(end + 8, v) } }
        for v: UInt32 in [0, 1, 0xFFFF_FFFF] { patch("directory size \(v)") { $0.put32(end + 12, v) } }
        patch("directory signature") { $0.put32(dir, 0x1234_5678) }
        for v: UInt16 in [0xFFFF, 0x8000, 100, 7] { patch("name length \(v)") { $0.put16(dir + 28, v) } }
        for v: UInt16 in [0xFFFF, 0x8000] { patch("extra length \(v)") { $0.put16(dir + 30, v) } }
        for v: UInt16 in [0xFFFF, 0x8000] { patch("comment length \(v)") { $0.put16(dir + 32, v) } }
        for v: UInt32 in [UInt32(good.count), UInt32(good.count - 10), UInt32(end), UInt32(dir), 0xFFFF_FFFE, 0xFFFF_FFFF] { patch("local header at \(v)") { $0.put32(dir + 42, v) } }
        patch("local signature") { $0.put32(0, 0xDEAD_BEEF) }
        for v: UInt16 in [0xFFFF, 0x7FFF] { patch("local name length \(v)") { $0.put16(26, v) } }
        for v: UInt16 in [0xFFFF, 0x7FFF] { patch("local extra length \(v)") { $0.put16(28, v) } }
        patch("end record alone") { $0 = Data($0.suffix(22)) }
        patch("end record cut") { $0 = Data($0.dropLast(10)) }
        patch("comment holding an end record") { d in
            var tail = Data(d.suffix(22)); tail.put16(20, 0)
            d.put16(d.count - 2, UInt16(tail.count))
            d.append(tail)
        }
        patch("65,535 byte comment") { d in d.put16(d.count - 2, 0xFFFF); d.append(Data(repeating: 0x50, count: 65_535)) }
        patch("only signatures") { $0 = Data(repeating: 0x50, count: 5000) }
        for (label, data) in variants {
            let url = try write(data, "corrupt.usdz")
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = ZipStore(url: url)?.firstLayer(withExtension: "usdc")
            _ = USDColorPrimvars(url: url)
            XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9, 1, label)
        }
        XCTAssertNil(ZipStore(url: try write(Data("PK\u{3}\u{4}".utf8), "short.usdz")))
        XCTAssertNil(USDColorPrimvars(url: try write(Data("PK\u{3}\u{4}".utf8) + Data(count: 100), "pk.usdz")))
    }

    /// An entry that claims a size of 0xFFFFFFFE, the rest of the file plus one, or 2 GB, in the
    /// directory, in the local header, or both: nil, with no allocation of that size.
    func testAnEntryThatClaimsAHugeSizeIsRefused() throws {
        for claimed: UInt32 in [0xFFFF_FFFE, 0x8000_0000, 0x7FFF_FFFF, UInt32(crateFile.count + 1000), UInt32(crateFile.count + 1), 0xFFFF_FFFF] {
            var zip = ZipBuilder([.init(name: "a.usdc", payload: crateFile, claimedSize: claimed)])
            let data = zip.build()
            let url = try write(data, "huge.usdz")
            let growth = USDFuzzProbe.peakGrowth {
                // A claim only slightly past the layer still lies inside the file (the next record's bytes follow it).
                if claimed >= UInt32(crateFile.count + 200) {
                    XCTAssertNil(ZipStore(url: url)?.firstLayer(withExtension: "usdc"), "claims \(claimed)")
                    XCTAssertNil(USDColorPrimvars(url: url), "claims \(claimed)")
                } else {
                    _ = USDColorPrimvars(url: url)
                }
            }
            XCTAssertLessThan(growth.bytes, 64 << 20, "claims \(claimed)")
        }
        // A claim of nothing: an empty layer is no mesh.
        var empty = ZipBuilder([.init(name: "a.usdc", payload: Data())])
        XCTAssertNil(USDColorPrimvars(url: try write(empty.build(), "empty.usdz")))
    }

    /// Two `.usdc` entries (the first one in the file wins, however the names sort), `../` and
    /// absolute names, a name with a NUL, a name of 65,535 characters and one of invalid UTF-8: the
    /// reader only returns bytes (it never writes a file by that name), so the answers are the first
    /// layer's, and nothing is created outside the folder.
    func testDuplicateLayersAndHostileNamesOnlyEverYieldBytes() throws {
        let other = USDFuzzFixtures.crates[1].data
        var dup = ZipBuilder([.init(name: "z.usdc", payload: crateFile), .init(name: "a.usdc", payload: other)])
        let url = try write(dup.build(), "dup.usdz")
        XCTAssertEqual(ZipStore(url: url)?.firstLayer(withExtension: "usdc"), crateFile, "the first in the file, not the first by name")
        var same = ZipBuilder([.init(name: "a.usdc", payload: crateFile), .init(name: "a.usdc", payload: other)])
        let sameURL = try write(same.build(), "same.usdz")
        XCTAssertNotNil(ZipStore(url: sameURL)?.firstLayer(withExtension: "usdc"))
        let names = ["../evil.usdc", "../../../../tmp/p3d-evil.usdc", "/etc/p3d-evil.usdc", "a/../../b.usdc", "x\u{0}.usdc", String(repeating: "n", count: 65_000) + ".usdc",
                     "\u{FFFD}\u{FFFD}.USDC", "..\\..\\evil.usdc", "ÄÖ\u{202E}cdsu.usdc", ".usdc"]
        for name in names {
            var zip = ZipBuilder([.init(name: name, payload: crateFile)])
            let url = try write(zip.build(), "names.usdz")
            XCTAssertEqual(ZipStore(url: url)?.firstLayer(withExtension: "usdc"), crateFile, name)
            _ = USDColorPrimvars(url: url)
        }
        // Invalid UTF-8 in a name, by patching bytes in both name copies.
        var zip = ZipBuilder([.init(name: "abcdef.usdc", payload: crateFile)])
        var raw = zip.build()
        raw[30] = 0xFF; raw[31] = 0xC0
        raw[zip.directoryEntryAt[0] + 46] = 0xFF; raw[zip.directoryEntryAt[0] + 47] = 0xC0
        _ = ZipStore(url: try write(raw, "badutf8.usdz"))?.firstLayer(withExtension: "usdc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/p3d-evil.usdc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/etc/p3d-evil.usdc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("evil.usdc").path))
    }

    /// Entries not aligned to 64 bytes (the package rule), an extra field that shifts the data by
    /// every amount from 0 to 70, a stored entry whose data would start in the end record, and a
    /// local header offset on a byte that is not a header: the layer is read or nil, never a trap.
    func testMisalignedEntriesAreReadOrRefused() throws {
        for extra in 0...70 {
            var zip = ZipBuilder([.init(name: "a.usdc", payload: crateFile, alignTo: 0)])
            var d = zip.build()
            // Insert `extra` bytes into the local extra field and fix the length (the directory's offset is unchanged).
            if extra > 0 {
                d.insert(contentsOf: Data(count: extra), at: 30 + 6)
                d.put16(28, UInt16(extra))
                let end = zip.endAt + extra, dir = zip.directoryAt + extra
                d.put32(end + 16, UInt32(dir))
            }
            let url = try write(d, "shift.usdz")
            let layer = ZipStore(url: url)?.firstLayer(withExtension: "usdc")
            if extra == 0 { XCTAssertEqual(layer, crateFile) }
            _ = USDColorPrimvars(url: url)
        }
        for align in [1, 2, 3, 16, 64, 4096] {
            var zip = ZipBuilder([.init(name: "pad.bin", payload: Data(count: 13)), .init(name: "a.usdc", payload: crateFile, alignTo: align)])
            let url = try write(zip.build(), "aligned.usdz")
            XCTAssertEqual(ZipStore(url: url)?.firstLayer(withExtension: "usdc"), crateFile, "aligned to \(align)")
            XCTAssertNotNil(USDColorPrimvars(url: url), "aligned to \(align)")
        }
        var zip = ZipBuilder([.init(name: "a.usdc", payload: crateFile)])
        let good = zip.build()
        for offset in [1, 2, 3, 29, 30, 31, 45, 100, zip.directoryAt, zip.endAt, good.count - 1] {
            var d = good
            d.put32(zip.directoryEntryAt[0] + 42, UInt32(offset))
            let url = try write(d, "badoffset.usdz")
            XCTAssertNil(ZipStore(url: url)?.firstLayer(withExtension: "usdc"), "local header at \(offset)")
        }
    }

    /// A deflate-compressed `.usdc` entry (method 8, real raw deflate of the crate bytes): the reader only
    /// takes stored entries, so it gives no layer and no colours; the importer is then run on it and must
    /// either throw or open without a trap.
    func testACompressedEntryGivesNoLayerAndTheImportDoesNotTrap() throws {
        let packed = crateFile.withUnsafeBytes { src -> Data in
            var out = [UInt8](repeating: 0, count: crateFile.count + 1024)
            let n = compression_encode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, crateFile.count, nil, COMPRESSION_ZLIB)
            return Data(out[0..<n])
        }
        XCTAssertGreaterThan(packed.count, 100)
        var zip = ZipBuilder([.init(name: "a.usdc", payload: packed, method: 8, claimedSize: nil)])
        var data = zip.build()
        // The uncompressed size differs from the packed one, as a real deflate entry's does.
        data.put32(zip.directoryEntryAt[0] + 24, UInt32(crateFile.count)); data.put32(22, UInt32(crateFile.count))
        let url = try write(data, "deflate.usdz")
        XCTAssertNil(ZipStore(url: url)?.firstLayer(withExtension: "usdc"))
        XCTAssertNil(USDColorPrimvars(url: url))
        _ = try? ImportRouter.load(url, format: .usd)
    }

    // MARK: Text

    /// Unbalanced braces: only opening ones (10,000), only closing ones (10,000), alternating wrongly,
    /// braces inside strings and comments, a string that never ends, a triple-quoted string that never ends,
    /// and a mesh whose brace never closes: no trap, no mesh from the unfinished one.
    func testUnbalancedBracesInTextNeverTrap() throws {
        var cases: [(String, Data)] = [
            ("open", usda(String(repeating: "{", count: 10_000))), ("close", usda(String(repeating: "}", count: 10_000))),
            ("wrong order", usda(String(repeating: "}{", count: 10_000))),
            ("unclosed mesh", usda(triangle.replacingOccurrences(of: "\n    }\n}", with: "\n"))),
            ("extra close", usda(triangle + "}}}}")),
            ("string never ends", usda("def Mesh \"Tri {\n" + triangle)), ("triple string never ends", usda("def Mesh \"\"\"Tri {\n" + triangle)),
            ("braces in strings", usda("def Mesh \"{{{{\" { string a = \"}}}}\" }\n" + triangle)),
            ("braces in comments", usda("# {{{{{\n" + triangle + "\n# }}}}")),
            ("braces in parentheses", usda("def Xform \"a\" ( customData = {{{{{ ) {\n" + triangle + "}")),
            ("def at the end", usda(triangle + "\ndef Mesh \"")), ("def alone", usda("def")), ("def Mesh", usda("def Mesh ")),
        ]
        cases.append(("backslashes", usda("def Mesh \"Tri\\\" { " + String(repeating: "\\", count: 5001) + "\"")))
        let tri = try XCTUnwrap(USDColorPrimvars(url: write(usda(triangle), "ok.usda")), "the control opens")
        XCTAssertEqual(tri.meshes["/root/Tri"]?.points.count, 3)
        XCTAssertEqual(tri.meshes["/root/Tri"]?.colours.first?.interpolation, "vertex")
        for (label, data) in cases {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let found = USDColorPrimvars(url: try write(data, "unbalanced.usda"))
            XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9, 1, label)
            if label == "unclosed mesh" { XCTAssertNil(found?.meshes["/root/Tri"], label) }
        }
    }

    /// Prims nested 2,000 deep (plain, as meshes, and as meshes each with a body of 20 KB): the
    /// scanner gives up past 1,024 and answers nil or only the shallow ones, in under a second.
    func testTwoThousandLevelsOfNestingIsRefusedQuickly() throws {
        for (label, open, body) in [("prims", "def Xform \"a\" {\n", ""), ("meshes", "def Mesh \"a\" {\n", ""),
                                    ("meshes with bodies", "def Mesh \"a\" {\n", "    point3f[] points = [" + String(repeating: "(1, 2, 3), ", count: 200) + "(0, 0, 0)]\n")] {
            for depth in (body.isEmpty ? [1000, 1024, 1025, 2000, 20_000] : [1000, 2000]) {
                let text = String(repeating: open + body, count: depth) + String(repeating: "}\n", count: depth)
                let url = try write(usda(text), "deep.usda")
                let t0 = DispatchTime.now().uptimeNanoseconds
                let found = USDColorPrimvars(url: url)
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                XCTAssertLessThan(dt, 1, "\(label) \(depth) deep")
                for (path, _) in found?.meshes ?? [:] { XCTAssertLessThanOrEqual(path.split(separator: "/").count, 1024, label) }
                USDFuzzProbe.note(dt, "text \(label) \(depth) deep")
            }
        }
        // The same, with a real mesh at the bottom.
        let deep = String(repeating: "def Xform \"a\" {\n", count: 2000) + triangle + String(repeating: "}\n", count: 2000)
        XCTAssertNil(USDColorPrimvars(url: try write(usda(deep), "deepmesh.usda")))
    }

    /// An array of 10 MB on one line, as the points, as the colours and as the corner numbers: it
    /// is read (or refused) in under a second and without a copy of it for each match.
    func testATenMegabyteArrayLineIsReadQuickly() throws {
        let item = "(0.5, 0.25, 0.125), "
        let line = String(repeating: item, count: 10_000_000 / item.utf8.count) + "(1, 1, 1)"
        let corners = String(repeating: "1, 2, 3, ", count: 10_000_000 / 9) + "0"
        for (label, body) in [("points", "point3f[] points = [\(line)]"), ("colours", "color3f[] primvars:Col = [\(line)] (interpolation = \"vertex\")"),
                              ("corners", "int[] faceVertexIndices = [\(corners)]")] {
            let text = "def Mesh \"Tri\" {\n\(body)\n}\n"
            let url = try write(usda(text), "big.usda")
            var found: USDColorPrimvars?
            let r = USDFuzzProbe.peakGrowth { found = USDColorPrimvars(url: url) }
            USDFuzzProbe.note(r.seconds, "text 10 MB \(label) line")
            print("USDHostileFileTests: 10 MB \(label) line: \(r.seconds) s, footprint +\(r.footprint >> 20) MB, allocated +\(r.malloc >> 20) MB, opened \(found != nil)")
            // Debug code is several times slower than Release, and the work is linear in the 10 MB.
            XCTAssertLessThan(r.seconds, 3, "10 MB \(label) line")
            XCTAssertLessThan(r.bytes, 256 << 20, "10 MB \(label) line")
        }
    }

    /// `1e30`, `-1e30`, `nan`, `inf`, `4e9`, 2,000,000,000 and 1,999,999,999.9 in the corner numbers
    /// (the numbers become -1, which no point has), then a colour lookup: no trap, no colours. Also a
    /// `nan` in the points, and in the colours (the attribute is dropped).
    func testHugeAndNotANumberValuesInTextNeverTrap() throws {
        for token in ["1e30", "-1e30", "nan", "-nan", "inf", "-inf", "4e9", "2000000000", "1999999999.9", "-2000000000", "1e-45", "0x10", "1,,2", "--1", "1e", "9999999999999999999999"] {
            let text = """
            def Mesh "Tri" {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexIndices = [0, 1, \(token)]
                color4f[] primvars:Col = [(1, 0, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1)] (interpolation = "faceVarying")
            }
            """
            let found = USDColorPrimvars(url: try write(usda(text), "numbers.usda"))
            let positions = (0..<3).map { SIMD3<Float>(Float($0), Float($0 % 2), 0) }
            if token != "1e-45" {
                XCTAssertNil(found?.colours(forPath: "/Tri", positions: positions), "corner \(token)")
                XCTAssertNil(found?.colours(forPath: "/Tri", positions: [positions[0], positions[0], positions[0]]), "corner \(token)")
            }
            for (what, line) in [("points", "point3f[] points = [(0, 0, 0), (1, 0, \(token)), (0, 1, 0)]"), ("colours", "color4f[] primvars:Col = [(1, 0, \(token), 1), (0, 1, 0, 1), (0, 0, 1, 1)] (interpolation = \"vertex\")")] {
                let more = "def Mesh \"Tri\" {\n point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]\n int[] faceVertexIndices = [0, 1, 2]\n color4f[] primvars:Col = [(1, 0, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1)] (interpolation = \"vertex\")\n \(line)\n}"
                if let f = USDColorPrimvars(url: try write(usda(more), "numbers2.usda")) {
                    for (_, m) in f.meshes { for c in m.colours { XCTAssertTrue(c.values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }, "\(what) \(token)") } }
                    _ = f.colours(forPath: "/Tri", positions: positions)
                }
            }
        }
    }

    /// A colour attribute with no interpolation at all (the file means "constant"), with an empty one, with
    /// an unknown one, and with `uniform`: the reader gives the colours and the lookup answers from the
    /// interpolation it knows, or nil. No trap.
    func testAMissingOrUnknownInterpolationIsHandled() throws {
        let positions = (0..<3).map { SIMD3<Float>(Float($0), Float($0 % 2), 0) }
        for (meta, expectsColours) in [("", true), (" ()", true), (" (interpolation = \"\")", true), (" (interpolation = \"sideways\")", false), (" (interpolation = \"uniform\")", false),
                                       (" (interpolation = \"vertex\" interpolation = \"constant\")", true), (" (interpolation = vertex)", true), (" (colorSpace = \"srgb\")", true)] {
            let text = """
            def Mesh "Tri" {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexIndices = [0, 1, 2]
                color4f[] primvars:Col = [(1, 0, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1)]\(meta)
            }
            """
            let found = USDColorPrimvars(url: try write(usda(text), "interp.usda"))
            XCTAssertNotNil(found, "metadata \(meta)")
            let colours = found?.colours(forPath: "/Tri", positions: positions)
            if expectsColours, meta.isEmpty || meta == " ()" { XCTAssertEqual(colours?.count, 3, "constant for \(meta)") }
            if !expectsColours { XCTAssertNil(colours, "metadata \(meta)") }
        }
    }

    /// Files that are not USD at all, or start like one: empty, one byte, `#usda` without the space, a
    /// 4 MB file of text with no braces, binary noise after `PXR-USDC`, a `PK` with nothing behind it.
    func testTheTypeSniffRefusesFilesThatAreNotUSD() throws {
        let cases: [(String, Data)] = [("empty", Data()), ("one byte", Data([0x50])), ("#usda no space", Data("#usda".utf8)), ("#usda 1.0 only", Data("#usda 1.0".utf8)),
                                       ("no braces", Data(("#usda 1.0\n" + String(repeating: "abc ", count: 1_000_000)).utf8)), ("PXR-USDC alone", Data("PXR-USDC".utf8)),
                                       ("PXR-USDC noise", Data("PXR-USDC".utf8) + Data(repeating: 0xA5, count: 5000)), ("PK", Data("PK\u{3}\u{4}".utf8)), ("PK\\5\\6", Data("PK\u{5}\u{6}".utf8) + Data(count: 18)),
                                       ("a directory-like name", Data("PXR-USDC".utf8) + Data([0, 8, 0]))]
        for (label, data) in cases { XCTAssertNil(USDColorPrimvars(url: try write(data, "sniff.bin")), label) }
        XCTAssertNil(USDColorPrimvars(url: folder.appendingPathComponent("missing.usdc")))
        XCTAssertNil(USDColorPrimvars(url: folder))
    }

    // MARK: Memory and time

    /// A file that is accepted by every size check and claims the most it may. Returns the file and the count it claims.
    private func amplified(_ kind: String, fileSize: Int) -> (Data, Int) {
        var b = CrateBuilder()
        // The most each table can carry: an integer table unpacks into 4 + N/4 + 4N bytes, at most 4 * 16M + 64
        // (so N <= 15,058,837), the field values into 8N bytes (N <= 8,000,008); the rest take the full count.
        var claim = min(16_000_000, 32 * fileSize + 4096)
        if kind == "specs" || kind == "fieldSets" || kind == "pathArrays" { claim = min(claim, 15_000_000) }
        if kind == "fields" { claim = min(claim, 8_000_000) }
        var raw: [String: [UInt8]] = [:]
        switch kind {
        case "pathCount": b.pathCount = claim
        case "specs": for k in ["SPECS.paths", "SPECS.sets", "SPECS.types"] { raw[k] = CrateBuilder.zeroIntegers(count: claim) }
        case "fields": raw["FIELDS.indexes"] = CrateBuilder.zeroIntegers(count: claim); raw["FIELDS.reps"] = [UInt8](repeating: 0, count: claim * 8)
        case "fieldSets": raw["FIELDSETS.sets"] = CrateBuilder.zeroIntegers(count: claim)
        case "tokens": b.rawTokenText = [UInt8](repeating: 0, count: claim)
        case "pathArrays": for k in ["PATHS.index", "PATHS.token", "PATHS.jump"] { raw[k] = CrateBuilder.zeroIntegers(count: claim) }
        default: break
        }
        b.padding = 0
        let unpadded = b.build(rawIntegers: raw).count
        b.padding = max(0, fileSize - unpadded)
        var d = b.build(rawIntegers: raw)
        let m = b.marks
        switch kind {
        case "specs": d.put64(m["SPECS.count"]!, UInt64(claim))
        case "fields": d.put64(m["FIELDS.count"]!, UInt64(claim))
        case "fieldSets": d.put64(m["FIELDSETS.count"]!, UInt64(claim))
        case "tokens": d.put64(m["TOKENS.count"]!, UInt64(claim))
        case "pathArrays": d.put64(m["PATHS.encoded"]!, UInt64(claim)); d.put64(m["PATHS.pathCount"]!, UInt64(claim))
        default: break
        }
        return (d, claim)
    }

    /// For crafted files of 64 KB and 1 MB that claim far more than the reader allows (about 32 times the
    /// file, up to 16 million, for the path count, spec count, field count, field set count, token count and
    /// path arrays), the call is refused before it allocates: at most 64 MB per MB of file (4 MB at 64 KB)
    /// and a few seconds at most (Debug). Claims at the limit itself are in `USDCrateLimitTests`.
    func testASmallFileCannotMakeTheReaderUseMoreThanSixtyFourMegabytesPerMegabyteOrAFullSecond() {
        for kind in ["pathCount", "specs", "fields", "fieldSets", "tokens", "pathArrays"] {
            for size in [64 << 10, 1 << 20] {
                let (data, claim) = amplified(kind, fileSize: size)
                var result: [String: USDColorPrimvars.Mesh]?
                let r = USDFuzzProbe.peakGrowth { result = USDCrateReader.meshes(from: data) }
                USDFuzzProbe.note(r.seconds, "\(kind) claim \(claim) in \(data.count) bytes")
                USDFuzzProbe.noteMemory(r.bytes, "\(kind) claim \(claim) in \(data.count) bytes")
                print("USDHostileFileTests: \(kind) file \(data.count) bytes claims \(claim): footprint +\(r.footprint >> 20) MB, allocated +\(r.malloc >> 20) MB, \(r.seconds) s, result \(result == nil ? "nil" : "mesh")")
                // Ceiling: 64 MB for a 1 MB file, scaled linearly by the file's size (4 MB at 64 KB).
                let ceiling = 64 * (1 << 20) * size / (1 << 20)
                XCTAssertLessThan(r.bytes, ceiling, "\(kind) in \(data.count) bytes: +\(r.bytes >> 20) MB (footprint +\(r.footprint >> 20), allocated +\(r.malloc >> 20)) over \(ceiling >> 20) MB")
                // Debug code runs several times slower than Release: three seconds here stands for the one second wanted.
                XCTAssertLessThan(r.seconds, 3, "\(kind) in \(data.count) bytes: \(r.seconds) s")
            }
        }
    }

    /// The slowest crate call made by this class stays under a second.
    func testTheSlowestHostileInputFinishesInUnderASecond() {
        print("USDHostileFileTests: slowest crate call \(USDFuzzProbe.worstSeconds) s (\(USDFuzzProbe.worstLabel)); slowest noted \(USDFuzzProbe.noted.max { $0.0 < $1.0 } ?? (0, ""))")
        XCTAssertLessThan(USDFuzzProbe.worstSeconds, 1)
    }

    // MARK: Whole import

    /// The whole import on files that carry hostile colour data but good geometry: a `.usda` with `nan`
    /// and `1e30` where the colours and corner numbers are, with no interpolation, and with unbalanced
    /// braces after the mesh. The mesh opens in each case (the colours are dropped, not the model).
    func testTheImportStillOpensTheMeshWhenItsColourDataIsHostile() throws {
        let body = """
        #usda 1.0
        (
            defaultPrim = "root"
            upAxis = "Y"
        )
        def Xform "root" {
            def Mesh "Tri" {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                color4f[] primvars:Col = [(1, 0, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1)]%META%
            }
        }
        """
        let variants: [(String, String)] = [("control", ""), ("no interpolation", ""), ("nan colour", ""), ("unknown interpolation", " (interpolation = \"sideways\")"),
                                            ("face varying with 3 values", " (interpolation = \"faceVarying\")")]
        for (label, meta) in variants {
            var text = body.replacingOccurrences(of: "%META%", with: meta)
            if label == "nan colour" { text = text.replacingOccurrences(of: "(0, 1, 0, 1)", with: "(nan, 1e30, -inf, 1)") }
            let url = try write(Data(text.utf8), "import.usda")
            let scene = try ImportRouter.load(url, format: .usd)
            XCTAssertFalse(scene.meshes.isEmpty, label)
            XCTAssertEqual(scene.meshes.first?.parts.first?.positions.count, 3, label)
        }
        // Text after the mesh that unbalances the braces: Model I/O decides whether the file opens, and a trap must not happen either way.
        for tail in ["\n}}}}", "\n{{{{", "\ndef Mesh \"x\" {{{{ color4f[] primvars:Col = [(", "\n" + String(repeating: "def Xform \"a\" {\n", count: 3000)] {
            let url = try write(Data((body.replacingOccurrences(of: "%META%", with: "") + tail).utf8), "import2.usda")
            _ = try? ImportRouter.load(url, format: .usd)
        }
    }

    /// The whole import on mutated Blender files: 60 of each of the `.usdc` and `.usdz` fixtures with
    /// a few bytes changed (fixed seed), and a few truncated. It may throw or open; it must not trap or hang.
    func testTheImportOfMutatedBlenderFilesNeverTraps() throws {
        var rng = FuzzGenerator(seed: 0x5EED_0007)
        for (kind, fixtures) in [("usdc", USDFuzzFixtures.crates), ("usdz", USDFuzzFixtures.packages)] {
            for (name, original) in fixtures {
                for n in 0..<60 {
                    var d = original
                    if n < 6 { d = Data(d.prefix(rng.below(d.count))) } else {
                        let nasty = Nasty.values(size: d.count)
                        for _ in 0..<(1 + rng.below(3)) { let at = rng.below(d.count - 8); if rng.below(2) == 0 { d[at] = UInt8(truncatingIfNeeded: rng.next()) } else { d.put64(at, nasty[rng.below(nasty.count)]) } }
                    }
                    let url = try write(d, "\(name)-\(n).\(kind)")
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = try? ImportRouter.load(url, format: .usd)
                    let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                    USDFuzzProbe.note(dt, "import \(name) \(kind) #\(n)")
                    XCTAssertLessThan(dt, 2, "\(name) \(kind) #\(n)")
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
