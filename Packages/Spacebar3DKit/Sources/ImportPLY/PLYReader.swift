import Foundation
import ModelCore
import simd

/// Reads PLY (text, or binary of either byte order) straight from the file's bytes.
///
/// Kept from the file: positions, normals, vertex colours, and the faces as polygons (a
/// quad stays a quad for the statistics and the wireframe). A file with no faces is a point
/// cloud. Texture coordinates and any other property or element are passed over.
public enum PLYReader {
    public enum Failure: Error, LocalizedError, Equatable {
        case notPLY
        case header(String)
        case truncated
        case empty

        public var errorDescription: String? {
            switch self {
            case .notPLY: return L10n.text("The file is not a PLY file.")
            case .header(let what): return L10n.format("The PLY header cannot be read: %@.", String(describing: what))
            case .truncated: return L10n.text("The PLY data is incomplete or invalid.")
            case .empty: return L10n.text("The file contains no geometry.")
            }
        }
    }

    enum Scalar: Equatable {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64

        init?(_ name: String) {
            switch name {
            case "char", "int8": self = .int8
            case "uchar", "uint8": self = .uint8
            case "short", "int16": self = .int16
            case "ushort", "uint16": self = .uint16
            case "int", "int32": self = .int32
            case "uint", "uint32": self = .uint32
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            default: return nil
            }
        }

        var size: Int {
            switch self {
            case .int8, .uint8: return 1
            case .int16, .uint16: return 2
            case .int32, .uint32, .float32: return 4
            case .float64: return 8
            }
        }

        /// What a colour of this type is divided by to land in 0...1.
        var colourScale: Float {
            switch self {
            case .uint8, .int8: return 255
            case .uint16, .int16: return 65535
            default: return 1
            }
        }
    }

    struct Property { var name: String; var type: Scalar; var listCount: Scalar? }
    struct Element { var name: String; var count: Int; var properties: [Property] }
    enum Encoding { case text, little, big }

    public static func load(_ url: URL) throws -> ModelScene {
        try scene(from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func scene(from data: Data) throws -> ModelScene {
        try data.withUnsafeBytes { raw in try scene(from: raw.bindMemory(to: UInt8.self)) }
    }

    private static func scene(from bytes: UnsafeBufferPointer<UInt8>) throws -> ModelScene {
        var scanner = ByteScanner(bytes)
        let (encoding, elements) = try header(&scanner)
        func read(from origin: SIMD3<Double>?) throws -> (scene: ModelScene, far: SIMD3<Double>?) {
            if encoding == .text {
                var source = TextSource(scanner: scanner)
                return try scene(from: &source, elements: elements, origin: origin)
            }
            var source = BinarySource(bytes: bytes, at: scanner.at, bigEndian: encoding == .big)
            return try scene(from: &source, elements: elements, origin: origin)
        }
        // A model far from the origin is read a second time, from its own middle, so that
        // its points are near the origin before they are rounded to Float.
        let middle: SIMD3<Double>
        do {
            let first = try read(from: nil)
            guard let far = first.far else { return first.scene }
            middle = far
        }
        return try read(from: middle).scene
    }

    /// The scene with its coordinates counted from `origin`. Without one they are as the
    /// file gives them, and `far` is where to count from when the model lies far off.
    private static func scene<Source: ValueSource>(from source: inout Source, elements: [Element], origin: SIMD3<Double>?) throws -> (scene: ModelScene, far: SIMD3<Double>?) {
        var part = ModelScene.MeshPart()
        var whereabouts = Whereabouts()
        let start = origin ?? SIMD3()
        var topology = SourceTopology()
        let polygonBudget = PolygonTriangulation.Budget()
        var sizes: [UInt32] = []
        var onlyTriangles = true
        var colourScale = SIMD4<Float>(repeating: 1)

        for element in elements {
            guard element.count >= 0, element.count <= source.remaining else { throw Failure.truncated }
            if element.name == "vertex" {
                // Where each wanted value sits among the element's properties.
                func slot(_ names: String...) -> Int? { element.properties.firstIndex { names.contains($0.name) && $0.listCount == nil } }
                let px = slot("x"), py = slot("y"), pz = slot("z")
                guard let px, let py, let pz else { throw Failure.header(L10n.text("the vertices have no x, y, z")) }
                let n = [slot("nx"), slot("ny"), slot("nz")]
                let c = [slot("red", "r", "diffuse_red"), slot("green", "g", "diffuse_green"), slot("blue", "b", "diffuse_blue")]
                let alpha = slot("alpha", "a", "diffuse_alpha")
                let hasNormals = !n.contains(nil), hasColours = !c.contains(nil)
                if hasColours {
                    for (i, index) in (c + [alpha]).enumerated() { if let index { colourScale[i] = element.properties[index].type.colourScale } }
                }
                part.positions.reserveCapacity(element.count)
                if hasNormals { part.normals.reserveCapacity(element.count) }
                if hasColours { part.colors.reserveCapacity(element.count) }
                var row = [Double](repeating: 0, count: element.properties.count)
                for _ in 0..<element.count {
                    for (i, property) in element.properties.enumerated() {
                        if let listCount = property.listCount {
                            let count = try source.listLength(listCount)
                            for _ in 0..<count { _ = try source.next(property.type) }
                        } else {
                            row[i] = try source.next(property.type)
                        }
                    }
                    let place = SIMD3(row[px], row[py], row[pz])
                    whereabouts.include(place)
                    part.positions.append(SIMD3<Float>(place - start))
                    if hasNormals { part.normals.append(SIMD3(Float(row[n[0]!]), Float(row[n[1]!]), Float(row[n[2]!]))) }
                    if hasColours {
                        let raw = SIMD4(Float(row[c[0]!]), Float(row[c[1]!]), Float(row[c[2]!]), alpha.map { Float(row[$0]) } ?? colourScale.w)
                        part.colors.append(simd_clamp(raw / colourScale, SIMD4(repeating: 0), SIMD4(repeating: 1)))
                    }
                }
            } else if element.name == "face", let list = element.properties.firstIndex(where: { $0.listCount != nil && ["vertex_indices", "vertex_index"].contains($0.name) }) {
                let vertexCount = part.positions.count
                part.triangleIndices.reserveCapacity(min(element.count, source.remaining) * 3)
                var corners: [UInt32] = []
                for _ in 0..<element.count {
                    for (i, property) in element.properties.enumerated() {
                        if let listCount = property.listCount {
                            let count = try source.listLength(listCount)
                            if i == list {
                                corners.removeAll(keepingCapacity: true)
                                var valid = true
                                for _ in 0..<count {
                                    let v = try source.next(property.type)
                                    if v >= 0, v < Double(vertexCount) { corners.append(UInt32(v)) } else { valid = false }
                                }
                                // A face that points outside the vertices, or has fewer than three corners, is left out.
                                guard valid, corners.count >= 3 else { continue }
                                guard let triangles = PolygonTriangulation.indices(count: corners.count, budget: polygonBudget, position: { part.positions[Int(corners[$0])] }) else { continue }
                                part.triangleIndices.append(contentsOf: triangles.map { corners[$0] })
                                sizes.append(UInt32(corners.count))
                                if corners.count != 3 { onlyTriangles = false }
                                topology.addFace(corners: corners.count)
                            } else {
                                for _ in 0..<count { _ = try source.next(property.type) }
                            }
                        } else {
                            _ = try source.next(property.type)
                        }
                    }
                }
            } else {
                for _ in 0..<element.count {
                    for property in element.properties {
                        if let listCount = property.listCount {
                            let count = try source.listLength(listCount)
                            for _ in 0..<count { _ = try source.next(property.type) }
                        } else {
                            _ = try source.next(property.type)
                        }
                    }
                }
            }
        }

        guard !part.positions.isEmpty else { throw Failure.empty }
        topology.vertices = part.positions.count
        if part.triangleIndices.isEmpty {
            part.primitive = .points
            part.normals = []
        } else if !onlyTriangles {
            part.faceSizes = sizes
        }
        part.material = 0

        var scene = ModelScene()
        // Geometry with no material gets the plain one.
        var plain = ModelScene.Material()
        plain.name = "plain"
        // The file's own colors already specify its appearance, on faces as on points; the
        // synthetic gray is only for geometry without them. Authored material factors in
        // other formats still tint.
        plain.baseColor = part.colors.isEmpty
            ? SIMD4(Float(0xb4) / 255, Float(0xb4) / 255, Float(0xb8) / 255, 1)
            : SIMD4(1, 1, 1, 1)
        plain.metallic = 0
        plain.roughness = 0.65
        plain.doubleSided = true
        plain.authoredPBR = false
        scene.materials = [plain]
        scene.meshes = [ModelScene.Mesh(name: "", parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        scene.topology = topology
        return (scene, origin == nil ? whereabouts.farMiddle : nil)
    }

    private static func header(_ scanner: inout ByteScanner) throws -> (Encoding, [Element]) {
        guard let magic = scanner.tokenOnLine(), scanner.equals(magic, "ply") else { throw Failure.notPLY }
        scanner.skipLine()
        var encoding: Encoding?
        var elements: [Element] = []
        var lines = 0
        while true {
            guard !scanner.isAtEnd else { throw Failure.header(L10n.text("it has no end")) }
            lines += 1
            guard lines < 10_000 else { throw Failure.header(L10n.text("it is too long")) }
            guard let word = scanner.tokenOnLine() else { scanner.skipLine(); continue }
            if scanner.equals(word, "end_header") { scanner.skipLine(); break }
            let rest = scanner.restOfLine().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if scanner.equals(word, "format") {
                switch rest.first {
                case "ascii": encoding = .text
                case "binary_little_endian": encoding = .little
                case "binary_big_endian": encoding = .big
                default: throw Failure.header(L10n.format("unknown format %@", String(describing: rest.first ?? "")))
                }
            } else if scanner.equals(word, "element") {
                guard rest.count >= 2, let count = Int(rest[1]), count >= 0 else { throw Failure.header(L10n.text("an element has no count")) }
                elements.append(Element(name: rest[0], count: count, properties: []))
            } else if scanner.equals(word, "property") {
                guard !elements.isEmpty else { throw Failure.header(L10n.text("a property comes before any element")) }
                if rest.first == "list" {
                    guard rest.count >= 4, let count = Scalar(rest[1]), let type = Scalar(rest[2]), count != .float32, count != .float64 else { throw Failure.header(L10n.text("a list property is not understood")) }
                    elements[elements.count - 1].properties.append(Property(name: rest[3], type: type, listCount: count))
                } else {
                    guard rest.count >= 2, let type = Scalar(rest[0]) else { throw Failure.header(L10n.text("a property has an unknown type")) }
                    elements[elements.count - 1].properties.append(Property(name: rest[1], type: type, listCount: nil))
                }
                guard elements[elements.count - 1].properties.count <= 1024 else { throw Failure.header(L10n.text("it is too long")) }
            }
            // comment, obj_info and anything else: passed over.
        }
        guard let encoding else { throw Failure.header(L10n.text("it does not say how the data is stored")) }
        return (encoding, elements)
    }
}

/// Where the values after the header come from.
protocol ValueSource {
    mutating func next(_ type: PLYReader.Scalar) throws -> Double
    /// An upper bound on how many more values there can be.
    var remaining: Int { get }
}

extension ValueSource {
    mutating func listLength(_ type: PLYReader.Scalar) throws -> Int {
        let value = try next(type)
        let maximum: Double
        switch type {
        case .int8: maximum = Double(Int8.max)
        case .uint8: maximum = Double(UInt8.max)
        case .int16: maximum = Double(Int16.max)
        case .uint16: maximum = Double(UInt16.max)
        case .int32: maximum = Double(Int32.max)
        case .uint32: maximum = Double(UInt32.max)
        default: throw PLYReader.Failure.truncated
        }
        guard value.isFinite, value >= 0, value.rounded(.towardZero) == value,
              value <= maximum, value <= Double(remaining) else { throw PLYReader.Failure.truncated }
        return Int(value)
    }
}

struct TextSource: ValueSource {
    var scanner: ByteScanner

    mutating func next(_ type: PLYReader.Scalar) throws -> Double {
        guard let token = scanner.token(), let value = scanner.number(token) else { throw PLYReader.Failure.truncated }
        return value
    }

    // A value takes at least a character and a separator.
    var remaining: Int { (scanner.bytes.count - scanner.at + 1) / 2 }
}

struct BinarySource: ValueSource {
    let bytes: UnsafeBufferPointer<UInt8>
    var at: Int
    let bigEndian: Bool

    var remaining: Int { bytes.count - at }

    mutating func next(_ type: PLYReader.Scalar) throws -> Double {
        let size = type.size
        guard bytes.count - at >= size else { throw PLYReader.Failure.truncated }
        let p = UnsafeRawPointer(bytes.baseAddress!) + at
        at += size
        @inline(__always) func load<T: FixedWidthInteger>(_: T.Type) -> T {
            let v = p.loadUnaligned(as: T.self)
            return bigEndian ? T(bigEndian: v) : T(littleEndian: v)
        }
        switch type {
        case .int8: return Double(load(Int8.self))
        case .uint8: return Double(load(UInt8.self))
        case .int16: return Double(load(Int16.self))
        case .uint16: return Double(load(UInt16.self))
        case .int32: return Double(load(Int32.self))
        case .uint32: return Double(load(UInt32.self))
        case .float32: return Double(Float(bitPattern: load(UInt32.self)))
        case .float64: return Double(bitPattern: load(UInt64.self))
        }
    }
}
