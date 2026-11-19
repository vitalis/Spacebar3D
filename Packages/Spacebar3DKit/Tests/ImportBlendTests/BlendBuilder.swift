import Foundation

/// Writes small .blend files for the tests: a header, blocks, and a description of the
/// structures used (the reader takes every offset from that description, so a file with
/// only the fields the reader looks for is a file it can read).
final class BlendBuilder {
    enum Value {
        case int(Int)
        case float(Float)
        case floats([Float])
        case text(String)
        case pointer(UInt64)
    }

    enum Header { case classic(version: String), large(version: String) }

    private var typeNames = ["char", "short", "int", "float", "int64_t", "void"]
    private var typeSizes = [1, 2, 4, 4, 8, 0]
    private var structures: [(name: String, fields: [(type: String, name: String)])] = []
    private var blocks: [(code: String, structure: Int, count: Int, address: UInt64, bytes: Data)] = []
    private var nextAddress: UInt64 = 0x1000
    let header: Header

    init(header: Header = .classic(version: "402")) { self.header = header }

    /// A structure and its fields in order: `("float", "co[3]")`, `("Object", "*parent")`.
    func define(_ name: String, _ fields: [(String, String)]) {
        if !typeNames.contains(name) { typeNames.append(name); typeSizes.append(0) }
        for (type, _) in fields where !typeNames.contains(type) { typeNames.append(type); typeSizes.append(0) }
        structures.append((name, fields.map { (type: $0.0, name: $0.1) }))
        typeSizes[typeNames.firstIndex(of: name)!] = layout(name).size
    }

    private func layout(_ name: String) -> (size: Int, fields: [String: (offset: Int, size: Int, element: Int)]) {
        guard let s = structures.first(where: { $0.name == name }) else { return (typeSizes[typeNames.firstIndex(of: name) ?? 0], [:]) }
        var offset = 0
        var fields: [String: (Int, Int, Int)] = [:]
        for (type, raw) in s.fields {
            let pointer = raw.hasPrefix("*")
            var plain = raw.replacingOccurrences(of: "*", with: "")
            var elements = 1
            while let open = plain.lastIndex(of: "["), let close = plain.lastIndex(of: "]") {
                elements *= Int(plain[plain.index(after: open)..<close])!
                plain = String(plain[..<open]) + String(plain[plain.index(after: close)...])
            }
            let element = pointer ? 8 : (structures.contains { $0.name == type } ? layout(type).size : typeSizes[typeNames.firstIndex(of: type)!])
            fields[plain] = (offset, element * elements, element)
            offset += element * elements
        }
        return (offset, fields)
    }

    func size(of name: String) -> Int { layout(name).size }

    /// The bytes of one structure with the given fields set ("id.name" reaches into a structure inside it).
    func record(_ name: String, _ values: [String: Value] = [:]) -> Data {
        var data = Data(count: layout(name).size)
        for (path, value) in values {
            var structure = name, offset = 0
            let parts = path.split(separator: ".").map(String.init)
            var found: (offset: Int, size: Int, element: Int)?
            for (i, part) in parts.enumerated() {
                guard let field = layout(structure).fields[part] else { fatalError("no field \(part) in \(structure)") }
                offset += field.offset
                found = (offset, field.size, field.element)
                if i < parts.count - 1 {
                    structure = structures.first { $0.name == structure }!.fields.first { String($0.name.replacingOccurrences(of: "*", with: "").split(separator: "[")[0]) == part }!.type
                }
            }
            let field = found!
            func put<T>(_ v: T, _ at: Int) { withUnsafeBytes(of: v) { data.replaceSubrange(at..<(at + $0.count), with: $0) } }
            switch value {
            case .int(let v):
                switch field.element { case 1: put(Int8(truncatingIfNeeded: v), field.offset); case 2: put(Int16(truncatingIfNeeded: v), field.offset); case 8: put(Int64(v), field.offset); default: put(Int32(truncatingIfNeeded: v), field.offset) }
            case .float(let v): put(v, field.offset)
            case .floats(let v): for (i, f) in v.enumerated() { put(f, field.offset + i * 4) }
            case .text(let v): let bytes = Array(v.utf8.prefix(field.size - 1)); data.replaceSubrange(field.offset..<(field.offset + bytes.count), with: bytes)
            case .pointer(let v): put(v, field.offset)
            }
        }
        return data
    }

    /// Adds a block and gives the address other blocks point to it by. Blocks are written
    /// in the order they are added; a data-block's pieces ("DATA") follow it.
    @discardableResult
    func add(_ code: String, _ structure: String, _ bytes: Data, count: Int = 1, at address: UInt64? = nil) -> UInt64 {
        let used = address ?? reserve()
        blocks.append((code, structures.firstIndex { $0.name == structure } ?? 0, count, used, bytes))
        return used
    }

    /// An address for a block that is added later (for pointers that lead forward).
    func reserve() -> UInt64 { nextAddress += 0x1000; return nextAddress }

    static func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

    func build(fieldNames overrides: [String: String] = [:]) -> Data {
        func i32(_ v: Int) -> Data { Self.bytes([Int32(v)]) }
        func padded(_ d: Data) -> Data { d + Data(count: (4 - d.count % 4) % 4) }
        var fieldNames: [String] = []
        for s in structures { for f in s.fields where !fieldNames.contains(f.name) { fieldNames.append(f.name) } }
        var dna = Data("SDNANAME".utf8) + i32(fieldNames.count)
        for n in fieldNames { dna += Data((overrides[n] ?? n).utf8) + Data([0]) }
        dna = padded(dna) + Data("TYPE".utf8) + i32(typeNames.count)
        for n in typeNames { dna += Data(n.utf8) + Data([0]) }
        dna = padded(dna) + Data("TLEN".utf8) + Self.bytes(typeSizes.map { Int16($0) })
        dna = padded(dna) + Data("STRC".utf8) + i32(structures.count)
        for s in structures {
            dna += Self.bytes([Int16(typeNames.firstIndex(of: s.name)!), Int16(s.fields.count)])
            for f in s.fields { dna += Self.bytes([Int16(typeNames.firstIndex(of: f.type)!), Int16(fieldNames.firstIndex(of: f.name)!)]) }
        }
        var out: Data
        var large = false
        switch header {
        case .classic(let version): out = Data("BLENDER-v\(version)".utf8)
        case .large(let version): out = Data("BLENDER17-01v\(version)".utf8); large = true
        }
        func block(_ code: String, _ structure: Int, _ count: Int, _ address: UInt64, _ bytes: Data) -> Data {
            var name = Array(code.utf8.prefix(4)); while name.count < 4 { name.append(0) }
            if large { return Data(name) + i32(structure) + Self.bytes([address]) + Self.bytes([Int64(bytes.count), Int64(count)]) + bytes }
            return Data(name) + i32(bytes.count) + Self.bytes([address]) + i32(structure) + i32(count) + bytes
        }
        for b in blocks { out += block(b.code, b.structure, b.count, b.address, b.bytes) }
        out += block("DNA1", 0, 1, 0x10, dna)
        out += block("ENDB", 0, 0, 0, Data())
        return out
    }
}
