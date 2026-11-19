import Foundation

/// Works out what kind of file a model is. The bytes decide wherever a format has a clear
/// signature; the file extension settles the rest.
///
/// The tests pin the cases one by one. Only the first 8192 bytes and the total length are used,
/// so a memory-mapped `Data` is cheap to pass.
public enum FormatDetector {
    /// - Parameters:
    ///   - data: the whole file (its length matters for STL and 3D Studio).
    ///   - ext: the file extension, lower-cased, without the dot; may be empty.
    public static func detect(_ data: Data, ext: String) -> Format {
        let bytes = [UInt8](data.prefix(8192))
        let length = data.count
        if starts(bytes, with: "glTF") { return .gltf }
        if isBlend(bytes) { return .blend }
        if starts(bytes, with: "PK\u{03}\u{04}") {
            // Both are zip archives: 3MF holds "3D/3dmodel.model", USDZ a .usd file.
            let names = Array(bytes.prefix(4096))
            return ext == "3mf" || contains(names, "3dmodel.model") || contains(names, "[Content_Types].xml") ? .threeMF : .usd
        }
        if starts(bytes, with: "PXR-USDC") || starts(bytes, with: "#usda") { return .usd }
        if starts(bytes, with: "ply\n") || starts(bytes, with: "ply\r\n") { return .ply }
        // The extension settles files the size rule misses (padding after the triangles, or none at all).
        if isSTL(bytes, length: length) || ext == "stl" { return .stl }
        // 3D Studio: a 0x4D4D chunk whose length is the whole file.
        if length > 6, bytes[0] == 0x4d, bytes[1] == 0x4d {
            if Int(littleEndian32(bytes, at: 2)) == length || ext == "3ds" { return .threeDS }
        }
        let head = Array(bytes.prefix(4096))
        if contains(head, "<COLLADA") { return .dae }
        if ext == "gltf" || head.first(where: { !isLatin1Space($0) }) == UInt8(ascii: "{") { return .gltfJSON }
        if isOBJ(bytes) { return .obj }
        if isFBX(bytes) { return .fbx }
        if ["usd", "usda", "usdc", "usdz"].contains(ext) { return .usd }
        return .gltf
    }

    /// True for a glTF file (either form) that is a VRM avatar or a VRM animation: its
    /// description names one of the VRM extensions. Such a file is glTF to `detect`, but
    /// needs the VRM reader.
    public static func isVRM(_ data: Data) -> Bool { names(["\"VRM\"", "\"VRMC_vrm\"", "\"VRMC_vrm_animation\""], in: data) }

    /// True for a glTF file that is a VRM animation (`.vrma`): motion for an avatar, with
    /// no avatar of its own.
    public static func isVRMAnimation(_ data: Data) -> Bool { names(["\"VRMC_vrm_animation\""], in: data) }

    /// Whether the description of a glTF file has one of `names` in it.
    private static func names(_ names: [String], in data: Data) -> Bool {
        // The description: the first chunk of the binary form, or the whole text form.
        var json = data
        if data.count >= 20, data.prefix(4).elementsEqual("glTF".utf8) {
            let s = data.startIndex
            let length = Int(data[s + 12]) | Int(data[s + 13]) << 8 | Int(data[s + 14]) << 16 | Int(data[s + 15]) << 24
            guard length > 0, 20 + length <= data.count else { return false }
            json = data.subdata(in: (s + 20)..<(s + 20 + length))
        }
        guard json.count <= 256 * 1024 * 1024 else { return false }
        return json.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            for name in names {
                let needle = Array(name.utf8)
                if memmem(base, raw.count, needle, needle.count) != nil { return true }
            }
            return false
        }
    }

    /// Uncompressed .blend files start with "BLENDER"; saved compressed they are zstd or gzip streams.
    public static func isBlend(_ data: Data) -> Bool { isBlend([UInt8](data.prefix(8))) }

    /// FBX from the leading bytes (GLB and VRM start with the "glTF" magic).
    public static func isFBX(_ data: Data) -> Bool { isFBX([UInt8](data.prefix(64))) }

    /// Wavefront OBJ: plain text whose lines start with OBJ keywords.
    public static func isOBJ(_ data: Data) -> Bool { isOBJ([UInt8](data.prefix(8192))) }

    /// STL. Binary: an 80-byte header, a triangle count, then 50 bytes per triangle, which
    /// fixes the file size exactly. Text: starts with "solid" and has facets.
    public static func isSTL(_ data: Data) -> Bool { isSTL([UInt8](data.prefix(1024)), length: data.count) }

    // MARK: - Byte-level checks

    static func isBlend(_ bytes: [UInt8]) -> Bool {
        if starts(bytes, with: "BLENDER") { return true }
        let zstd = bytes.count >= 4 && bytes[0] == 0x28 && bytes[1] == 0xb5 && bytes[2] == 0x2f && bytes[3] == 0xfd
        let gzip = bytes.count >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
        return zstd || gzip
    }

    static func isFBX(_ bytes: [UInt8]) -> Bool {
        // Checked first because the JSON chunk of a GLB can mention FBX near the start
        // (for example the generator "FBX2glTF").
        if starts(bytes, with: "glTF") { return false }
        // Binary FBX: "Kaydara FBX Binary  \0"
        let signature = "Kaydara FBX Binary"
        if bytes.count > signature.utf8.count, starts(bytes, with: signature) { return true }
        // Text FBX: mentions "FBX" near the start.
        return contains(Array(bytes.prefix(64)), "FBX")
    }

    static func isOBJ(_ bytes: [UInt8]) -> Bool {
        let head = bytes.prefix(8192)
        // Binary formats (GLB, binary FBX) contain NUL bytes early on; OBJ is text.
        if head.isEmpty || head.contains(0) { return false }
        let text = scalars(head)
        if text.starts(with: "glTF".unicodeScalars) || contains(Array(head), "FBXHeaderExtension") { return false }
        // A line that starts with an OBJ keyword, then spaces or tabs, then something.
        let keywords = ["mtllib", "usemtl", "vn", "vt", "v", "f", "o", "g"].map { Array($0.unicodeScalars) }
        var lineStart = 0
        while lineStart <= text.count {
            var at = lineStart
            while at < text.count, text[at] == " " || text[at] == "\t" { at += 1 }
            for keyword in keywords where text[at...].starts(with: keyword) {
                var after = at + keyword.count
                let gapStart = after
                while after < text.count, text[after] == " " || text[after] == "\t" { after += 1 }
                if after > gapStart, after < text.count, !isSpace(text[after]) { return true }
            }
            guard let next = text[lineStart...].firstIndex(where: isLineEnd) else { break }
            lineStart = next + 1
        }
        return false
    }

    static func isSTL(_ bytes: [UInt8], length: Int) -> Bool {
        if length >= 84, bytes.count >= 84 {
            let count = Int(littleEndian32(bytes, at: 80))
            if count > 0, 84 + count * 50 == length { return true }
        }
        let text = scalars(bytes.prefix(1024))
        // Starts with "solid" as a whole word, after any white space.
        var at = 0
        while at < text.count, isSpace(text[at]) { at += 1 }
        let solid = Array("solid".unicodeScalars)
        guard text[at...].starts(with: solid), at + solid.count == text.count || !isWord(text[at + solid.count]) else { return false }
        // "facet", white space, "normal", each as whole words.
        let facet = Array("facet".unicodeScalars), normal = Array("normal".unicodeScalars)
        var search = 0
        while search + facet.count <= text.count {
            if text[search...].starts(with: facet), search == 0 || !isWord(text[search - 1]) {
                var after = search + facet.count
                let gapStart = after
                while after < text.count, isSpace(text[after]) { after += 1 }
                if after > gapStart, text[after...].starts(with: normal),
                   after + normal.count == text.count || !isWord(text[after + normal.count]) { return true }
            }
            search += 1
        }
        return false
    }

    // MARK: - Helpers

    private static func starts(_ bytes: [UInt8], with prefix: String) -> Bool { bytes.starts(with: Array(prefix.utf8)) }

    private static func contains(_ bytes: [UInt8], _ text: String) -> Bool {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        return (0...(bytes.count - needle.count)).contains { bytes[$0...].starts(with: needle) }
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// The bytes as text: UTF-8 with invalid bytes
    /// replaced, and a leading byte-order mark dropped.
    private static func scalars(_ bytes: ArraySlice<UInt8>) -> [Unicode.Scalar] {
        var out = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        if out.first == "\u{FEFF}" { out.removeFirst() }
        return out
    }

    /// White space as JavaScript's `\s` defines it.
    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: return true
        default: return false
        }
    }

    /// Line ends as JavaScript's multi-line `^` defines them.
    private static func isLineEnd(_ s: Unicode.Scalar) -> Bool { s == "\n" || s == "\r" || s.value == 0x2028 || s.value == 0x2029 }

    /// Word characters as JavaScript's `\b` defines them.
    private static func isWord(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "_"
    }

    /// White space among single bytes read as Latin-1.
    private static func isLatin1Space(_ byte: UInt8) -> Bool { (0x09...0x0d).contains(byte) || byte == 0x20 || byte == 0xa0 }
}
