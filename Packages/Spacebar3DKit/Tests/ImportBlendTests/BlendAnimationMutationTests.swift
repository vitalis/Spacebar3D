import Foundation
@testable import ImportBlend
import ModelCore
import XCTest

/// Random damage to the decompressed fixtures, from fixed seeds. Most of the damage is aimed at the blocks the animation reading follows
/// (and their headers), a tenth anywhere. A whole file opens in about 40 ms in Debug (the DNA parse), so each class runs a few hundred
/// files to stay under its time budget; the classes together are the corpus.
enum Mutation {
    enum Kind: String { case byte, multiByte, word32, word64 }

    static func hotRanges(_ file: BlendFile) -> [Range<Int>] {
        file.blocks.compactMap { block in
            guard block.length > 0, FuzzFiles.animationStructures.contains(file.structure(of: block)?.name ?? "") else { return nil }
            return (block.offset - 32)..<(block.offset + min(block.length, 4096))
        }
    }

    static func apply(_ kind: Kind, to data: Data, file: BlendFile, hot: [Range<Int>], random rng: inout FuzzRandom) -> (Data, String) {
        var out = data
        func position(alignment: Int = 1) -> Int {
            var p: Int
            if !hot.isEmpty, rng.next() % 10 != 0 { let r = hot[Int(rng.next() % UInt64(hot.count))]; p = r.lowerBound + Int(rng.next() % UInt64(r.count)) } else { p = Int(rng.next() % UInt64(data.count)) }
            p -= p % alignment
            return min(max(p, 0), data.count - 8)
        }
        func put<T>(_ value: T, at: Int) { withUnsafeBytes(of: value) { out.replaceSubrange(at..<(at + MemoryLayout<T>.size), with: $0) } }
        var recipe = kind.rawValue
        switch kind {
        case .byte:
            for _ in 0..<(1 + Int(rng.next() % 8)) {
                let p = position(), old = out[p]
                let v: UInt8 = [UInt8(truncatingIfNeeded: rng.next()), old ^ UInt8(1 << (rng.next() % 8)), 0, 0xFF, 0x7F, 0x80][Int(rng.next() % 6)]
                out[p] = v; recipe += " [\(p)]=\(v)"
            }
        case .multiByte:
            for _ in 0..<(1 + Int(rng.next() % 3)) {
                let p = position(), n = min(2 + Int(rng.next() % 63), data.count - p), pick = rng.next() % 5
                for i in 0..<n { out[p + i] = pick == 0 ? UInt8(truncatingIfNeeded: rng.next()) : pick == 1 ? 0xFF : pick == 2 ? 0 : pick == 3 ? [0x00, 0x00, 0xC0, 0x7F][i % 4] : [0x00, 0x00, 0x80, 0x7F][i % 4] }
                recipe += " [\(p)+\(n)]fill\(pick)"
            }
        case .word32:
            let interesting: [UInt32] = [0, 1, 0xFFFF_FFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF, 0x1_0000, 0x7FC0_0000, 0x7F80_0000, 0xFF80_0000, 0x4F00_0000, 0xCF00_0000, 0x0000_0001, 0x7F7F_FFFF, 0x0080_0000, 0x3F80_0000, 0xBF80_0000]
            for _ in 0..<(1 + Int(rng.next() % 4)) {
                let p = position(alignment: 4), v = rng.next() % 4 == 0 ? UInt32(truncatingIfNeeded: rng.next()) : interesting[Int(rng.next() % UInt64(interesting.count))]
                put(v, at: p); recipe += " [\(p)]=0x\(String(v, radix: 16))"
            }
        case .word64:
            for _ in 0..<(1 + Int(rng.next() % 4)) {
                let p = position(alignment: 8)
                let block = file.blocks[Int(rng.next() % UInt64(file.blocks.count))]
                let choices: [UInt64] = [0, 1, .max, UInt64(Int64.max), UInt64(bitPattern: Int64.min), 1 << 31, 1 << 32, 0x7FF8_0000_0000_0000, 0x7FF0_0000_0000_0000, 0x7FFF_FFFF_0000_0000 | 0xFFFF, block.old, block.old, block.old &+ 8, UInt64(0xFFFF_FFFF) << 32 | rng.next() & 0xFFFF, rng.next()]
                let v = choices[Int(rng.next() % UInt64(choices.count))]
                put(v, at: p); recipe += " [\(p)]=0x\(String(v, radix: 16))"
            }
        }
        return (out, recipe)
    }
}

class BlendMutationRun: XCTestCase {
    var harness: FuzzHarness!
    override func setUp() { continueAfterFailure = true; harness = FuzzHarness() }
    override func tearDown() { print(harness.summary) }

    func run(_ kind: Mutation.Kind, seed: UInt64, perFixture: Int) {
        for (name, data) in FuzzFiles.slim {
            guard let file = try? BlendFile(data) else { return XCTFail("\(name) does not parse") }
            let hot = Mutation.hotRanges(file)
            var rng = FuzzRandom(seed: seed ^ UInt64(name.utf8.reduce(5381) { $0 &* 33 &+ Int($1) }))
            for i in 0..<perFixture {
                let (mutated, recipe) = Mutation.apply(kind, to: data, file: file, hot: hot, random: &rng)
                harness.run("seed \(seed) \(name) #\(i) \(recipe)", mutated, fixture: name, render: i % 12 == 0)
            }
        }
    }
}

final class BlendAnimationByteMutationTests: BlendMutationRun {
    /// Random single bytes and bit flips (one to eight a file), first set of seeds: none traps, hangs or allocates hugely.
    func testRandomByteChangesOpenOrAreRefusedFirstSeeds() { run(.byte, seed: 0xB1E4D001, perFixture: 150) }
}
final class BlendAnimationByteMutationMoreTests: BlendMutationRun {
    /// Random single bytes and bit flips, second set of seeds.
    func testRandomByteChangesOpenOrAreRefusedSecondSeeds() { run(.byte, seed: 0xB1E4D002, perFixture: 150) }
}
final class BlendAnimationMultiByteMutationTests: BlendMutationRun {
    /// Runs of two to sixty-four bytes set to noise, 0xFF, zero or float NaN and infinity patterns, first seeds.
    func testRandomMultiByteRunsOpenOrAreRefusedFirstSeeds() { run(.multiByte, seed: 0xB1E4D003, perFixture: 150) }
}
final class BlendAnimationMultiByteMutationMoreTests: BlendMutationRun {
    /// Runs of two to sixty-four bytes, second seeds.
    func testRandomMultiByteRunsOpenOrAreRefusedSecondSeeds() { run(.multiByte, seed: 0xB1E4D004, perFixture: 150) }
}
final class BlendAnimationWord32MutationTests: BlendMutationRun {
    /// Aligned 32-bit words (counts, indices, floats) set to extremes: 0, -1, 2^31, 65535, 65536, NaN, infinity, huge floats, first seeds.
    func testRandom32BitWordsOpenOrAreRefusedFirstSeeds() { run(.word32, seed: 0xB1E4D005, perFixture: 150) }
}
final class BlendAnimationWord32MutationMoreTests: BlendMutationRun {
    /// Aligned 32-bit words set to extremes, second seeds.
    func testRandom32BitWordsOpenOrAreRefusedSecondSeeds() { run(.word32, seed: 0xB1E4D006, perFixture: 150) }
}
final class BlendAnimationWord64MutationTests: BlendMutationRun {
    /// Aligned 64-bit words (pointers, 64-bit counts) set to 0, -1, 2^31, 2^32, NaN, infinity or the address of a real block, first seeds.
    func testRandom64BitWordsOpenOrAreRefusedFirstSeeds() { run(.word64, seed: 0xB1E4D007, perFixture: 150) }
}
final class BlendAnimationWord64MutationMoreTests: BlendMutationRun {
    /// Aligned 64-bit words set to extremes or block addresses, second seeds.
    func testRandom64BitWordsOpenOrAreRefusedSecondSeeds() { run(.word64, seed: 0xB1E4D008, perFixture: 150) }
}
