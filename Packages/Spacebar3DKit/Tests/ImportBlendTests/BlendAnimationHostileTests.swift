import Foundation
@testable import ImportBlend
import ModelCore
import XCTest

/// Targeted hostile edits of the decompressed fixtures: cyclic bones and parents, huge counts, wild indices, non-finite and reversed
/// Bezier keys, impossible timing, degenerate rotations and matrices, bad weights and malformed `rna_path` strings. Each edit is
/// made in place by structure and field name (the offsets come from the file's own DNA) on every fixture that has the structure.
/// The importer must open the model (perhaps without animation) without trapping, hanging or allocating hugely.
class BlendHostileRun: XCTestCase {
    typealias Edit = (inout Doc) -> Int
    struct Variant { let name: String; let edit: Edit; var mustOpen = true }
    var harness: FuzzHarness!
    override func setUp() { continueAfterFailure = true; harness = FuzzHarness() }
    override func tearDown() { print(harness.summary) }

    static let extremes: [Double] = [.nan, .infinity, -.infinity, 1e38, -1e38, 3.0e9, 0, -1, 1e-38]
    static let counts: [Int64] = [Int64(Int32.max), -1, Int64(Int32.min), 65_536, 1 << 24, 0]
    static let indices: [Int64] = [-1, Int64(Int32.max), Int64(Int32.min), 65_535, 65_536, 1 << 30, 7]

    func floats(_ s: String, _ f: String, components: [Int] = [0], values: [Double] = extremes, tag: String? = nil, mustOpen: Bool = true) -> [Variant] {
        values.map { v in Variant(name: "\(tag ?? "\(s).\(f)")=\(v)", edit: { d in components.reduce(0) { $0 + d.set(s, f, component: $1) { _ in .num(v) } } }, mustOpen: mustOpen) }
    }
    func ints(_ s: String, _ f: String, values: [Int64], mustOpen: Bool = true) -> [Variant] {
        values.map { v in Variant(name: "\(s).\(f)=\(v)", edit: { d in d.set(s, f) { _ in .int(v) } }, mustOpen: mustOpen) }
    }

    func run(_ variants: [Variant], file: StaticString = #filePath, line: UInt = #line) {
        var hits: [String: Int] = [:]
        for (name, data) in FuzzFiles.slim {
            for variant in variants {
                guard var doc = Doc(data) else { return XCTFail("\(name) does not parse") }
                let n = variant.edit(&doc)
                guard n > 0 else { continue }
                hits[variant.name, default: 0] += 1
                harness.run("hostile \(name): \(variant.name)", doc.data, fixture: name, render: hits[variant.name] == 1 && harness.cases % 5 == 0, mustOpen: variant.mustOpen, file: file, line: line)
            }
        }
        let missed = variants.filter { hits[$0.name] == nil }.map(\.name)
        print("P3D-FUZZ unreached variants (no fixture has the structure): \(missed.count) of \(variants.count) \(missed.prefix(6))")
        XCTAssertLessThan(missed.count, variants.count, "no variant reached any fixture", file: file, line: line)
    }
}

final class BlendAnimationHostileGraphTests: BlendHostileRun {
    /// A bone that is its own first child, its own next sibling, and two bones that are each other's children: the joint list stops at its cap and the time and memory stay bounded.
    func testCyclicBonesAndObjectParentsOpenWithoutHangingOrAllocatingHugely() {
        var v: [Variant] = []
        v.append(Variant(name: "bone is its own child", edit: { d in d.set("Bone", "childbase") { .pointer($0.address) } }))
        v.append(Variant(name: "bone childbase last = itself too", edit: { d in d.set("Bone", "childbase", component: 1) { .pointer($0.address) } + d.set("Bone", "childbase") { .pointer($0.address) } }))
        v.append(Variant(name: "bone is its own next sibling", edit: { d in d.set("Bone", "next") { .pointer($0.address) } }))
        v.append(Variant(name: "bone is its own parent", edit: { d in d.set("Bone", "parent") { .pointer($0.address) } }))
        v.append(Variant(name: "two bones children of each other", edit: { d in
            let bones = d.elements("Bone"); guard bones.count >= 2, let f = d.file.offset("Bone", "childbase") else { return 0 }
            d.put(bones[1].address, at: bones[0].base + f); d.put(bones[0].address, at: bones[1].base + f)
            if let p = d.file.offset("Bone", "parent") { d.put(bones[1].address, at: bones[0].base + p); d.put(bones[0].address, at: bones[1].base + p) }
            return 2 }))
        v.append(Variant(name: "armature bonebase starts at a self-cyclic bone", edit: { d in d.set("Bone", "next") { .pointer($0.address) } + d.set("Bone", "childbase") { .pointer($0.address) } + { let first = d.elements("Bone").first?.address ?? 0; return d.set("bArmature", "bonebase") { _ in .pointer(first) } }() }))
        v.append(Variant(name: "pose channel is its own parent and child", edit: { d in d.set("bPoseChannel", "parent") { .pointer($0.address) } + d.set("bPoseChannel", "child") { .pointer($0.address) } + d.set("bPoseChannel", "next") { .pointer($0.address) } }))
        v.append(Variant(name: "object is its own parent", edit: { d in d.set("Object", "parent") { .pointer($0.address) } }))
        v.append(Variant(name: "objects are each other's parents", edit: { d in
            let objects = d.elements("Object").filter { $0.block.code == BlendFile.code("OB") }; guard objects.count >= 2, let f = d.file.offset("Object", "parent") else { return 0 }
            d.put(objects[1].address, at: objects[0].base + f); d.put(objects[0].address, at: objects[1].base + f); return 2 }))
        v.append(Variant(name: "object parent chain of bone-parent type with a cycle", edit: { d in d.set("Object", "partype", { _ in .int(7) }) + d.set("Object", "parent") { .pointer($0.address) } }))
        for t: Int64 in [0, 1, 2, 7, 8, 100, -1, 32767] { v.append(Variant(name: "object partype=\(t)", edit: { d in let first = d.elements("Object").first { $0.block.code == BlendFile.code("OB") }?.address ?? 0; return d.set("Object", "partype") { _ in .int(t) } + d.set("Object", "parent") { _ in .pointer(first) } })) }
        run(v)
    }

    /// Counts of every kind set to 2^31-1, -1, -2^31, 65536, 2^24 and 0 (`totvert`, curve, layer, strip, channelbag, slot, keyframe-data, weight, element and key counts).
    func testHugeAndNegativeCountsOpenWithoutAllocatingHugely() {
        var v: [Variant] = []
        for (s, f) in [("FCurve", "totvert"), ("bAction", "layer_array_num"), ("ActionLayer", "strip_array_num"), ("ActionStripKeyframeData", "channelbag_array_num"), ("ActionChannelBag", "fcurve_array_num"),
                       ("bAction", "slot_array_num"), ("bAction", "strip_keyframe_data_array_num"), ("MDeformVert", "totweight"), ("KeyBlock", "totelem"), ("Key", "totkey"), ("ActionChannelBag", "group_array_num"), ("bArmature", "act_bone")] {
            v += ints(s, f, values: Self.counts)
        }
        v += ints("Mesh", "totvert", values: Self.counts, mustOpen: false)
        v += ints("Mesh", "totpoly", values: Self.counts, mustOpen: false) + ints("Mesh", "totloop", values: Self.counts, mustOpen: false)
        v += ints("CustomData", "totlayer", values: Self.counts, mustOpen: false)
        run(v)
    }

    /// Indices out of range: `data_index`, `slot_handle` (animation data, slot and channelbag), `array_index`, `def_nr`.
    func testOutOfRangeIndicesAndHandlesOpenWithoutTrapping() {
        var v: [Variant] = []
        for (s, f) in [("ActionStrip", "data_index"), ("AnimData", "slot_handle"), ("ActionSlot", "handle"), ("ActionChannelBag", "slot_handle"), ("FCurve", "array_index"), ("MDeformWeight", "def_nr"), ("KeyBlock", "relative"), ("KeyBlock", "vgroup")] {
            v += ints(s, f, values: Self.indices)
        }
        for t: Int64 in [-1, 1, 2, 255, 256] { v.append(Variant(name: "ActionStrip.strip_type=\(t)", edit: { d in d.set("ActionStrip", "strip_type") { _ in .int(t) } })) }
        for t: Int64 in [-1, 1, 2, 9] { v.append(Variant(name: "Key.type=\(t)", edit: { d in d.set("Key", "type") { _ in .int(t) } })) }
        run(v)
    }

    /// Every animation pointer pointed at its own block, at the owner's header, at a different block, and at nothing.
    func testPointersAimedAtThemselvesOrOtherBlocksOpenWithoutTrapping() {
        var v: [Variant] = []
        let fields: [(String, String)] = [("AnimData", "action"), ("bAction", "layer_array"), ("bAction", "slot_array"), ("bAction", "strip_keyframe_data_array"), ("ActionLayer", "strip_array"),
            ("ActionStripKeyframeData", "channelbag_array"), ("ActionChannelBag", "fcurve_array"), ("FCurve", "bezt"), ("FCurve", "rna_path"), ("Key", "refkey"), ("KeyBlock", "data"), ("KeyBlock", "next"),
            ("Object", "adt"), ("Object", "data"), ("Mesh", "key"), ("Object", "modifiers"), ("Mesh", "vertex_group_names"), ("bArmature", "bonebase")]
        for (s, f) in fields {
            let geometry = (s, f) == ("Object", "data")
            v.append(Variant(name: "\(s).\(f) -> itself", edit: { d in d.set(s, f) { .pointer($0.address) } }, mustOpen: !geometry))
            v.append(Variant(name: "\(s).\(f) -> object block", edit: { d in let first = d.elements("Object").first?.address ?? 1; return d.set(s, f) { _ in .pointer(first) } }, mustOpen: !geometry))
            v.append(Variant(name: "\(s).\(f) -> null", edit: { d in d.set(s, f) { _ in .pointer(0) } }, mustOpen: !geometry))
            v.append(Variant(name: "\(s).\(f) -> unmapped", edit: { d in d.set(s, f) { _ in .pointer(0xDEAD_BEEF_0000) } }, mustOpen: !geometry))
        }
        run(v)
    }
}

final class BlendAnimationHostileCurveTests: BlendHostileRun {
    /// Bezier keys whose frames, values and handles are NaN, infinity, huge, tiny, negative; handles crossing or reversed; interpolation codes out of range; keys out of order or all on one frame.
    func testNonFiniteHugeAndCrossingBezierKeysOpenWithoutTrapping() {
        var v: [Variant] = []
        // vec[0..2] left handle, vec[3..5] key, vec[6..8] right handle.
        v += floats("BezTriple", "vec", components: [3], tag: "key frame")
        v += floats("BezTriple", "vec", components: [4], tag: "key value")
        v += floats("BezTriple", "vec", components: [0], tag: "left handle frame")
        v += floats("BezTriple", "vec", components: [1], tag: "left handle value")
        v += floats("BezTriple", "vec", components: [6], tag: "right handle frame")
        v += floats("BezTriple", "vec", components: [7], tag: "right handle value")
        v += floats("BezTriple", "vec", components: [0, 3, 6], tag: "every frame")
        v += floats("BezTriple", "vec", components: [1, 4, 7], tag: "every value")
        v += floats("BezTriple", "vec", components: Array(0..<9), values: [.nan, .infinity, 1e38, -1e38, 0], tag: "all nine")
        for (name, left, right) in [("left handle after key", 1e6, 0.0), ("right handle before key", 0.0, -1e6), ("handles swapped and crossing", 1e5, -1e5), ("handles huge apart", 3e9, -3e9), ("handles on the key", 0.0, 0.0)] {
            v.append(Variant(name: "handles " + name, edit: { d in
                guard let f = d.file.offset("BezTriple", "vec") else { return 0 }
                var hits = 0
                for e in d.elements("BezTriple") { let key = d.file.f32(e.base + f + 12); d.put(Float(Double(key) + left), at: e.base + f); d.put(Float(Double(key) + right), at: e.base + f + 24); hits += 1 }
                return hits }))
        }
        for ipo: Int64 in [0, 1, 2, 3, 4, 255, -1, Int64(Int32.max)] { v.append(Variant(name: "BezTriple.ipo=\(ipo)", edit: { d in d.set("BezTriple", "ipo") { _ in .int(ipo) } })) }
        v.append(Variant(name: "key frames descending", edit: { d in guard let f = d.file.offset("BezTriple", "vec") else { return 0 }; var n = 0; for e in d.elements("BezTriple") { d.put(Float(1000 - e.index * 10), at: e.base + f + 12); n += 1 }; return n }))
        v.append(Variant(name: "key frames all equal", edit: { d in d.set("BezTriple", "vec", component: 3) { _ in .num(5) } }))
        v.append(Variant(name: "two thousand keys claimed in a one-key block", edit: { d in d.set("FCurve", "totvert") { _ in .int(2000) } }))
        v += floats("FCurve", "flag", values: [0, 1, 4, 1024, 1028, 65535, -1], tag: "FCurve.flag")
        v += floats("FCurve", "extend", values: [0, 1, 2, -1, 100], tag: "FCurve.extend")
        run(v)
    }

    /// Scene timing: fps 0, base 0, NaN, negative, infinite, tiny and huge, start after end, and start and end at plus or minus 2^31.
    func testImpossibleSceneTimingOpensWithoutTrapping() {
        func scene(_ field: String) -> (Doc) -> Int? { { d in d.file.offset("Scene", "r").flatMap { r in d.file.offset("RenderData", field).map { r + $0 } } } }
        var v: [Variant] = []
        func put(_ name: String, _ write: @escaping (inout Doc, Int, Int) -> Void) {
            v.append(Variant(name: name, edit: { d in
                var n = 0
                for e in d.elements("Scene") where e.block.code == BlendFile.code("SC") {
                    guard let r = d.file.offset("Scene", "r"), let rd = d.file.structure("RenderData")?.fields else { continue }
                    guard let sfra = rd["sfra"]?.offset, let efra = rd["efra"]?.offset, let sec = rd["frs_sec"]?.offset, let base = rd["frs_sec_base"]?.offset else { continue }
                    write(&d, e.base + r + sfra, e.base + r + efra); write(&d, e.base + r + sec, e.base + r + base); n += 1
                }
                return n }))
        }
        for fps: Int16 in [0, -1, 1, Int16.max, Int16.min, 1000] { for base: Float in [1, 0, -1, .nan, .infinity, 1e-30, 1e30, -0.0] {
            v.append(Variant(name: "fps \(fps) base \(base)", edit: { d in
                var n = 0
                for e in d.elements("Scene") where e.block.code == BlendFile.code("SC") {
                    guard let r = d.file.offset("Scene", "r"), let rd = d.file.structure("RenderData")?.fields, let s = rd["frs_sec"]?.offset, let b = rd["frs_sec_base"]?.offset else { continue }
                    d.put(fps, at: e.base + r + s); d.put(base, at: e.base + r + b); n += 1
                }
                return n }))
        } }
        for (s, e) in [(100, 1), (1, 1), (Int32.min, Int32.max), (Int32.max, Int32.min), (Int32.min, Int32.min), (Int32.max, Int32.max), (0, Int32.max), (Int32.min, 0), (-1, -1_000_000_000), (1 << 30, -(1 << 30))] as [(Int32, Int32)] {
            v.append(Variant(name: "sfra \(s) efra \(e)", edit: { d in
                var n = 0
                for el in d.elements("Scene") where el.block.code == BlendFile.code("SC") {
                    guard let r = d.file.offset("Scene", "r"), let rd = d.file.structure("RenderData")?.fields, let a = rd["sfra"]?.offset, let b = rd["efra"]?.offset else { continue }
                    d.put(s, at: el.base + r + a); d.put(e, at: el.base + r + b); n += 1
                }
                return n }))
        }
        v += floats("bAction", "frame_start", values: Self.extremes, tag: "action frame_start") + floats("bAction", "frame_end", values: Self.extremes, tag: "action frame_end")
        run(v)
    }
}

final class BlendAnimationHostileValueTests: BlendHostileRun {
    /// Zero, NaN, infinite, huge and negative quaternions, Euler angles, scales, locations and rotation modes on objects and pose channels.
    func testDegenerateRotationsScalesAndModesOpenWithoutTrapping() {
        var v: [Variant] = []
        let q: [Double] = [0, .nan, .infinity, 1e30, -1e30, 1e-40]
        for (s, f, n) in [("Object", "quat", 4), ("bPoseChannel", "quat", 4), ("Object", "rot", 3), ("bPoseChannel", "eul", 3), ("Object", "size", 3), ("bPoseChannel", "size", 3), ("Object", "loc", 3), ("bPoseChannel", "loc", 3), ("Object", "dsize", 3), ("Object", "dquat", 4), ("Object", "drot", 3), ("Object", "dloc", 3)] {
            v += floats(s, f, components: Array(0..<n), values: q, tag: "\(s).\(f) all")
            v += floats(s, f, components: [0], values: [.nan, 0], tag: "\(s).\(f)[0]")
        }
        for mode: Int64 in [-1, 0, 1, 2, 3, 4, 5, 6, 7, 99, 32767, -32768] {
            v.append(Variant(name: "Object.rotmode=\(mode)", edit: { d in d.set("Object", "rotmode") { _ in .int(mode) } }))
            v.append(Variant(name: "bPoseChannel.rotmode=\(mode)", edit: { d in d.set("bPoseChannel", "rotmode") { _ in .int(mode) } }))
        }
        run(v)
    }

    /// Armature matrices that are zero, NaN, infinite, singular (rank one, zero scale on one axis) or huge; bone lengths and bone matrices likewise; `parentinv` too.
    func testNonInvertibleAndNonFiniteMatricesOpenWithoutTrapping() {
        var v: [Variant] = []
        let all = Array(0..<16)
        v += floats("Bone", "arm_mat", components: all, values: [0, .nan, .infinity, 1e30, -1e30, 1e-40], tag: "arm_mat all")
        v += floats("Object", "parentinv", components: all, values: [0, .nan, .infinity, 1e30], tag: "parentinv all")
        v += floats("Object", "object_to_world", components: all, values: [0, .nan], tag: "object_to_world all")
        v += floats("bPoseChannel", "pose_mat", components: all, values: [0, .nan, .infinity], tag: "pose_mat all")
        v += floats("Bone", "bone_mat", components: Array(0..<9), values: [0, .nan, 1e30], tag: "bone_mat all")
        v += floats("Bone", "length", values: Self.extremes, tag: "bone length")
        v += floats("Bone", "head", components: [0, 1, 2], values: [.nan, 1e30], tag: "bone head") + floats("Bone", "tail", components: [0, 1, 2], values: [.nan, 1e30], tag: "bone tail")
        v += floats("Bone", "arm_roll", values: [.nan, 1e30], tag: "arm_roll")
        for k in [0, 5, 10, 15] { v += floats("Bone", "arm_mat", components: [k], values: [0, .nan], tag: "arm_mat diagonal \(k)") }
        v.append(Variant(name: "arm_mat rank one", edit: { d in guard let f = d.file.offset("Bone", "arm_mat") else { return 0 }; var n = 0; for e in d.elements("Bone") { for i in 0..<16 { d.put(Float(i % 4 == 0 ? 1 : 0), at: e.base + f + i * 4) }; n += 1 }; return n }))
        v.append(Variant(name: "arm_mat columns equal", edit: { d in guard let f = d.file.offset("Bone", "arm_mat") else { return 0 }; var n = 0; for e in d.elements("Bone") { for i in 0..<16 { d.put(Float(1), at: e.base + f + i * 4) }; n += 1 }; return n }))
        run(v)
    }

    /// Weights and shape keys: negative, NaN, infinite and huge vertex weights, shape-key values, slider limits and a key block that is its own reference.
    func testBadWeightsAndShapeKeyValuesOpenWithoutTrapping() {
        var v: [Variant] = []
        v += floats("MDeformWeight", "weight", values: [-1, -1e30, .nan, .infinity, -.infinity, 1e30, 0, -0.0], tag: "MDeformWeight.weight")
        v += floats("KeyBlock", "curval", values: Self.extremes, tag: "KeyBlock.curval")
        v += floats("KeyBlock", "slidermin", values: Self.extremes, tag: "KeyBlock.slidermin") + floats("KeyBlock", "slidermax", values: Self.extremes, tag: "KeyBlock.slidermax")
        v += floats("KeyBlock", "pos", values: Self.extremes, tag: "KeyBlock.pos")
        v += floats("Key", "ctime", values: Self.extremes, tag: "Key.ctime")
        v.append(Variant(name: "KeyBlock refers to itself", edit: { d in d.set("KeyBlock", "relative") { .int(Int64($0.index)) } }))
        v.append(Variant(name: "every weight on group 0 with maximum totweight", edit: { d in d.set("MDeformWeight", "def_nr") { _ in .int(0) } + d.set("MDeformVert", "totweight") { _ in .int(4097) } }))
        v.append(Variant(name: "every deform vertex shares one weight block", edit: { d in
            guard let first = d.file.blocks.first(where: { d.file.structure(of: $0)?.name == "MDeformWeight" }) else { return 0 }
            return d.set("MDeformVert", "dw") { _ in .pointer(first.old) } + d.set("MDeformVert", "totweight") { _ in .int(1_000_000) } }))
        run(v)
    }

    /// `rna_path` strings: unterminated, empty, huge, unbalanced quotes, trailing and doubled backslashes, odd bracket nesting, and paths into bones that do not exist.
    func testMalformedCurvePathsOpenWithoutTrapping() {
        let paths: [(String, [UInt8])] = [
            ("unterminated plain", Array("pose.bones[\"Bone".utf8)), ("no NUL no text terminator", Array(repeating: 0x41, count: 40)), ("empty", []), ("one NUL", [0]),
            ("open quote only", Array("pose.bones[\"".utf8) + [0]), ("unbalanced quote", Array("pose.bones[\"a\"b\"].location".utf8) + [0]),
            ("trailing backslash", Array("pose.bones[\"a\\".utf8) + [0]), ("escaped quote ends", Array("pose.bones[\"a\\\"].location".utf8) + [0]), ("doubled backslashes", Array("pose.bones[\"a\\\\\"].location".utf8) + [0]),
            ("only brackets", Array("[[[[]]]]\"\"\"\\\\".utf8) + [0]), ("close before open", Array("]\"].location[\"".utf8) + [0]),
            ("bone that does not exist", Array("pose.bones[\"nobody\"].rotation_quaternion".utf8) + [0]), ("bone with huge index property", Array("pose.bones[\"Bone\"].location".utf8) + [0]),
            ("shape key that does not exist", Array("key_blocks[\"nothing\"].value".utf8) + [0]), ("non UTF-8", [0xFF, 0xFE, 0xC0, 0x80, 0xED, 0xA0, 0x80, 0]),
            ("embedded NULs", Array("location".utf8) + [0, 0] + Array("rotation_euler".utf8) + [0]),
            ("one megabyte of open quotes", [UInt8](repeating: 0x22, count: 1 << 20)), ("one megabyte of a name", Array("pose.bones[\"".utf8) + [UInt8](repeating: 0x61, count: 1 << 20) + Array("\"].location".utf8) + [0]),
            ("one megabyte of backslashes", Array("pose.bones[\"".utf8) + [UInt8](repeating: 0x5C, count: 1 << 20) + [0]),
            ("one megabyte of brackets", [UInt8](repeating: 0x5B, count: 1 << 20) + [0]), ("one megabyte without NUL", [UInt8](repeating: 0x70, count: 1 << 20)),
            ("name of 70000 bones prefix", Array(String(repeating: "pose.bones[\"a\"].", count: 5000).utf8) + [0])]
        let v = paths.map { name, bytes in Variant(name: "rna_path \(name)", edit: { d in d.replaceTarget("FCurve", "rna_path", with: bytes) }) }
        run(v)
    }
}

/// Reproductions of what the fuzz pass found, kept as separate named tests so they fail on their own until the importer is fixed.
final class BlendAnimationBoneCycleReproTests: BlendHostileRun {
    private func timed(_ label: String, _ edit: @escaping Edit, limit: Double = 3) {
        guard let data = FuzzFiles.slim.first(where: { $0.name == "bar" })?.data, var doc = Doc(data) else { return XCTFail("bar") }
        XCTAssertGreaterThan(edit(&doc), 0)
        let start = Date()
        harness.run(label, doc.data, fixture: "bar", mustOpen: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), limit, "\(label) took too long")
    }

    /// FOUND: two bones that are each other's children (the armature's bone walk repeats them up to the 65,535 joint cap) hang the open for over 30 s.
    func testTwoBonesThatAreEachOthersChildrenOpenInUnderHalfASecond() {
        timed("repro: two bones children of each other", { d in
            let bones = d.elements("Bone"); guard bones.count >= 2, let f = d.file.offset("Bone", "childbase") else { return 0 }
            d.put(bones[1].address, at: bones[0].base + f); d.put(bones[0].address, at: bones[1].base + f); return 2 }, limit: 0.5)
    }

    /// FOUND: a bone that is its own first child takes about 2 s (and about 40 MB) to open, from the same duplicate-joint walk.
    func testABoneThatIsItsOwnChildOpensInUnderHalfASecond() {
        timed("repro: bone is its own child", { d in d.set("Bone", "childbase") { .pointer($0.address) } }, limit: 0.5)
    }
}
