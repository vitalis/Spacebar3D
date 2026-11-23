import Foundation
@testable import ImportBlend
import ModelCore
import simd
import XCTest

/// Truncated and randomly damaged copies of the five Blender 5.2.2 animation fixtures (decompressed first, so the
/// damage lands in the `.blend` itself and not in the Zstandard stream). None may trap, hang or allocate hugely;
/// each must open or be refused. Fixed seeds: the same inputs every run. The last input started is written to
/// `/tmp/ba2/last-input.txt`, which names the culprit if the process dies.
final class BlendAnimationTruncationTests: XCTestCase {
    private var harness: FuzzHarness!
    override func setUp() { continueAfterFailure = true; harness = FuzzHarness() }
    override func tearDown() { print(harness.summary) }

    /// The fixtures decompress to real Blender 5.2.2 files, the reader accepts them uncompressed, and the animated ones give a clip.
    func testTheDecompressedFixturesOpenUncompressedAndAreAnimated() throws {
        for (name, data) in FuzzFiles.all {
            XCTAssertTrue(data.starts(with: Array("BLENDER".utf8)), name)
            XCTAssertFalse(Zstandard.isCompressed(data), name)
            let scene = try BlendReader.scene(from: data)
            XCTAssertEqual(scene.clips.isEmpty, name == "staticCube", "\(name): clips \(scene.clips.count)")
        }
        for (name, data) in FuzzFiles.slim {
            let scene = try BlendReader.scene(from: data)
            XCTAssertEqual(scene.clips.isEmpty, name == "staticCube", "slim \(name)")
        }
    }

    /// The file cut at the first 600 bytes, then at a stride and around every block header up to the DNA block, and through the DNA block (which ends the file) at a stride and at every byte of its last 300.
    func testEveryTruncationLengthOfEachFixtureOpensOrIsRefused() {
        for (name, data) in FuzzFiles.slim { harness.calibrate(name, data) }
        for (name, data) in FuzzFiles.slim {
            guard let file = try? BlendFile(data), let dna = file.blocks.first(where: { $0.code == BlendFile.dnaCode }) else { return XCTFail("\(name) does not parse") }
            for length in 0..<data.count where length < 300 || (length < dna.offset && (length % 800 == 0 || file.blocks.contains { abs($0.offset - 32 - length) < 3 })) || length % 701 == 0 || length > data.count - 60 {
                harness.run("truncate slim \(name) to \(length) of \(data.count)", Data(data.prefix(length)), fixture: name, render: length % 4001 == 0)
            }
        }
    }

    /// The full fixtures cut at block boundaries: the header cut at every byte, payloads at the start, middle and end.
    func testTruncatingTheFullFixturesAtBlockBoundariesOpensOrIsRefused() {
        for (name, data) in FuzzFiles.all {
            guard let file = try? BlendFile(data) else { return XCTFail("\(name) does not parse") }
            var cuts = Set<Int>()
            for (i, block) in file.blocks.enumerated() where i % 25 == 0 || block.code == BlendFile.dnaCode {
                for d in stride(from: 0, through: 32, by: 3) { cuts.insert(block.offset - 32 + d) }
                for d in [1, block.length / 2, max(block.length - 1, 0)] { cuts.insert(block.offset + d) }
            }
            for cut in cuts.sorted() where cut >= 0 && cut < data.count { harness.run("truncate full \(name) to \(cut)", Data(data.prefix(cut))) }
        }
    }
}

/// The blocks that the animation reading follows, each cut short while the file around it stays valid (the DNA parse of a whole file is
/// about 10 ms in Debug, so this is its own class to stay under the time budget).
final class BlendAnimationShortBlockTests: XCTestCase {
    private var harness: FuzzHarness!
    override func setUp() { continueAfterFailure = true; harness = FuzzHarness() }
    override func tearDown() { print(harness.summary) }

    /// Each block of the animation, armature, weight, shape-key and object structures cut short in place (its header length shortened, the bytes after it kept), at its start, a few bytes in, the middle and one byte short: every reader sees a short array, struct or string.
    func testShorteningEachAnimationBlockInPlaceOpensOrIsRefused() {
        for (name, data) in FuzzFiles.slim { harness.calibrate(name, data) }
        for (name, data) in FuzzFiles.slim {
            guard let file = try? BlendFile(data) else { return XCTFail("\(name) does not parse") }
            for (index, block) in file.blocks.enumerated() where block.length > 0 && FuzzFiles.animationStructures.contains(file.structure(of: block)?.name ?? "") {
                for keep in Set([0, 4, block.length / 2, block.length - 1]) where keep >= 0 && keep < block.length {
                    var cut = data
                    cut.replaceSubrange((block.offset + keep)..<(block.offset + block.length), with: [])
                    cut.replaceSubrange((block.offset - 16)..<(block.offset - 8), with: withUnsafeBytes(of: Int64(keep)) { Array($0) })
                    harness.run("shorten slim \(name) block \(index) to \(keep) of \(block.length)", cut, fixture: name, render: keep == block.length / 2 && index % 3 == 0)
                }
            }
        }
    }
}
