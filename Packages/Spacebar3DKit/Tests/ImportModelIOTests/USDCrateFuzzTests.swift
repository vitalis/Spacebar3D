import Foundation
import XCTest
@testable import ImportModelIO

/// Deterministic fuzzing of the binary USD reader (`USDCrateReader`), the zip reader and the text
/// reader. Every input is made from the Blender fixtures in `BlenderUSDColourTests.swift`, or from
/// `CrateBuilder`, by cutting or changing bytes with a fixed-seed generator (the same files every
/// run). Nothing may trap, hang (each call under a second) or hand back a nonsense mesh; a bad file
/// answers `nil`. Counts are fixed below; a failure message names the input recipe.
final class USDCrateFuzzTests: XCTestCase {
    private var folder: URL!
    private var seedSalt: UInt64 = 0

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// The crate files to fuzz: the three Blender files and two built ones (one with the
    /// uncompressed value arrays the Blender files lack).
    private var crates: [(name: String, data: Data)] {
        var triangle = CrateBuilder()
        var cornerColours = CrateBuilder(minor: 13, points: 4, colours: 6, indices: [0, 1, 2, 2, 3, 0], interpolation: 15)
        return USDFuzzFixtures.crates + [("built", triangle.build()), ("builtOld", cornerColours.build())]
    }

    /// What a mesh the reader hands back must satisfy, whatever the input was.
    private func check(_ result: [String: USDColorPrimvars.Mesh]?, size: Int, _ label: @autoclosure () -> String, line: UInt = #line) {
        guard let result else { return }
        let bound = 32 * size + 4096
        XCTAssertFalse(result.isEmpty, "non-nil result must hold a mesh: \(label())", line: line)
        for (path, mesh) in result {
            XCTAssertTrue(path.hasPrefix("/"), "\(label())", line: line)
            XCTAssertLessThanOrEqual(mesh.points.count, bound, "\(label())", line: line)
            XCTAssertFalse(mesh.colours.isEmpty, "\(label())", line: line)
            for c in mesh.colours {
                XCTAssertLessThanOrEqual(c.values.count, bound, "\(label())", line: line)
                XCTAssertTrue(c.values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }, "NaN colour: \(label())", line: line)
            }
        }
    }

    private func run(_ data: Data, _ label: @autoclosure () -> String) {
        check(USDFuzzProbe.crate(data, label()), size: data.count, label())
    }

    // MARK: Control

    /// The built file opens in every crate version from 0.8 to 0.13 and gives the mesh, its three
    /// points and one colour attribute; versions 0.4 to 0.7 are refused; the Blender files give their meshes too. This proves the
    /// fuzzing starts from files that work.
    func testBuiltAndBlenderFilesOpenSoMutationsStartFromGoodInput() throws {
        for minor in UInt8(4)...7 {
            var b = CrateBuilder(minor: minor)
            XCTAssertNil(USDCrateReader.meshes(from: b.build()), "version 0.\(minor) is refused")
        }
        for minor in UInt8(8)...13 {
            var b = CrateBuilder(minor: minor)
            let mesh = try XCTUnwrap(USDCrateReader.meshes(from: b.build())?["/root/Tri"], "version 0.\(minor)")
            XCTAssertEqual(mesh.points.count, 3)
            XCTAssertEqual(mesh.faceVertexIndices, [0, 1, 2])
            XCTAssertEqual(mesh.colours.first?.values.count, 3)
            XCTAssertEqual(mesh.colours.first?.interpolation, "vertex")
        }
        for (name, data) in USDFuzzFixtures.crates where name != "triPlain" {
            XCTAssertNotNil(USDCrateReader.meshes(from: data), name)
        }
        XCTAssertNil(USDCrateReader.meshes(from: USDFuzzFixtures.crates[2].data), "a mesh without colours gives nothing")
    }

    // MARK: Truncation

    /// Every prefix of every crate file, byte by byte (about 7,000 files): none may trap, and none
    /// shorter than the table of contents may be accepted.
    func testEveryTruncationOfEveryCrateFileIsRefusedOrHarmless() throws {
        var total = 0
        for (name, data) in crates {
            let tocAt = CrateLayout(data)?.tocAt ?? 0
            for length in 0..<data.count {
                let part = Data(data.prefix(length))
                run(part, "\(name) cut at \(length)")
                total += 1
                if length < tocAt { XCTAssertNil(USDCrateReader.meshes(from: part), "\(name) cut at \(length) is before the table of contents") }
            }
        }
        XCTAssertGreaterThan(total, 5000)
    }

    // MARK: Random mutation

    /// 4,000 single-byte changes per file (about 20,000 files): a random byte set to a random value
    /// or to 0, 0xFF or 0x7F or with one bit flipped.
    func testRandomSingleByteChangesNeverTrap() {
        var rng = FuzzGenerator(seed: 0x5EED_0001)
        for (name, original) in crates {
            for n in 0..<4000 {
                var d = original
                let at = rng.below(d.count)
                switch rng.below(5) {
                case 0: d[at] = UInt8(truncatingIfNeeded: rng.next())
                case 1: d[at] = 0
                case 2: d[at] = 0xFF
                case 3: d[at] = 0x7F
                default: d[at] ^= UInt8(1 << rng.below(8))
                }
                run(d, "\(name) single byte #\(n) at \(at)")
            }
        }
    }

    /// 2,400 changes per file that overwrite 2 to 24 bytes at one or several places with random
    /// bytes, runs of zeros or runs of 0xFF (about 12,000 files).
    func testRandomMultiByteChangesNeverTrap() {
        var rng = FuzzGenerator(seed: 0x5EED_0002)
        for (name, original) in crates {
            for n in 0..<2400 {
                var d = original
                for _ in 0..<(1 + rng.below(4)) {
                    let at = rng.below(d.count)
                    let length = min(d.count - at, 2 + rng.below(23))
                    let kind = rng.below(3)
                    for k in 0..<length { d[at + k] = kind == 0 ? UInt8(truncatingIfNeeded: rng.next()) : kind == 1 ? 0 : 0xFF }
                }
                run(d, "\(name) multi byte #\(n)")
            }
        }
    }

    /// 4,000 random 64-bit overwrites per file, at any offset (so also across the 8-byte words), with
    /// the values that break counts and offsets: 0, 1, the file's size, its size plus one, 2^32,
    /// 2^47, 2^48, Int64.max, UInt64.max and random words (about 20,000 files).
    func testRandomSixtyFourBitFieldsNeverTrap() {
        var rng = FuzzGenerator(seed: 0x5EED_0003)
        for (name, original) in crates {
            let nasty = Nasty.values(size: original.count)
            for n in 0..<4000 {
                var d = original
                let at = rng.below(d.count - 7)
                let v = rng.below(4) == 0 ? rng.next() : nasty[rng.below(nasty.count)]
                d.put64(at, v)
                run(d, "\(name) u64 #\(n) at \(at) = \(v)")
            }
        }
    }

    /// Every 8-aligned word of every crate file, and the first six words of each section, set to each
    /// of the 26 nasty values in turn (about 30,000 files, no randomness).
    func testEveryWordSetToEveryNastyValueNeverTraps() {
        for (name, original) in crates {
            var offsets = Set(stride(from: 0, to: original.count - 7, by: 8))
            if let layout = CrateLayout(original) {
                for s in layout.sections where s.start >= 0 && s.start < original.count { for k in 0..<6 { offsets.insert(s.start + 8 * k) } }
            }
            for at in offsets.sorted() where at + 8 <= original.count {
                for v in Nasty.values(size: original.count) {
                    var d = original
                    d.put64(at, v)
                    run(d, "\(name) word at \(at) = \(v)")
                }
            }
        }
    }

    /// Pieces of one file copied over another, so tables meet the wrong bytes (1,200
    /// files).
    func testSplicedFilesNeverTrap() {
        var rng = FuzzGenerator(seed: 0x5EED_0004)
        let all = crates
        for n in 0..<1200 {
            var d = all[rng.below(all.count)].data
            let other = all[rng.below(all.count)].data
            let at = rng.below(d.count), from = rng.below(other.count), length = min(rng.below(400) + 1, d.count - at, other.count - from)
            d.replaceSubrange(at..<(at + length), with: other[from..<(from + length)])
            run(d, "splice #\(n) at \(at) from \(from) length \(length)")
        }
    }

    // MARK: Zip and text

    /// Every prefix of each `.usdz` (about 5,500 files, each written to disk and opened as the
    /// importer opens it): `USDColorPrimvars(url:)` must not trap.
    func testEveryTruncationOfEveryPackageIsRefusedOrHarmless() throws {
        let url = folder.appendingPathComponent("cut.usdz")
        for (name, original) in USDFuzzFixtures.packages {
            for length in stride(from: 0, to: original.count, by: 1) {
                try Data(original.prefix(length)).write(to: url)
                let found = USDColorPrimvars(url: url)
                if length < original.count { XCTAssertNil(found, "\(name) package cut at \(length) has no directory record") }
            }
        }
    }

    /// 2,400 random byte and 32-bit changes per `.usdz` (7,200 files) through the zip reader and the
    /// crate reader behind it.
    func testRandomChangesToPackagesNeverTrap() throws {
        var rng = FuzzGenerator(seed: 0x5EED_0005)
        let url = folder.appendingPathComponent("mut.usdz")
        for (_, original) in USDFuzzFixtures.packages {
            for _ in 0..<2400 {
                var d = original
                for _ in 0..<(1 + rng.below(3)) {
                    let at = rng.below(d.count - 8)
                    if rng.below(2) == 0 { d[at] = UInt8(truncatingIfNeeded: rng.next()) } else { d.put32(at, UInt32(truncatingIfNeeded: rng.next() | (rng.below(2) == 0 ? 0xFFFF_0000 : 0))) }
                }
                try d.write(to: url)
                _ = USDColorPrimvars(url: url)
                _ = ZipStore(url: url)?.firstLayer(withExtension: "usdc")
            }
        }
    }

    /// 2,000 random changes per `.usda` (6,000 files): bytes, deleted ranges, repeated ranges, and
    /// the characters that matter to the scanner (braces, quotes, brackets, parentheses, `#`).
    func testRandomChangesToTextNeverTrap() throws {
        var rng = FuzzGenerator(seed: 0x5EED_0006)
        let url = folder.appendingPathComponent("mut.usda")
        let special = Array("{}[]()\"'#=,.-e\nnaiN".utf8)
        for (_, original) in USDFuzzFixtures.texts {
            for _ in 0..<2000 {
                var d = original
                for _ in 0..<(1 + rng.below(4)) where d.count > 20 {
                    let at = rng.below(d.count - 10)
                    switch rng.below(4) {
                    case 0: d[at] = UInt8(truncatingIfNeeded: rng.next())
                    case 1: d[at] = special[rng.below(special.count)]
                    case 2: d.removeSubrange(at..<(at + rng.below(10)))
                    default: let piece = d[at..<(at + rng.below(10))]; d.insert(contentsOf: piece + piece, at: at)
                    }
                }
                try d.write(to: url)
                if let found = USDColorPrimvars(url: url) {
                    for (path, mesh) in found.meshes {
                        XCTAssertTrue(path.hasPrefix("/"))
                        for c in mesh.colours { XCTAssertTrue(c.values.allSatisfy { $0.x.isFinite && $0.w.isFinite }) }
                    }
                }
            }
        }
    }

    /// The slowest call seen by this class stays under a second (the probe fails each call over one);
    /// this line prints the figure for the report.
    func testTheSlowestFuzzCallIsReported() {
        let slowest = USDFuzzProbe.worstSeconds
        print("USDCrateFuzzTests: \(USDFuzzProbe.calls) crate calls so far, slowest \(slowest) s (\(USDFuzzProbe.worstLabel))")
        XCTAssertLessThan(slowest, 1)
    }
}
