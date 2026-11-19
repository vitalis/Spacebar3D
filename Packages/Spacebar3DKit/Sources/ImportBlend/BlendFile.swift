import ModelCore
import Compression
import Foundation
import simd

/// A .blend file opened: its blocks and the description of its own structures (the
/// `DNA1` block). Nothing about a Blender version's layout is written here except the
/// names of the fields looked for; every offset comes from the file.
///
/// The file is not trusted: every read is checked against the file's size and gives zero
/// outside it, lists stop at a limit, and nothing here traps on a damaged file.
final class BlendFile {
    struct Field { let type: String; let offset: Int; let size: Int; let isPointer: Bool; let count: Int }
    struct Structure { let name: String; let size: Int; var fields: [String: Field] }
    struct Block { let code: UInt32; let offset: Int; let length: Int; let old: UInt64; let sdna: Int; let count: Int }

    static let maxBlocks = 8_000_000
    static let maxStructures = 20_000
    static let maxListLength = 1_000_000
    /// What a compressed file may unpack to.
    static let maxUnpackedBytes = 2 * 1024 * 1024 * 1024

    let bytes: Data
    private(set) var pointerSize = 8
    /// 280 for Blender 2.80, 402 for 4.2, 500 for 5.0.
    private(set) var version = 0
    private(set) var blocks: [Block] = []
    private var structures: [Structure] = []
    private var structureIndex: [String: Int] = [:]
    /// An address the file was written from names a block only among the blocks of one
    /// data-block (Blender reuses temporary memory while writing), so every block knows the
    /// data-block it belongs to and a pointer is resolved among its own first.
    private var byAddress: [UInt64: [Int32]] = [:]
    private var owner: [Int32] = []
    /// The data-block whose pointers are being followed.
    var currentOwner = -1

    static func code(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        for (i, byte) in text.utf8.prefix(4).enumerated() { value |= UInt32(byte) << (8 * UInt32(i)) }
        return value
    }
    static let dataCode = code("DATA"), endCode = code("ENDB"), dnaCode = code("DNA1")

    init(_ data: Data) throws {
        bytes = data
        guard data.count > 32, data.prefix(7).elementsEqual("BLENDER".utf8) else { throw BlendReader.Failure.notBlend }
        var cursor: Int
        var large = false
        let eighth = u8(7)
        if eighth == UInt8(ascii: "-") || eighth == UInt8(ascii: "_") {
            // Up to 4.x: BLENDER, pointer size (_ four bytes, - eight), byte order (v little), three digits.
            pointerSize = eighth == UInt8(ascii: "_") ? 4 : 8
            guard u8(8) == UInt8(ascii: "v") else { throw BlendReader.Failure.unsupported(L10n.text("it was saved on a big-endian computer")) }
            version = Int(text(9, 3)) ?? 0
            cursor = 12
        } else {
            // 5.0 on: BLENDER, header size (two digits), '-', format version (two digits), 'v', four digits.
            large = true
            guard u8(12) == UInt8(ascii: "v") else { throw BlendReader.Failure.unsupported(L10n.text("it was saved on a big-endian computer")) }
            let headerSize = Int(text(7, 2)) ?? 17
            version = Int(text(13, 4)) ?? 0
            guard headerSize >= 17, headerSize <= 64 else { throw BlendReader.Failure.damaged }
            cursor = headerSize
        }
        var dna: Block?
        while cursor + 16 <= data.count, blocks.count < Self.maxBlocks {
            let code = u32(cursor)
            let block: Block
            if large {
                // code, structure index, old address, length (64-bit), count (64-bit)
                let length = i64(cursor + 16), count = i64(cursor + 24)
                guard length >= 0, length <= Int64(data.count), count >= 0, count <= Int64(data.count) else { throw BlendReader.Failure.damaged }
                block = Block(code: code, offset: cursor + 32, length: Int(length), old: u64(cursor + 8), sdna: Int(i32(cursor + 4)), count: Int(count))
            } else if pointerSize == 8 {
                block = Block(code: code, offset: cursor + 24, length: Int(i32(cursor + 4)), old: u64(cursor + 8), sdna: Int(i32(cursor + 16)), count: Int(i32(cursor + 20)))
            } else {
                block = Block(code: code, offset: cursor + 20, length: Int(i32(cursor + 4)), old: UInt64(u32(cursor + 8)), sdna: Int(i32(cursor + 12)), count: Int(i32(cursor + 16)))
            }
            if code == Self.endCode { break }
            guard block.length >= 0, block.count >= 0, block.offset <= data.count, block.length <= data.count - block.offset else { throw BlendReader.Failure.damaged }
            if code == Self.dnaCode { dna = block }
            byAddress[block.old, default: []].append(Int32(blocks.count))
            owner.append(code == Self.dataCode ? (owner.last ?? 0) : Int32(blocks.count))
            blocks.append(block)
            cursor = block.offset + block.length
        }
        guard let dna else { throw BlendReader.Failure.damaged }
        try parseDNA(dna)
    }

    // MARK: Reading values

    private func load<T>(_ at: Int, as type: T.Type) -> T? {
        guard at >= 0, at <= bytes.count - MemoryLayout<T>.size else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: T.self) }
    }
    func u8(_ at: Int) -> UInt8 { load(at, as: UInt8.self) ?? 0 }
    func i16(_ at: Int) -> Int16 { load(at, as: Int16.self) ?? 0 }
    func i32(_ at: Int) -> Int32 { load(at, as: Int32.self) ?? 0 }
    func u32(_ at: Int) -> UInt32 { load(at, as: UInt32.self) ?? 0 }
    func i64(_ at: Int) -> Int64 { load(at, as: Int64.self) ?? 0 }
    func u64(_ at: Int) -> UInt64 { load(at, as: UInt64.self) ?? 0 }
    func f32(_ at: Int) -> Float { load(at, as: Float.self) ?? 0 }
    func pointer(_ at: Int) -> UInt64 { pointerSize == 8 ? u64(at) : UInt64(u32(at)) }
    func floats(_ at: Int, _ count: Int) -> [Float] { (0..<count).map { f32(at + $0 * 4) } }
    func vector(_ at: Int) -> SIMD3<Float> { SIMD3(f32(at), f32(at + 4), f32(at + 8)) }
    func matrix(_ at: Int) -> simd_float4x4 {
        let v = floats(at, 16)
        return simd_float4x4(SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]), SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
    }
    /// Text up to its first zero byte, within `size` bytes.
    func text(_ at: Int, _ size: Int) -> String {
        guard at >= 0, size > 0, at < bytes.count else { return "" }
        let end = min(at + size, bytes.count)
        return String(decoding: bytes[(bytes.startIndex + at)..<(bytes.startIndex + end)].prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: The file's own description of its structures

    private func parseDNA(_ dna: Block) throws {
        var at = dna.offset
        let end = dna.offset + dna.length
        func tag(_ expected: String) throws {
            guard at + 4 <= end, text(at, 4) == expected else { throw BlendReader.Failure.damaged }
            at += 4
        }
        func align() { at = dna.offset + ((at - dna.offset + 3) & ~3) }
        func strings() throws -> [String] {
            let count = Int(i32(at)); at += 4
            guard count >= 0, count <= dna.length else { throw BlendReader.Failure.damaged }
            var out: [String] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                var stop = at
                while stop < end, u8(stop) != 0 { stop += 1 }
                guard stop < end else { throw BlendReader.Failure.damaged }
                out.append(text(at, stop - at + 1))
                at = stop + 1
            }
            align()
            return out
        }
        try tag("SDNA"); try tag("NAME")
        let names = try strings()
        try tag("TYPE")
        let types = try strings()
        try tag("TLEN")
        guard at + types.count * 2 <= end else { throw BlendReader.Failure.damaged }
        let lengths = (0..<types.count).map { Int(UInt16(bitPattern: i16(at + $0 * 2))) }
        at += types.count * 2
        align()
        try tag("STRC")
        let count = Int(i32(at)); at += 4
        guard count >= 0, count <= Self.maxStructures else { throw BlendReader.Failure.damaged }
        for _ in 0..<count {
            guard at + 4 <= end else { throw BlendReader.Failure.damaged }
            let type = Int(i16(at)), fieldCount = Int(i16(at + 2)); at += 4
            guard types.indices.contains(type), fieldCount >= 0, at + fieldCount * 4 <= end else { throw BlendReader.Failure.damaged }
            var info = Structure(name: types[type], size: lengths[type], fields: [:])
            var offset = 0
            for _ in 0..<fieldCount {
                let fieldType = Int(i16(at)), nameIndex = Int(i16(at + 2)); at += 4
                guard types.indices.contains(fieldType), names.indices.contains(nameIndex) else { throw BlendReader.Failure.damaged }
                let raw = names[nameIndex]
                // "*next", "(*func)()", "co[3]", "mat[4][4]"
                let isPointer = raw.hasPrefix("*") || raw.hasPrefix("(")
                var name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "*("))
                var elements = 1
                while let open = name.lastIndex(of: "["), let close = name.lastIndex(of: "]"), open < close {
                    guard let dimension = Int(name[name.index(after: open)..<close]), dimension > 0,
                          dimension <= (1 << 24) / elements else { throw BlendReader.Failure.damaged }
                    elements *= dimension
                    name = String(name[..<open]) + String(name[name.index(after: close)...])
                }
                if let paren = name.firstIndex(of: ")") { name = String(name[..<paren]) }
                let size = (isPointer ? pointerSize : lengths[fieldType]) * elements
                info.fields[name] = Field(type: types[fieldType], offset: offset, size: size, isPointer: isPointer, count: elements)
                offset += size
            }
            structureIndex[info.name] = structures.count
            structures.append(info)
        }
    }

    func structure(_ name: String) -> Structure? { structureIndex[name].map { structures[$0] } }
    /// The structure a block's bytes are, by the block's own word.
    func structure(of block: Block) -> Structure? { structures.indices.contains(block.sdna) ? structures[block.sdna] : nil }
    /// The offset of the first of these fields the structure has (their names changed over the versions).
    func offset(_ structure: String, _ names: String...) -> Int? {
        guard let s = self.structure(structure) else { return nil }
        return names.lazy.compactMap { s.fields[$0]?.offset }.first
    }

    // MARK: Following pointers

    /// The block a pointer leads to, among the blocks of the data-block being read. A
    /// pointer whose target was not written (it happens) stays unresolved.
    func block(at address: UInt64) -> Block? {
        guard address != 0, let candidates = byAddress[address] else { return nil }
        return candidates.first { Int(owner[Int($0)]) == currentOwner }.map { blocks[Int($0)] }
    }

    /// A data-block (an object, a mesh, a material, an image) by its address, and its place among the blocks.
    func dataBlock(at address: UInt64) -> (index: Int, block: Block)? {
        guard address != 0, let candidates = byAddress[address], let i = candidates.first(where: { blocks[Int($0)].code != Self.dataCode }) else { return nil }
        return (Int(i), blocks[Int(i)])
    }

    /// Every data-block of a kind ("OB", "ME", "SC"), in the file's order.
    func dataBlocks(_ code: String) -> [(index: Int, block: Block)] {
        let wanted = Self.code(code)
        return blocks.enumerated().filter { $0.element.code == wanted }.map { ($0.offset, $0.element) }
    }

    /// The name of a data-block, without the two letters of its kind.
    func name(of block: Block) -> String {
        guard let field = structure("ID")?.fields["name"] else { return "" }
        return String(text(block.offset + field.offset, field.size).dropFirst(2))
    }

    /// The elements of a linked list, each beginning with the pointer to the next.
    func list(_ first: UInt64) -> [(address: UInt64, block: Block)] {
        var out: [(UInt64, Block)] = [], at = first
        var seen = Set<UInt64>()
        while out.count < Self.maxListLength, seen.insert(at).inserted, let b = block(at: at) {
            out.append((at, b))
            at = pointer(b.offset)
        }
        return out
    }

    // MARK: Compressed files

    /// A file saved compressed, unpacked: gzip (before Blender 3.0) with the system's
    /// zlib, Zstandard (3.0 on) with the reference decoder.
    static func unpacked(_ data: Data) throws -> Data {
        if Zstandard.isCompressed(data) {
            do { return try Zstandard.decode(data, limit: maxUnpackedBytes) } catch Zstandard.Failure.tooLarge { throw BlendReader.Failure.tooLarge } catch { throw BlendReader.Failure.damaged }
        }
        guard data.count >= 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
        return try gunzip(data)
    }

    private static func gunzip(_ data: Data) throws -> Data {
        // The gzip wrapper around the deflate stream: ten bytes, then what the flags say follows.
        let b = [UInt8](data.prefix(10))
        guard b[2] == 8 else { throw BlendReader.Failure.damaged }
        let flags = b[3]
        var at = 10
        func byte(_ i: Int) -> UInt8? { i < data.count ? data[data.startIndex + i] : nil }
        if flags & 4 != 0 {
            guard let low = byte(at), let high = byte(at + 1) else { throw BlendReader.Failure.damaged }
            at += 2 + Int(low) + Int(high) << 8
        }
        for flag in [UInt8(8), 16] where flags & flag != 0 {
            while let c = byte(at), c != 0 { at += 1 }
            at += 1
        }
        if flags & 2 != 0 { at += 2 }
        guard at < data.count - 8 else { throw BlendReader.Failure.damaged }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw BlendReader.Failure.damaged }
        defer { compression_stream_destroy(stream) }
        let chunk = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out = Data()
        let failure: BlendReader.Failure? = data.withUnsafeBytes { raw -> BlendReader.Failure? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return .damaged }
            stream.pointee.src_ptr = base + at
            stream.pointee.src_size = raw.count - at
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { return .damaged }
                out.append(buffer, count: chunk - stream.pointee.dst_size)
                if out.count > maxUnpackedBytes { return .tooLarge }
                if status == COMPRESSION_STATUS_END { return nil }
                // No more to read and nothing written: the stream ends short.
                if stream.pointee.src_size == 0, stream.pointee.dst_size == chunk { return .damaged }
            }
        }
        if let failure { throw failure }
        return out
    }
}
