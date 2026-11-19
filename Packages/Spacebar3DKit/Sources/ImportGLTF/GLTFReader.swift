import Foundation
import ModelCore
import simd

/// Reads glTF 2.0: the binary container (`.glb`) and the text form (`.gltf`, with its
/// buffers and images inside the file as data, or beside it).
///
/// Kept from the file: the default scene's nodes with their placement, triangle and point
/// primitives (strips and fans are unrolled; lines are passed over) with positions,
/// normals, the texture coordinates the colour image uses, and vertex colours; materials
/// in the metallic-roughness model with their colour, metallic-roughness and normal
/// images, the unlit extension and the older specular-glossiness one; blending.
///
/// Everything read from the file is checked against the data that is really there: a
/// file is untrusted, and an accessor that points outside its buffer fails the load
/// instead of reading past it.
public enum GLTFReader {
    public enum Failure: Error, LocalizedError, Equatable, MissingFilesReporting {
        case notGLTF
        case damaged(String)
        case unsupported(String)
        /// Files beside the model that it cannot be shown without.
        case missingFiles([String])
        case empty

        public var missingFiles: [String] {
            if case .missingFiles(let names) = self { return names }
            return []
        }

        public var errorDescription: String? {
            switch self {
            case .notGLTF: return L10n.text("This is not a glTF file.")
            case .damaged(let what): return L10n.format("The file is damaged: %@.", String(describing: what))
            case .unsupported(let what): return L10n.format("This file cannot be shown: %@.", String(describing: what))
            case .missingFiles(let names): return L10n.format("The model’s data is in separate files that could not be read: %@", String(describing: names.joined(separator: ", ")))
            case .empty: return L10n.text("The file contains no geometry.")
            }
        }
    }

    static let maxElements = 100_000_000
    static let maxNodes = 200_000
    static let maxDepth = 256

    public static func load(_ url: URL) throws -> ModelScene {
        try scene(from: Data(contentsOf: url, options: .mappedIfSafe), sidecars: SidecarFolder(modelURL: url))
    }

    public static func scene(from data: Data, sidecars: SidecarSource? = nil) throws -> ModelScene {
        var document = try Document(data: data, sidecars: sidecars)
        return try document.scene()
    }

    // MARK: Container

    /// The JSON and the binary chunk of a `.glb`, or the JSON of a `.gltf`.
    static func split(_ data: Data) throws -> (json: Data, binary: Data?) {
        guard data.count >= 4 else { throw Failure.notGLTF }
        let magic = data.prefix(4)
        guard magic.elementsEqual([0x67, 0x6c, 0x54, 0x46]) else { return (data, nil) }   // "glTF"
        func word(_ at: Int) throws -> Int {
            guard at + 4 <= data.count else { throw Failure.damaged(L10n.text("the container is cut short")) }
            let s = data.startIndex + at
            return Int(data[s]) | Int(data[s + 1]) << 8 | Int(data[s + 2]) << 16 | Int(data[s + 3]) << 24
        }
        guard try word(4) == 2 else { throw Failure.unsupported(L10n.text("only version 2 of glTF is read")) }
        var at = 12
        var json: Data?, binary: Data?
        while at + 8 <= data.count {
            let length = try word(at), kind = try word(at + 4)
            let start = at + 8
            guard length >= 0, start + length <= data.count else { throw Failure.damaged(L10n.text("a chunk runs past the end of the file")) }
            let chunk = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length))
            if kind == 0x4e4f534a, json == nil { json = chunk } else if kind == 0x004e4942, binary == nil { binary = chunk }
            at = start + length
            // Chunks are aligned to four bytes.
            at += (4 - at % 4) % 4
        }
        guard let json else { throw Failure.damaged(L10n.text("the container has no description")) }
        return (json, binary)
    }
}

/// One file being read.
struct Document {
    typealias Object = [String: Any]
    typealias Failure = GLTFReader.Failure

    let root: Object
    let binary: Data?
    let sidecars: SidecarSource?
    private var buffers: [Int: Data] = [:]
    var out = ModelScene()
    /// For each of the file's meshes that was read, the joint influences of its parts.
    var influences: [Int: [Influences?]] = [:]

    /// The joints (of a node's skin) and weights of each vertex of a part.
    struct Influences {
        var joints: [SIMD4<UInt16>]
        var weights: [SIMD4<Float>]
    }

    let accessors: [Object]
    let bufferViews: [Object]
    let bufferList: [Object]

    init(data: Data, sidecars: SidecarSource?) throws {
        let (json, binary) = try GLTFReader.split(data)
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? Object else { throw Failure.notGLTF }
        guard let asset = root["asset"] as? Object else { throw Failure.notGLTF }
        if let version = asset["version"] as? String, !version.hasPrefix("2") { throw Failure.unsupported(L10n.text("only version 2 of glTF is read")) }
        // What the file says it cannot be shown without.
        let known: Set<String> = ["KHR_materials_unlit", "KHR_materials_pbrSpecularGlossiness", "KHR_texture_transform", "KHR_materials_emissive_strength",
                                  "KHR_mesh_quantization", "EXT_texture_webp", "KHR_materials_variants", "KHR_lights_punctual"]
        // Compressed geometry is not read (owner decision, 2026-11-12).
        let compressed = ["KHR_draco_mesh_compression": "Draco", "EXT_meshopt_compression": "Meshopt", "KHR_meshopt_compression": "Meshopt"]
        if let required = root["extensionsRequired"] as? [String], let first = required.first(where: { !known.contains($0) }) {
            if let scheme = compressed[first] { throw Failure.unsupported(L10n.format("%@-compressed models are not supported", String(describing: scheme))) }
            throw Failure.unsupported(L10n.format("it needs %@, which is not read", String(describing: first)))
        }
        self.root = root
        self.binary = binary
        self.sidecars = sidecars
        accessors = root["accessors"] as? [Object] ?? []
        bufferViews = root["bufferViews"] as? [Object] ?? []
        bufferList = root["buffers"] as? [Object] ?? []
    }

    // MARK: JSON

    static func int(_ value: Any?) -> Int? {
        // A JSON true or false is not a number (and 0 and 1 are not true and false).
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9e15 else { return nil }
        return Int(double)
    }

    static func float(_ value: Any?) -> Float? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.floatValue
    }

    static func floats(_ value: Any?, count: Int) -> [Float]? {
        guard let list = value as? [Any], list.count == count else { return nil }
        let values = list.compactMap(float)
        return values.count == count ? values : nil
    }

    // MARK: Buffers

    /// The bytes named by a URI: data inside the file, or a file beside the model.
    func bytes(uri: String) -> Data? {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else { return nil }
            let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
            let body = String(uri[uri.index(after: comma)...])
            if header.hasSuffix(";base64") { return Data(base64Encoded: body, options: .ignoreUnknownCharacters) }
            return body.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard !uri.contains("://") || uri.hasPrefix("file://") else { return nil }
        return sidecars?.data(named: uri.removingPercentEncoding ?? uri)
    }

    private mutating func buffer(_ index: Int) throws -> Data {
        if let known = buffers[index] { return known }
        guard bufferList.indices.contains(index) else { throw Failure.damaged(L10n.text("a buffer that is not in the file is used")) }
        let data: Data
        if let uri = bufferList[index]["uri"] as? String {
            guard let found = bytes(uri: uri) else {
                if uri.hasPrefix("data:") { throw Failure.damaged(L10n.text("a buffer's data cannot be decoded")) }
                throw Failure.missingFiles([((uri.removingPercentEncoding ?? uri) as NSString).lastPathComponent])
            }
            data = found
        } else {
            guard index == 0, let binary else { throw Failure.damaged(L10n.text("a buffer has no data")) }
            data = binary
        }
        buffers[index] = data
        return data
    }

    /// The bytes of a buffer view, and the distance between its elements when it sets one.
    mutating func view(_ index: Int) throws -> (data: Data, stride: Int?) {
        guard bufferViews.indices.contains(index) else { throw Failure.damaged(L10n.text("a buffer view that is not in the file is used")) }
        let view = bufferViews[index]
        guard let bufferIndex = Self.int(view["buffer"]), let length = Self.int(view["byteLength"]), length >= 0 else { throw Failure.damaged(L10n.text("a buffer view is incomplete")) }
        let offset = Self.int(view["byteOffset"]) ?? 0
        let whole = try buffer(bufferIndex)
        guard offset >= 0, offset <= whole.count, length <= whole.count - offset else { throw Failure.damaged(L10n.text("a buffer view runs past its buffer")) }
        let stride = Self.int(view["byteStride"])
        if let stride, stride < 1 || stride > 4096 { throw Failure.damaged(L10n.text("a buffer view has an impossible stride")) }
        return (whole.subdata(in: (whole.startIndex + offset)..<(whole.startIndex + offset + length)), stride)
    }

    // MARK: Accessors

    private static func componentSize(_ type: Int) -> Int? {
        switch type {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return nil
        }
    }

    private static func componentCount(_ type: String) -> Int? {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT4": return 16
        default: return nil
        }
    }

    @inline(__always)
    private static func value(_ p: UnsafeRawPointer, _ type: Int, normalized: Bool) -> Float {
        switch type {
        case 5120:
            let v = p.loadUnaligned(as: Int8.self)
            return normalized ? max(Float(v) / 127, -1) : Float(v)
        case 5121:
            let v = p.loadUnaligned(as: UInt8.self)
            return normalized ? Float(v) / 255 : Float(v)
        case 5122:
            let v = p.loadUnaligned(as: Int16.self)
            return normalized ? max(Float(v) / 32767, -1) : Float(v)
        case 5123:
            let v = p.loadUnaligned(as: UInt16.self)
            return normalized ? Float(v) / 65535 : Float(v)
        case 5125:
            return Float(p.loadUnaligned(as: UInt32.self))
        default:
            return p.loadUnaligned(as: Float.self)
        }
    }

    @inline(__always)
    private static func whole(_ p: UnsafeRawPointer, _ type: Int) throws -> UInt32 {
        switch type {
        case 5121: return UInt32(p.loadUnaligned(as: UInt8.self))
        case 5123: return UInt32(p.loadUnaligned(as: UInt16.self))
        case 5125: return p.loadUnaligned(as: UInt32.self)
        default: throw Failure.damaged(L10n.text("indices must use unsigned integers"))
        }
    }

    /// The shape of an accessor after every check that can be made without its data.
    private struct Layout {
        var count: Int, components: Int, componentType: Int, normalized: Bool
        var view: Int?, offset: Int
        var sparse: Document.Object?
        var elementSize: Int { components * (Document.componentSize(componentType) ?? 1) }
    }

    private func layout(_ index: Int) throws -> Layout {
        guard accessors.indices.contains(index) else { throw Failure.damaged(L10n.text("an accessor that is not in the file is used")) }
        let a = accessors[index]
        guard let count = Self.int(a["count"]), count >= 0, count <= GLTFReader.maxElements,
              let componentType = Self.int(a["componentType"]), Self.componentSize(componentType) != nil,
              let type = a["type"] as? String, let components = Self.componentCount(type)
        else { throw Failure.damaged(L10n.text("an accessor is incomplete")) }
        let offset = Self.int(a["byteOffset"]) ?? 0
        guard offset >= 0 else { throw Failure.damaged(L10n.text("an accessor starts before its data")) }
        return Layout(count: count, components: components, componentType: componentType, normalized: a["normalized"] as? Bool ?? false,
                      view: Self.int(a["bufferView"]), offset: offset, sparse: a["sparse"] as? Object)
    }

    /// Resolve and check the complete byte extent before allocating decoded values.
    private mutating func contents(_ l: Layout) throws -> (data: Data, step: Int)? {
        guard let viewIndex = l.view, l.count > 0 else { return nil }
        let (data, stride) = try view(viewIndex)
        let size = l.elementSize, step = stride ?? size
        guard l.offset >= 0, step >= size, l.offset <= data.count, data.count - l.offset >= size, (l.count - 1) <= (data.count - l.offset - size) / step
        else { throw Failure.damaged(L10n.text("an accessor runs past its data")) }
        return (data, step)
    }

    private func each(_ l: Layout, _ contents: (data: Data, step: Int)?, _ body: (Int, UnsafeRawPointer) throws -> Void) rethrows {
        guard let contents else { return }
        try contents.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<l.count { try body(i, base + l.offset + i * contents.step) }
        }
    }

    /// An accessor as floats, with its sparse replacements applied.
    mutating func floats(_ index: Int, components expected: Int? = nil) throws -> (values: [Float], components: Int, count: Int) {
        let l = try layout(index)
        if let expected, expected != l.components { throw Failure.damaged(L10n.text("an accessor has the wrong kind of values")) }
        let n = l.components, type = l.componentType, normalized = l.normalized
        let base = try contents(l)
        var sparseData: (indices: Layout, indexBytes: (data: Data, step: Int)?, values: Layout, valueBytes: (data: Data, step: Int)?)?
        if let sparse = l.sparse {
            guard let count = Self.int(sparse["count"]), count >= 0, count <= l.count,
                  let indices = sparse["indices"] as? Object, let replacements = sparse["values"] as? Object,
                  let indexView = Self.int(indices["bufferView"]), let indexType = Self.int(indices["componentType"]), [5121, 5123, 5125].contains(indexType),
                  let valueView = Self.int(replacements["bufferView"])
            else { throw Failure.damaged(L10n.text("a sparse accessor is incomplete")) }
            let il = Layout(count: count, components: 1, componentType: indexType, normalized: false, view: indexView, offset: Self.int(indices["byteOffset"]) ?? 0, sparse: nil)
            let vl = Layout(count: count, components: n, componentType: type, normalized: normalized, view: valueView, offset: Self.int(replacements["byteOffset"]) ?? 0, sparse: nil)
            sparseData = (il, try contents(il), vl, try contents(vl))
        }
        var values = [Float](repeating: 0, count: l.count * n)
        values.withUnsafeMutableBufferPointer { out in
            each(l, base) { i, p in
                let size = Self.componentSize(type) ?? 4
                for c in 0..<n { out[i * n + c] = Self.value(p + c * size, type, normalized: normalized) }
            }
        }
        if let sparse = sparseData {
            var which = [UInt32](repeating: 0, count: sparse.indices.count)
            try each(sparse.indices, sparse.indexBytes) { i, p in
                which[i] = try Self.whole(p, sparse.indices.componentType)
            }
            values.withUnsafeMutableBufferPointer { out in
                each(sparse.values, sparse.valueBytes) { i, p in
                    let target = Int(which[i])
                    guard target < l.count else { return }
                    let size = Self.componentSize(type) ?? 4
                    for c in 0..<n { out[target * n + c] = Self.value(p + c * size, type, normalized: normalized) }
                }
            }
        }
        return (values, n, l.count)
    }

    /// An accessor of whole numbers (indices, joints).
    mutating func wholes(_ index: Int, components expected: Int = 1) throws -> [UInt32] {
        let l = try layout(index)
        guard l.components == expected else { throw Failure.damaged(L10n.text("an accessor has the wrong kind of values")) }
        guard !l.normalized, [5121, 5123, 5125].contains(l.componentType) else {
            throw Failure.damaged(L10n.text("indices must use unsigned integers"))
        }
        guard l.sparse == nil else { throw Failure.unsupported(L10n.text("sparse indices are not read")) }
        let n = l.components, type = l.componentType
        let data = try contents(l)
        var values = [UInt32](repeating: 0, count: l.count * n)
        try values.withUnsafeMutableBufferPointer { out in
            try each(l, data) { i, p in
                let size = Self.componentSize(type) ?? 4
                for c in 0..<n { out[i * n + c] = try Self.whole(p + c * size, type) }
            }
        }
        return values
    }

    func accessorCount(_ index: Int) -> Int? {
        accessors.indices.contains(index) ? Self.int(accessors[index]["count"]) : nil
    }
}
