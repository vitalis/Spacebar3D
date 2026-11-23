import Foundation
import ModelCore
import simd

/// Reads Wavefront OBJ straight from the file's bytes.
///
/// Kept from the file: positions, vertex colours written after a position, normals, and
/// the faces as polygons (a quad stays a quad for the statistics and the wireframe). A file
/// with positions and no faces is a point cloud. Faces are split into one part for each
/// material they use (`usemtl`); the materials come from the `.mtl` files the model names
/// (`mtllib`, see `MTLReader`), and texture coordinates are kept for the parts whose
/// material has an image. Where the `.mtl` file is out of reach (it sits beside the model,
/// which the sandbox opens only after a grant) every surface gets one neutral material and
/// the file is listed as missing. Lines and curves are passed over.
public enum OBJReader {
    public enum Failure: Error, LocalizedError, Equatable {
        case empty

        public var errorDescription: String? { L10n.text("The file contains no geometry.") }
    }

    public static func load(_ url: URL) throws -> ModelScene {
        try scene(from: Data(contentsOf: url, options: .mappedIfSafe), sidecars: SidecarFolder(modelURL: url))
    }

    public static func scene(from data: Data, sidecars: SidecarSource? = nil) throws -> ModelScene {
        try data.withUnsafeBytes { raw in try scene(from: raw.bindMemory(to: UInt8.self), sidecars: sidecars) }
    }

    /// A face corner: which position, texture coordinate and normal (-1 for none).
    private struct Corner: Hashable { var position: Int32; var uv: Int32; var normal: Int32 }

    /// The faces that use one material.
    private struct Group {
        var material: String
        /// Texture coordinates tell corners apart only where an image will be laid on them.
        var keepsUV: Bool
        var indices: [UInt32] = []
        var vertexOf: [Corner: UInt32] = [:]
        var cornerOf: [Corner] = []          // per output vertex
        var sizes: [UInt32] = []
        var onlyTriangles = true
        var everyCornerHasNormal = true
        var everyCornerHasUV = true
        var everyFaceFlat = true
        /// For each triangle, once the file names smoothing groups: the group of its face;
        /// below zero for a face in none, a number of its own for each such face.
        var smoothingOf: [Int32] = []
    }

    /// The stand-in for an OBJ's materials when there are none to read.
    static var neutral: ModelScene.Material {
        var neutral = ModelScene.Material()
        neutral.name = "neutral"
        neutral.baseColor = SIMD4(Float(0xc8) / 255, Float(0xc8) / 255, Float(0xcc) / 255, 1)
        neutral.metallic = 0
        neutral.roughness = 0.7
        neutral.doubleSided = true
        neutral.authoredPBR = false
        return neutral
    }

    private static func scene(from bytes: UnsafeBufferPointer<UInt8>, sidecars: SidecarSource?) throws -> ModelScene {
        // A model far from the origin is read a second time, from its own middle, so that
        // its corners are near the origin before they are rounded to Float.
        let middle: SIMD3<Double>
        do {
            let first = try read(bytes, sidecars: sidecars, from: nil)
            guard let far = first.far else { return first.scene }
            middle = far
        }
        return try read(bytes, sidecars: sidecars, from: middle).scene
    }

    /// The scene with its coordinates counted from `origin`. Without one they are as the
    /// file gives them, and `far` is where to count from when the model lies far off.
    private static func read(_ bytes: UnsafeBufferPointer<UInt8>, sidecars: SidecarSource?, from origin: SIMD3<Double>?) throws -> (scene: ModelScene, far: SIMD3<Double>?) {
        var scanner = ByteScanner(bytes)
        var whereabouts = Whereabouts()
        let start = origin ?? SIMD3()
        var positions: [SIMD3<Float>] = []
        var colours: [SIMD4<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var allColoured = true

        var scene = ModelScene()
        var library = MTLReader.Library()
        var librariesRead = false
        var groups: [Group] = []
        var groupOf: [String: Int] = [:]
        var materialName = ""
        var current = -1

        var topology = SourceTopology()
        let polygonBudget = PolygonTriangulation.Budget()
        // Smoothing is on unless the file turns it off ("s off" or "s 0").
        var smoothing = true
        // Which smoothing group the faces are in, once the file names any ("s 1"); faces
        // before that are in one together. A face in none counts down from -1.
        var namesGroups = false
        var smoothingGroup: Int32 = 0, ungrouped: Int32 = 0
        var face: [UInt32] = []
        var values: [Double] = []

        func read(libraries line: String) {
            librariesRead = true
            guard let sidecars else { return }
            // One name, which may hold spaces, or several names.
            var names = [line]
            if sidecars.data(named: line) == nil, line.contains(" ") { names = line.split(separator: " ").map(String.init) }
            for name in names where !name.isEmpty {
                if let data = sidecars.data(named: name) {
                    library.merge(MTLReader.library(from: data))
                } else {
                    scene.diagnostics.missingResources.append((SidecarFolder.cleaned(name) as NSString? ?? name as NSString).lastPathComponent)
                }
            }
        }

        while !scanner.isAtEnd {
            guard let word = scanner.tokenOnLine() else { scanner.skipLine(); continue }
            if scanner.equals(word, "v") {
                values.removeAll(keepingCapacity: true)
                while let token = scanner.tokenOnLine() { values.append(scanner.number(token) ?? 0) }
                guard values.count >= 3 else { scanner.skipLine(); continue }
                let place = SIMD3(values[0], values[1], values[2])
                whereabouts.include(place)
                positions.append(SIMD3<Float>(place - start))
                // x y z r g b (a widespread extension); x y z w has four values and no colour.
                if values.count >= 6 {
                    if colours.count < positions.count - 1 { colours.append(contentsOf: repeatElement(SIMD4(1, 1, 1, 1), count: positions.count - 1 - colours.count)) }
                    colours.append(simd_clamp(SIMD4(Float(values[3]), Float(values[4]), Float(values[5]), 1), SIMD4(repeating: 0), SIMD4(repeating: 1)))
                } else {
                    allColoured = false
                }
            } else if scanner.equals(word, "vn") {
                values.removeAll(keepingCapacity: true)
                while let token = scanner.tokenOnLine() { values.append(scanner.number(token) ?? 0) }
                normals.append(values.count >= 3 ? SIMD3(Float(values[0]), Float(values[1]), Float(values[2])) : .zero)
            } else if scanner.equals(word, "vt") {
                values.removeAll(keepingCapacity: true)
                while let token = scanner.tokenOnLine() { values.append(scanner.number(token) ?? 0) }
                // The file counts rows of the image from the bottom, the renderer from the top.
                uvs.append(values.count >= 2 ? SIMD2(Float(values[0]), 1 - Float(values[1])) : SIMD2(Float(values.first ?? 0), 1))
            } else if scanner.equals(word, "f") {
                if current < 0 {
                    // The materials decide which parts keep texture coordinates, so they are
                    // read before the first face, wherever the file names them.
                    if !librariesRead, let line = libraryLine(in: bytes, from: scanner.at) { read(libraries: line) }
                    librariesRead = true
                    if let known = groupOf[materialName] {
                        current = known
                    } else {
                        current = groups.count
                        groupOf[materialName] = current
                        groups.append(Group(material: materialName, keepsUV: library.materials[materialName]?.colourImage != nil))
                    }
                }
                face.removeAll(keepingCapacity: true)
                var corners = 0, valid = true
                let keepsUV = groups[current].keepsUV
                while let token = scanner.tokenOnLine() {
                    corners += 1
                    guard var corner = corner(scanner, token, positions: positions.count, uvs: uvs.count, normals: normals.count) else { valid = false; continue }
                    if corner.normal < 0 { groups[current].everyCornerHasNormal = false }
                    if !keepsUV { corner.uv = -1 } else if corner.uv < 0 { groups[current].everyCornerHasUV = false }
                    if let known = groups[current].vertexOf[corner] {
                        face.append(known)
                    } else {
                        let index = UInt32(groups[current].cornerOf.count)
                        groups[current].vertexOf[corner] = index
                        groups[current].cornerOf.append(corner)
                        face.append(index)
                    }
                }
                // The file's own count of faces includes ones that cannot be drawn.
                topology.addFace(corners: corners)
                guard valid, face.count >= 3 else {
                    if corners >= 3 { groups[current].sizes.append(0) }
                    scanner.skipLine(); continue
                }
                guard let triangles = PolygonTriangulation.indices(count: face.count, budget: polygonBudget, position: {
                    positions[Int(groups[current].cornerOf[Int(face[$0])].position)]
                }) else { scanner.skipLine(); continue }
                groups[current].indices.append(contentsOf: triangles.map { face[$0] })
                groups[current].sizes.append(UInt32(face.count))
                if face.count != 3 { groups[current].onlyTriangles = false }
                if smoothing { groups[current].everyFaceFlat = false }
                if namesGroups {
                    let own: Int32
                    if smoothing { own = smoothingGroup } else { ungrouped &-= 1; own = ungrouped }
                    groups[current].smoothingOf.append(contentsOf: repeatElement(own, count: triangles.count / 3))
                }
            } else if scanner.equals(word, "s") {
                if let token = scanner.tokenOnLine() {
                    smoothing = !(scanner.equals(token, "off") || scanner.equals(token, "0"))
                    if !namesGroups {
                        namesGroups = true
                        for g in groups.indices { groups[g].smoothingOf = Array(repeating: 0, count: groups[g].indices.count / 3) }
                    }
                    if smoothing {
                        let number = scanner.integer(from: token.lowerBound, to: token.upperBound).map(\.value) ?? 1
                        smoothingGroup = Int32(clamping: max(number, 1))
                    }
                }
            } else if scanner.equals(word, "usemtl") {
                materialName = scanner.restOfLine()
                current = -1
                continue
            } else if scanner.equals(word, "mtllib") {
                read(libraries: scanner.restOfLine())
                continue
            }
            scanner.skipLine()
        }

        guard !positions.isEmpty else { throw Failure.empty }
        topology.vertices = positions.count
        let coloured = allColoured && colours.count == positions.count
        var parts: [ModelScene.MeshPart] = []
        if groups.allSatisfy({ $0.indices.isEmpty }) {
            // Positions only: a point cloud.
            var part = ModelScene.MeshPart()
            part.primitive = .points
            part.positions = positions
            if coloured { part.colors = colours }
            part.material = 0
            var fallback = neutral
            // These colors are the appearance, not a tint over synthetic gray.
            if coloured { fallback.baseColor = SIMD4(1, 1, 1, 1) }
            scene.materials = [fallback]
            parts = [part]
        } else {
            var textureOf: [String: Int?] = [:]
            for var group in groups where !group.indices.isEmpty {
                var part = ModelScene.MeshPart()
                // Without normals of its own, a file that names smoothing groups gets the
                // normals they say.
                var grouped: [SIMD3<Float>]?
                if !group.everyCornerHasNormal, !group.everyFaceFlat, !group.smoothingOf.isEmpty, group.smoothingOf.count == group.indices.count / 3 {
                    grouped = smoothed(&group, positions: positions)
                }
                part.triangleIndices = group.indices
                part.positions = group.cornerOf.map { positions[Int($0.position)] }
                if coloured { part.colors = group.cornerOf.map { colours[Int($0.position)] } }
                if group.everyCornerHasNormal {
                    part.normals = group.cornerOf.map { normals[Int($0.normal)] }
                } else if let grouped {
                    part.normals = grouped
                } else if group.everyFaceFlat {
                    part.faceted = true
                }
                // Faces left out above have size 0 here and draw nothing.
                if !group.onlyTriangles { part.faceSizes = group.sizes.filter { $0 > 0 } }

                var material = neutral
                // These colors are the appearance, not a tint over synthetic gray.
                if coloured { material.baseColor = SIMD4(1, 1, 1, 1) }
                if let read = library.materials[group.material] {
                    material = read.material(named: group.material)
                    // A color the library names (Kd) is the author's and tints them; without
                    // one the stand-in gray would.
                    if coloured, read.colour == nil { material.baseColor = SIMD4(1, 1, 1, material.baseColor.w) }
                    if let name = read.colourImage {
                        if textureOf[name] == nil {
                            if let data = sidecars?.data(named: name), !data.isEmpty {
                                scene.textures.append(.embedded(bytes: [UInt8](data), mime: ""))
                                textureOf[name] = scene.textures.count - 1
                            } else {
                                scene.diagnostics.missingResources.append((SidecarFolder.cleaned(name) as NSString? ?? name as NSString).lastPathComponent)
                                textureOf[name] = .some(nil)
                            }
                        }
                        if let texture = textureOf[name] ?? nil, group.keepsUV, group.everyCornerHasUV {
                            part.uv0 = group.cornerOf.map { uvs[Int($0.uv)] }
                            material.baseColorTexture = texture
                            // Kd multiplies the image. Without Kd, use the image unchanged.
                            if read.colour == nil { material.baseColor = SIMD4(1, 1, 1, material.baseColor.w) }
                        }
                    }
                }
                part.material = scene.materials.count
                scene.materials.append(material)
                parts.append(part)
            }
        }

        scene.meshes = [ModelScene.Mesh(name: "", parts: parts)]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        scene.topology = topology
        return (scene, origin == nil ? whereabouts.farMiddle : nil)
    }

    /// The normals smoothing groups say: at each place, the faces of one group around it, each
    /// by its angle there, make one normal, and a face in none has its own. Corners at one
    /// place that take different normals become different vertices.
    private static func smoothed(_ group: inout Group, positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let indices = group.indices, triangles = indices.count / 3
        let single = group.smoothingOf.allSatisfy { $0 == group.smoothingOf[0] } && group.smoothingOf[0] >= 0
        // Where the normals are added up: one sum for each place and group.
        var sums: [SIMD3<Float>] = []
        var sumOf: [Int64: Int32] = [:]
        var sumAt = [Int32](repeating: -1, count: single ? positions.count : 0)
        var cornerSum = [Int32](repeating: 0, count: indices.count)
        for t in 0..<triangles {
            let v = (Int(indices[t * 3]), Int(indices[t * 3 + 1]), Int(indices[t * 3 + 2]))
            let at = (Int(group.cornerOf[v.0].position), Int(group.cornerOf[v.1].position), Int(group.cornerOf[v.2].position))
            let p = (positions[at.0], positions[at.1], positions[at.2])
            var facing = simd_cross(p.1 - p.0, p.2 - p.0)
            let length = simd_length(facing)
            facing = length > 0 && length.isFinite ? facing / length : .zero
            func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
                let la = simd_length(a), lb = simd_length(b)
                return la > 0 && lb > 0 ? acos(min(1, max(-1, simd_dot(a, b) / (la * lb)))) : 0
            }
            func add(_ k: Int, _ place: Int, _ weight: Float) {
                var s: Int32
                if single {
                    s = sumAt[place]
                    if s < 0 { s = Int32(sums.count); sumAt[place] = s; sums.append(.zero) }
                } else {
                    let key = Int64(place) << 32 | Int64(UInt32(bitPattern: group.smoothingOf[t]))
                    if let known = sumOf[key] { s = known } else { s = Int32(sums.count); sumOf[key] = s; sums.append(.zero) }
                }
                if facing.x.isFinite, weight.isFinite { sums[Int(s)] += facing * weight }
                cornerSum[t * 3 + k] = s
            }
            add(0, at.0, angle(p.1 - p.0, p.2 - p.0))
            add(1, at.1, angle(p.2 - p.1, p.0 - p.1))
            add(2, at.2, angle(p.0 - p.2, p.1 - p.2))
        }
        // A normal that adds up to nothing is left as nothing; the renderer lights it by its triangles.
        let made = sums.map { sum -> SIMD3<Float> in let l = simd_length(sum); return l > 0 && l.isFinite ? sum / l : .zero }
        if single { return group.cornerOf.map { made[Int(sumAt[Int($0.position)])] } }
        var cornerOf: [Corner] = [], normals: [SIMD3<Float>] = []
        var remapped = [UInt32](repeating: 0, count: indices.count)
        var vertexOf: [Int64: UInt32] = [:]
        for c in indices.indices {
            let key = Int64(indices[c]) << 32 | Int64(cornerSum[c])
            if let known = vertexOf[key] { remapped[c] = known; continue }
            let index = UInt32(cornerOf.count)
            vertexOf[key] = index
            cornerOf.append(group.cornerOf[Int(indices[c])])
            normals.append(made[Int(cornerSum[c])])
            remapped[c] = index
        }
        group.cornerOf = cornerOf
        group.indices = remapped
        return normals
    }

    /// The names on the first `mtllib` line at or after `start`, for files that name their
    /// materials after the faces that use them.
    private static func libraryLine(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> String? {
        guard let base = bytes.baseAddress, start < bytes.count else { return nil }
        let word = Array("\nmtllib".utf8)
        var from = start
        while from < bytes.count, let found = memmem(base + from, bytes.count - from, word, word.count) {
            let at = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + word.count
            guard at < bytes.count else { return nil }
            if bytes[at] == 0x20 || bytes[at] == 0x09 {
                var scanner = ByteScanner(bytes, at: at)
                return scanner.restOfLine()
            }
            from = at
        }
        return nil
    }

    /// "7", "7/2", "7//3" or "7/2/3"; an index counts from 1, or back from the end when negative.
    private static func corner(_ scanner: ByteScanner, _ token: Range<Int>, positions: Int, uvs: Int, normals: Int) -> Corner? {
        @inline(__always) func resolve(_ value: Int, _ count: Int) -> Int32? {
            let index = value > 0 ? value - 1 : count + value
            return value != 0 && index >= 0 && index < count ? Int32(index) : nil
        }
        guard let (v, afterV) = scanner.integer(from: token.lowerBound, to: token.upperBound), let position = resolve(v, positions) else { return nil }
        var corner = Corner(position: position, uv: -1, normal: -1)
        var at = afterV
        guard at < token.upperBound, scanner.bytes[at] == 0x2f else { return corner }
        at += 1
        if let (t, afterT) = scanner.integer(from: at, to: token.upperBound) {
            if let uv = resolve(t, uvs) { corner.uv = uv }
            at = afterT
        }
        while at < token.upperBound, scanner.bytes[at] != 0x2f { at += 1 }
        guard at < token.upperBound else { return corner }
        if let (n, _) = scanner.integer(from: at + 1, to: token.upperBound), let normal = resolve(n, normals) { corner.normal = normal }
        return corner
    }
}
