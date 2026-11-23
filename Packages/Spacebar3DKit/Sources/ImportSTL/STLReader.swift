import Foundation
import ModelCore
import simd

/// Reads STL, binary or text, straight from the file's bytes into a `ModelScene`.
///
/// STL is read here and not through Model I/O because Model I/O holds the whole file and
/// its own buffers while we copy out of them, which more than doubles the memory a large
/// file needs. The file is memory-mapped.
///
/// STL repeats every corner of every triangle (six million vertices for two million
/// triangles where a million positions exist). Corners at the same position are merged as
/// they are read, so the unmerged mesh is never held, and the part is marked `faceted`:
/// each face is shaded with its own normal, which the renderer takes from the surface. The
/// normals written in the file are not kept (many exporters leave them at zero).
public enum STLReader {
    public enum Failure: Error, LocalizedError, Equatable {
        case empty
        case truncated

        public var errorDescription: String? {
            switch self {
            case .empty: return L10n.text("The file contains no geometry.")
            case .truncated: return L10n.text("The file ends before its last triangle.")
            }
        }
    }

    public static func load(_ url: URL) throws -> ModelScene {
        try scene(from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func scene(from data: Data) throws -> ModelScene {
        var welder = Welder()
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            if isBinary(bytes) {
                try readBinary(bytes, into: &welder)
            } else if let middle = readText(bytes, into: &welder, from: nil) {
                // A model far from the origin is read a second time, from its own middle, so
                // that its corners are near the origin before they are rounded to Float.
                welder = Welder()
                _ = readText(bytes, into: &welder, from: middle)
            }
        }
        let triangles = welder.indices.count / 3
        guard triangles > 0 else { throw Failure.empty }
        var part = ModelScene.MeshPart()
        part.positions = welder.positions
        part.triangleIndices = welder.indices
        part.faceted = true
        welder = Welder()
        part.material = 0

        var scene = ModelScene()
        // Bare triangles get the plain material.
        var plain = ModelScene.Material()
        plain.name = "plain"
        plain.baseColor = SIMD4(Float(0xb4) / 255, Float(0xb4) / 255, Float(0xb8) / 255, 1)
        plain.metallic = 0
        plain.roughness = 0.65
        plain.doubleSided = true
        plain.authoredPBR = false
        scene.materials = [plain]
        scene.meshes = [ModelScene.Mesh(name: "", parts: [part])]
        // STL is Z-up (3D printing and CAD); the renderer's convention is Y up.
        scene.nodes = [ModelScene.Node(transform: simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))), mesh: 0)]
        // STL stores every triangle with its own three corners; count them as the file does.
        scene.topology.faces = triangles
        scene.topology.triangles = triangles
        scene.topology.vertices = triangles * 3
        return scene
    }

    /// Binary when the size is exactly what the triangle count says; otherwise text when it
    /// starts with "solid"; otherwise binary with whatever triangles fit.
    static func isBinary(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        if bytes.count >= 84 {
            let count = Int(littleEndian32(bytes, at: 80))
            if count > 0, 84 + count * 50 == bytes.count { return true }
        }
        var at = 0
        while at < bytes.count, bytes[at] == 0x20 || (0x09...0x0d).contains(bytes[at]) { at += 1 }
        return !bytes[at...].starts(with: Array("solid".utf8))
    }

    private static func littleEndian32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func readBinary(_ bytes: UnsafeBufferPointer<UInt8>, into welder: inout Welder) throws {
        guard bytes.count >= 84 else { throw Failure.empty }
        let declared = Int(littleEndian32(bytes, at: 80))
        let count = min(declared, (bytes.count - 84) / 50)
        guard count > 0 else { throw declared > 0 ? Failure.truncated : Failure.empty }
        welder.reserve(triangles: count)
        let base = UnsafeRawPointer(bytes.baseAddress!)
        @inline(__always) func vector(_ offset: Int) -> SIMD3<Float> {
            SIMD3(Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))),
                  Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))),
                  Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))))
        }
        for t in 0..<count {
            let at = 84 + t * 50
            welder.add(vector(at + 12)); welder.add(vector(at + 24)); welder.add(vector(at + 36))
        }
    }

    /// Positions merged as they arrive: `indices` gets one entry per corner added, pointing
    /// at the first corner seen at exactly that position.
    struct Welder {
        private(set) var positions: [SIMD3<Float>] = []
        private(set) var indices: [UInt32] = []
        /// Open addressing; a slot holds an index into `positions`, or `.max` when free.
        private var table = [UInt32](repeating: .max, count: 1024)

        /// Room for a closed surface of that many triangles (about half as many positions);
        /// anything else just grows.
        mutating func reserve(triangles: Int) {
            indices.reserveCapacity(triangles * 3)
            positions.reserveCapacity(triangles / 2 + 16)
            var capacity = table.count
            while capacity < triangles { capacity <<= 1 }
            if capacity > table.count { table = [UInt32](repeating: .max, count: capacity) }
        }

        mutating func add(_ p: SIMD3<Float>) {
            if (positions.count + 1) * 2 > table.count { grow() }
            let mask = table.count - 1
            var slot = PositionHash.home(p.x, p.y, p.z) & mask
            while true {
                let found = table[slot]
                if found == .max {
                    table[slot] = UInt32(positions.count)
                    indices.append(UInt32(positions.count))
                    positions.append(p)
                    return
                }
                let q = positions[Int(found)]
                if q.x == p.x && q.y == p.y && q.z == p.z { indices.append(found); return }
                slot = (slot + 1) & mask
            }
        }

        private mutating func grow() {
            table = [UInt32](repeating: .max, count: table.count * 2)
            let mask = table.count - 1
            for (i, p) in positions.enumerated() {
                var slot = PositionHash.home(p.x, p.y, p.z) & mask
                while table[slot] != .max { slot = (slot + 1) & mask }
                table[slot] = UInt32(i)
            }
        }
    }

    /// Text STL: only "vertex x y z" matters; every three vertices are a triangle. The
    /// corners are counted from `origin`. Without one they are as the file gives them, and
    /// what comes back is where to count from when the model lies far off.
    private static func readText(_ bytes: UnsafeBufferPointer<UInt8>, into welder: inout Welder, from origin: SIMD3<Double>?) -> SIMD3<Double>? {
        var scanner = ByteScanner(bytes)
        var whereabouts = Whereabouts()
        let start = origin ?? SIMD3()
        func number() -> Double? { scanner.token().flatMap { scanner.number($0) } }
        var corners: [SIMD3<Float>] = []
        while let token = scanner.token() {
            guard scanner.equals(token, "vertex"), let x = number(), let y = number(), let z = number() else { continue }
            let place = SIMD3(x, y, z)
            whereabouts.include(place)
            corners.append(SIMD3<Float>(place - start))
            if corners.count == 3 {
                for corner in corners { welder.add(corner) }
                corners.removeAll(keepingCapacity: true)
            }
        }
        return origin == nil ? whereabouts.farMiddle : nil
    }
}
