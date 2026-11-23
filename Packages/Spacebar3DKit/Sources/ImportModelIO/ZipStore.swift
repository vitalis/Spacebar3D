import Foundation

/// Reads files out of a zip archive whose entries are stored without compression, which
/// is what a `.usdz` package is. Used to take a package's images still compressed, as
/// JPEG or PNG bytes, without anything decoding them first.
struct ZipStore {
    private let data: Data
    /// Name to (offset of the local header, size).
    private var entries: [String: (offset: Int, size: Int)] = [:]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 22 else { return nil }
        self.data = data
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        // The directory's record is at the end, before a comment of at most 65,535 bytes.
        var end = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while end >= lowest, u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= lowest else { return nil }
        let count = u16(end + 10), directory = u32(end + 16)
        var at = directory
        for _ in 0..<count {
            guard at >= 0, at + 46 <= data.count, u32(at) == 0x0201_4b50 else { return nil }
            let method = u16(at + 10), packed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32), header = u32(at + 42)
            guard at + 46 + nameLength <= data.count else { return nil }
            let name = String(decoding: data[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            // Stored entries only, and no 64-bit sizes.
            if method == 0, packed == size, size != 0xffff_ffff, header != 0xffff_ffff { entries[name] = (header, size) }
            at += 46 + nameLength + extraLength + commentLength
        }
    }

    /// The first stored entry (the package's default layer comes first) whose name ends in
    /// `.extension`, as a view into the mapped file, not a copy.
    func firstLayer(withExtension ext: String) -> Data? {
        let suffix = "." + ext.lowercased()
        guard let name = entries.filter({ $0.key.lowercased().hasSuffix(suffix) }).min(by: { $0.value.offset < $1.value.offset })?.key,
              let entry = entries[name] else { return nil }
        let at = entry.offset
        guard at >= 0, at + 30 <= data.count,
              Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 == 0x0403_4b50 else { return nil }
        let start = at + 30 + (Int(data[at + 26]) | Int(data[at + 27]) << 8) + (Int(data[at + 28]) | Int(data[at + 29]) << 8)
        guard start >= 0, entry.size >= 0, start + entry.size <= data.count else { return nil }
        return data[start..<(start + entry.size)]
    }

    func bytes(of name: String) -> [UInt8]? {
        guard let entry = entries[name] else { return nil }
        let at = entry.offset
        guard at >= 0, at + 30 <= data.count,
              Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 == 0x0403_4b50 else { return nil }
        let start = at + 30 + (Int(data[at + 26]) | Int(data[at + 27]) << 8) + (Int(data[at + 28]) | Int(data[at + 29]) << 8)
        guard start >= 0, entry.size >= 0, start + entry.size <= data.count else { return nil }
        return [UInt8](data[start..<(start + entry.size)])
    }
}
