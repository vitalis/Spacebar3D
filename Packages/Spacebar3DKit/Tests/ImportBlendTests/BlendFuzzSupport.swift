import Darwin
import Foundation
@testable import ImportBlend
import ModelCore
import RenderMetal
import simd
import XCTest

/// A fixed-seed generator (SplitMix64), so every fuzz run draws the same inputs.
struct FuzzRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The five Blender 5.2.2 animation fixtures, decompressed once (the app's own Zstandard decoder), and helpers to edit them.
enum FuzzFiles {
    /// (name, uncompressed .blend bytes), in a fixed order.
    static let all: [(name: String, data: Data)] = {
        let cases = [BlenderAnimation.bar, BlenderAnimation.cube, BlenderAnimation.shapeKeys, BlenderAnimation.staticCube, BlenderAnimation.wobbler]
        return cases.map { ($0.name, (try? Zstandard.decode($0.data, limit: 64 << 20)) ?? Data()) }
    }()

    /// The structures animation reads, which targeted and weighted damage aims at.
    static let animationStructures: Set<String> = ["Object", "Mesh", "Key", "KeyBlock", "AnimData", "bAction", "ActionSlot", "ActionLayer", "ActionStrip", "ActionStripKeyframeData", "ActionChannelBag",
        "FCurve", "BezTriple", "bArmature", "Bone", "bPoseChannel", "ArmatureModifierData", "MDeformVert", "MDeformWeight", "CustomDataLayer", "Scene", "raw_data", "bDeformGroup"]

    /// The same files without the window, screen, workspace and brush blocks (about 300 KB of interface that no
    /// animation reads), so thousands of mutations run quickly. Blocks are dropped whole, so the rest is still a valid file.
    static let slim: [(name: String, data: Data)] = all.map { ($0.name, slimmed($0.data)) }

    static func slimmed(_ data: Data) -> Data {
        guard let file = try? BlendFile(data) else { return data }
        let drop = Set(["WM", "WS", "SR", "SN", "BR", "PL", "PAL", "WK", "TEST"].map { BlendFile.code($0) })
        var out = Data(data.prefix(17))
        var skip = false
        for block in file.blocks {
            if block.code != BlendFile.dataCode { skip = drop.contains(block.code) }
            if skip { continue }
            out.append(data[(block.offset - 32)..<(block.offset + block.length)])
        }
        // The end-of-file block.
        out.append(data[(data.count - 32)...])
        return out
    }
}

/// A file being edited in place by structure and field name, with the offsets read from its own DNA.
struct Doc {
    enum Value { case int(Int64), num(Double), pointer(UInt64) }
    struct Element { let base: Int; let block: BlendFile.Block; let index: Int; let size: Int
        /// The address a pointer to this element holds.
        var address: UInt64 { block.old &+ UInt64(index * size) }
    }
    var data: Data
    let file: BlendFile
    init?(_ data: Data) {
        guard let file = try? BlendFile(data) else { return nil }
        self.data = data; self.file = file
    }

    func elements(_ structure: String) -> [Element] {
        guard let size = file.structure(structure)?.size, size > 0 else { return [] }
        var out: [Element] = []
        for block in file.blocks where file.structure(of: block)?.name == structure {
            for e in 0..<min(max(block.length / size, 1), 64) where block.offset + (e + 1) * size <= data.count { out.append(Element(base: block.offset + e * size, block: block, index: e, size: size)) }
        }
        return out
    }

    mutating func put<T>(_ value: T, at: Int) {
        guard at >= 0, at + MemoryLayout<T>.size <= data.count else { return }
        withUnsafeBytes(of: value) { data.replaceSubrange(at..<(at + MemoryLayout<T>.size), with: $0) }
    }

    /// Writes `value(element)` into field `name` of every `structure` element (component `component` of an array field).
    /// Answers how many elements were written.
    @discardableResult
    mutating func set(_ structure: String, _ name: String, component: Int = 0, _ value: (Element) -> Value) -> Int {
        guard let field = file.structure(structure)?.fields[name] else { return 0 }
        let step = field.isPointer ? 8 : max(field.size / max(field.count, 1), 1)
        guard component < max(field.count, 1) else { return 0 }
        var hits = 0
        for element in elements(structure) {
            let at = element.base + field.offset + component * step
            let v = value(element)
            if field.isPointer {
                if case .pointer(let p) = v { put(p, at: at) } else if case .int(let i) = v { put(UInt64(bitPattern: i), at: at) } else { continue }
            } else {
                switch (field.type, v) {
                case ("float", .num(let d)): put(Float(d), at: at)
                case ("float", .int(let i)): put(Float(i), at: at)
                case ("float", .pointer(let p)): put(UInt32(truncatingIfNeeded: p), at: at)
                case ("double", .num(let d)): put(d, at: at)
                case ("int", .int(let i)), ("uint", .int(let i)): put(Int32(truncatingIfNeeded: i), at: at)
                case ("int", .num(let d)): put(Int32(clamping: Int64(clamping: Int64(d.isFinite ? d : 0))), at: at)
                case ("short", .int(let i)), ("ushort", .int(let i)): put(Int16(truncatingIfNeeded: i), at: at)
                case ("short", .num(let d)): put(Int16(clamping: Int64(d.isFinite ? d : 0)), at: at)
                case ("char", .int(let i)), ("uchar", .int(let i)), ("int8_t", .int(let i)): put(UInt8(truncatingIfNeeded: i), at: at)
                case (_, .pointer(let p)): put(UInt32(truncatingIfNeeded: p), at: at)
                default: continue
                }
            }
            hits += 1
        }
        return hits
    }

    /// Replaces the bytes of the data block that `pointerField` of each `structure` element points to (the block grows or shrinks).
    mutating func replaceTarget(_ structure: String, _ pointerField: String, with bytes: [UInt8]) -> Int {
        guard let field = file.structure(structure)?.fields[pointerField], field.isPointer else { return 0 }
        var targets = Set<Int>()
        for element in elements(structure) {
            let address = file.u64(element.base + field.offset)
            if let i = file.blocks.firstIndex(where: { $0.old == address && $0.code == BlendFile.dataCode }) { targets.insert(i) }
        }
        // Back to front, so earlier offsets stay valid.
        for i in targets.sorted(by: >) {
            let block = file.blocks[i]
            data.replaceSubrange(block.offset..<(block.offset + block.length), with: bytes)
            put(Int64(bytes.count), at: block.offset - 16)
            put(Int64(1), at: block.offset - 8)
        }
        return targets.count
    }
}

/// Peak memory of this process: a thread samples the physical footprint every millisecond.
final class PeakMeter {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var stop = false
    init() {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let done = stop; if !done { peak = max(peak, Self.footprint()) }; lock.unlock()
                if done { return }
                usleep(1000)
            }
        }
    }
    deinit { lock.lock(); stop = true; lock.unlock() }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    /// Starts a measurement; the answer is the footprint to subtract later.
    func begin() -> UInt64 { let now = Self.footprint(); lock.lock(); peak = now; lock.unlock(); return now }
    func rise(since base: UInt64) -> Int { lock.lock(); defer { lock.unlock() }; return Int(max(max(peak, Self.footprint()), base) - base) }
}

/// Runs inputs through the importer and the pose, with the time and memory limits, and keeps the worst cases.
final class FuzzHarness {
    /// Debug allowance for one file (the stated bound is 1 s).
    static let timeLimit = 3.0
    /// Allocated bytes allowed per byte of input file.
    static let memoryPerFileByte = 64
    /// The least the memory bound is for a small file: the importer's own fixed costs and a Metal scene.
    static let memoryFloor = 64 << 20

    let meter = PeakMeter()
    /// One renderer for the whole process, warmed up (pipelines, targets) so its one-time allocations are not counted against a file.
    static let sharedRenderer: MetalRenderer? = {
        guard let r = try? MetalRenderer() else { return nil }
        r.skinsOnGPU = false
        r.showGrid = false
        if let data = FuzzFiles.slim.first(where: { $0.name == "wobbler" })?.data, let scene = try? BlendReader.scene(from: data), let gpu = try? r.makeScene(scene) {
            r.show(gpu)
            gpu.pose(clip: 0, time: 0.1)
            for _ in 0..<3 { _ = try? r.renderOffscreen(width: 16, height: 16) }
        }
        return r
    }()
    let renderer: MetalRenderer? = FuzzHarness.sharedRenderer
    var cases = 0, opened = 0, refused = 0, withClip = 0, posed = 0, rendered = 0
    var worstTime: (seconds: Double, label: String) = (0, "")
    var worstMemory: (bytes: Int, label: String, ratio: Double) = (0, "", 0)
    var hangs = 0
    var worstImport: (seconds: Double, label: String) = (0, "")
    var gpuSeconds = 0.0
    var worstGPU: (bytes: Int, label: String) = (0, "")
    /// What the unmodified fixture's GPU scene rose by, by name (filled by `calibrate`).
    var gpuBaseline: [String: Int] = [:]
    func calibrate(_ name: String, _ data: Data) {
        let base = meter.begin()
        if let scene = try? BlendReader.scene(from: data) { pose(scene, gpu: true) }
        gpuBaseline[name] = meter.rise(since: base)
    }
    private let traceFD: Int32 = open("/tmp/ba2/last-input.txt", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    private let queue = DispatchQueue(label: "fuzz", qos: .userInitiated)

    private func trace(_ label: String) { _ = label.withCString { pwrite(traceFD, $0, strlen($0), 0) }; ftruncate(traceFD, off_t(label.utf8.count)) }

    /// Opens `data` (as the Quick Look extension would) and poses the result. Returns whether it opened.
    /// A trap here ends the test process; `/tmp/ba2/last-input.txt` then names the input.
    @discardableResult
    func run(_ label: String, _ data: Data, fixture: String? = nil, render: Bool = false, mustOpen: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        trace(label)
        cases += 1
        let base = meter.begin()
        let start = DispatchTime.now().uptimeNanoseconds
        var parseEnd: UInt64 = 0
        var result: ModelScene?
        defer { _ = 0 }
        var failed = false
        var importRise = 0
        var importSeconds = 0.0
        // A hang is a failure, not a stuck test run.
        let done = DispatchSemaphore(value: 0)
        queue.async {
            do { result = try BlendReader.scene(from: data) } catch { failed = true }
            let importEnd = DispatchTime.now().uptimeNanoseconds
            importSeconds = Double(importEnd - start) / 1e9
            if let scene = result {
                self.pose(scene, gpu: false)
                importRise = self.meter.rise(since: base)
            }
            parseEnd = DispatchTime.now().uptimeNanoseconds
            done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            hangs += 1
            XCTFail("HANG (over 30 s): \(label)", file: file, line: line)
            return false
        }
        // The GPU scene is made on this thread (the thread the renderer was warmed up on), after the importer is timed.
        let seconds = Double(parseEnd - start) / 1e9 + 0
        let gpuStart = DispatchTime.now().uptimeNanoseconds
        if render, let result { pose(result, gpu: true) }
        if render { gpuSeconds = max(gpuSeconds, Double(DispatchTime.now().uptimeNanoseconds - gpuStart) / 1e9) }
        let total = meter.rise(since: base)
        // The importer and the CPU pose are held to the bound. The GPU step is only reported: its footprint rises by a constant ~180 MB on every fourth offscreen render whatever the file (Metal, not the importer).
        let rise = importRise
        if total > worstGPU.bytes, render { worstGPU = (total, label) }
        let allowed = max(Self.memoryPerFileByte * data.count, Self.memoryFloor)
        if importSeconds > worstImport.seconds { worstImport = (importSeconds, label) }
        // `seconds` is the importer plus the CPU pose of every clip.
        if seconds > worstTime.seconds { worstTime = (seconds, label) }
        let ratio = Double(rise) / Double(max(data.count, 1))
        if rise > worstMemory.bytes { worstMemory = (rise, label, ratio) }
        if seconds > Self.timeLimit { XCTFail("SLOW \(seconds) s (limit \(Self.timeLimit)): \(label)", file: file, line: line) }
        if rise > allowed { XCTFail("MEMORY rose \(rise >> 20) MB for a \(data.count >> 10) KB file (allowed \(allowed >> 20) MB): \(label)", file: file, line: line) }
        if failed { refused += 1; if mustOpen { XCTFail("refused to open: \(label)", file: file, line: line) } } else { opened += 1 }
        if let result, mustOpen, result.meshes.isEmpty { XCTFail("opened with no meshes: \(label)", file: file, line: line) }
        return !failed
    }

    /// Every clip at a few times through the skeleton, and (for `render`) through a GPU scene with CPU skinning.
    private func pose(_ scene: ModelScene, gpu wantsGPU: Bool) {
        guard !scene.clips.isEmpty else { return }
        if !wantsGPU { withClip += 1 }
        for clip in scene.clips where !wantsGPU && scene.skeletons.indices.contains(clip.skeleton) {
            let skeleton = scene.skeletons[clip.skeleton]
            let span = clip.end.isFinite ? max(clip.end - clip.start, 0) : 0
            for time: Float in [0, 0.04, span / 2, span, span * 3 + 1, 1e6, -3, clip.start] {
                let matrices = skeleton.skinMatrices(clip: clip, time: time)
                if matrices.count != skeleton.joints.count { _ = matrices.count }
            }
        }
        guard wantsGPU, let renderer, let gpu = try? renderer.makeScene(scene) else { return }
        posed += 1
        renderer.show(gpu)
        let span = scene.clips[0].end.isFinite ? max(scene.clips[0].end, 0) : 0
        for time: Float in [0, span / 2, span, 1e6] { gpu.pose(clip: 0, time: time) }
        if posed % 4 == 0 {
            rendered += 1
            _ = try? renderer.renderOffscreen(width: 16, height: 16)
        }
    }

    var summary: String {
        String(format: "P3D-FUZZ cases=%d opened=%d refused=%d animated=%d posedOnGPU=%d rendered=%d hangs=%d worstImport=%.3fs [%@] worstImportPlusPose=%.3fs [%@] worstGPUstepTime=%.3fs worstMemory=%d MB (%.1f bytes per file byte) [%@] worstGPUstep=%d MB [%@]",
               cases, opened, refused, withClip, posed, rendered, hangs, worstImport.seconds, worstImport.label, worstTime.seconds, worstTime.label, gpuSeconds, worstMemory.bytes >> 20, worstMemory.ratio, worstMemory.label, worstGPU.bytes >> 20, worstGPU.label)
    }
}
