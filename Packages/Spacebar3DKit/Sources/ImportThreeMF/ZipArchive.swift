import Compression
import Foundation

/// Reads the files of a zip archive, stored or deflated, which is what a 3MF package is.
struct ZipArchive {
    enum Failure: Error { case notZip, damaged, tooLarge }

    private let data: Data
    private struct Entry { var offset: Int; var packed: Int; var size: Int; var method: Int }
    private var entries: [String: Entry] = [:]
    /// Names as written in the archive, in its order.
    private(set) var names: [String] = []

    /// No single file of a package is unpacked beyond this.
    static let maxEntryBytes = 1 << 30

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw Failure.notZip }
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        // The directory's record is at the end, before a comment of at most 65,535 bytes.
        var end = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while end >= lowest, u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= lowest else { throw Failure.notZip }
        func u64(_ at: Int) -> Int? {
            let high = u32(at + 4)
            // Nothing here is anywhere near 2^62 bytes; a value that large is damage.
            return high < 0x4000_0000 ? u32(at) | high << 32 : nil
        }
        var count = u16(end + 10)
        var at = u32(end + 16)
        // Archives written with 64-bit records keep the real numbers in a second record,
        // found through a locator just before this one. Some writers use them for small
        // archives too.
        if (count == 0xffff || at == 0xffff_ffff), end >= 20, u32(end - 20) == 0x0706_4b50,
           let record = u64(end - 12), record >= 0, record + 56 <= data.count, u32(record) == 0x0606_4b50,
           let entries = u64(record + 32), let directory = u64(record + 48) {
            count = entries
            at = directory
        }
        guard count <= data.count / 46 else { throw Failure.damaged }
        for _ in 0..<count {
            guard at >= 0, at + 46 <= data.count, u32(at) == 0x0201_4b50 else { throw Failure.damaged }
            let method = u16(at + 10)
            var packed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32)
            var header = u32(at + 42)
            guard at + 46 + nameLength + extraLength <= data.count else { throw Failure.damaged }
            let name = String(decoding: data[(data.startIndex + at + 46)..<(data.startIndex + at + 46 + nameLength)], as: UTF8.self)
            // 64-bit values, for the fields that say so, follow in an extra field, in this order.
            var valid = true
            if size == 0xffff_ffff || packed == 0xffff_ffff || header == 0xffff_ffff {
                valid = false
                var extra = at + 46 + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let id = u16(extra), length = u16(extra + 2)
                    if id == 1 {
                        var field = extra + 4
                        valid = true
                        func take() -> Int? {
                            guard field + 8 <= extra + 4 + length, field + 8 <= extraEnd, let value = u64(field) else { return nil }
                            field += 8
                            return value
                        }
                        if size == 0xffff_ffff { if let v = take() { size = v } else { valid = false } }
                        if packed == 0xffff_ffff { if let v = take() { packed = v } else { valid = false } }
                        if header == 0xffff_ffff { if let v = take() { header = v } else { valid = false } }
                        break
                    }
                    extra += 4 + length
                }
            }
            if valid, method == 0 || method == 8 {
                if entries[name] == nil { names.append(name) }
                entries[name] = Entry(offset: header, packed: packed, size: size, method: method)
            }
            at += 46 + nameLength + extraLength + commentLength
        }
    }

    /// Finds a file by its path in the package ("/3D/3dmodel.model" or "3D/3dmodel.model"),
    /// whatever the case of its letters.
    func resolve(_ path: String) -> String? {
        let wanted = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if entries[wanted] != nil { return wanted }
        return names.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    func contents(of name: String) throws -> Data {
        guard let entry = entries[name] else { throw Failure.damaged }
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        let at = entry.offset
        guard at >= 0, at + 30 <= data.count, u16(at) == 0x4b50, u16(at + 2) == 0x0403 else { throw Failure.damaged }
        let start = at + 30 + u16(at + 26) + u16(at + 28)
        guard entry.packed >= 0, entry.size >= 0, start <= data.count, entry.packed <= data.count - start else { throw Failure.damaged }
        guard entry.size <= Self.maxEntryBytes else { throw Failure.tooLarge }
        let packed = data[(data.startIndex + start)..<(data.startIndex + start + entry.packed)]
        if entry.method == 0 {
            guard entry.packed == entry.size else { throw Failure.damaged }
            return Data(packed)
        }
        if entry.size == 0 { return Data() }
        var out = Data(count: entry.size)
        let written = out.withUnsafeMutableBytes { target in
            packed.withUnsafeBytes { source in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, entry.packed, nil, COMPRESSION_ZLIB)
            }
        }
        // The size the archive promised, no less: a short result is a damaged file.
        guard written == entry.size else { throw Failure.damaged }
        return out
    }
}
