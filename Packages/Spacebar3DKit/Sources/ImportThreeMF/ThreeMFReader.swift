import CoreGraphics
import Foundation
import ImageIO
import ModelCore
import simd

/// Reads 3MF: a zip package of XML model files.
///
/// Kept from the file: every object's vertices and triangles, the objects built from
/// other objects (components) with their placements, objects kept in separate model files
/// of the package (the production extension, which slicers write routinely), the build
/// items with their placements, colours from base materials and colour groups (per
/// object, per triangle or per corner), and images with their coordinates. Of properties
/// laid over each other, a colour with images over it becomes one image when the images
/// share their coordinates; otherwise colours are multiplied and the first image is kept.
/// A base material's display properties give its metallic and roughness values, which
/// layers laid over it move toward a plain colour's (no metal, the usual roughness) by the
/// share they cover (their accumulated alpha), as the Materials Extension has display
/// properties blended for a preview; a face with no layer keeps them. Colours beneath an
/// image are kept when it is multiplied, and shown through it by its alpha when it is mixed.
/// A translucent material is drawn see-through, by a fixed amount. Beam
/// lattices and slices are passed over.
///
/// 3MF has no normals: every triangle is shaded flat, as 3MF viewers do.
public enum ThreeMFReader {
    public enum Failure: Error, LocalizedError, Equatable {
        case notAPackage
        case noModel
        case damaged
        case tooLarge
        case empty

        public var errorDescription: String? {
            switch self {
            case .notAPackage: return L10n.text("The file is not a 3MF package.")
            case .noModel: return L10n.text("The 3MF package holds no model.")
            case .damaged: return L10n.text("The 3MF package is damaged.")
            case .tooLarge: return L10n.text("The model is too large to show.")
            case .empty: return L10n.text("The file contains no geometry.")
            }
        }
    }

    /// Objects may be built from objects built from objects; real files go two or three deep.
    static let maxDepth = 16
    /// Placed objects and triangles in the whole scene. Components let a small file ask
    /// for an enormous scene; these stop that.
    static let maxInstances = 100_000
    static let maxTriangles = 50_000_000

    public static func load(_ url: URL) throws -> ModelScene {
        try scene(from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func scene(from data: Data) throws -> ModelScene {
        let archive: ZipArchive
        do { archive = try ZipArchive(data) } catch { throw Failure.notAPackage }
        var builder = Builder(archive: archive)
        return try builder.build()
    }

    // MARK: What a model file holds

    struct Reference: Hashable { var file: String; var id: Int }

    struct Component { var object: Reference; var transform: simd_float4x4 }

    final class Object {
        var vertices: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        /// Per triangle: property group, and the index into it for each corner; -1 for none.
        /// Empty when no triangle and not the object itself names a property.
        var properties: [Int32] = []
        var defaultGroup: Int32 = -1
        var defaultIndex: Int32 = -1
        var components: [Component] = []
        /// Where the vertices are counted from when the object lies far from its own origin
        /// (see `Whereabouts`): they hold the file's numbers less this, taken off in Double
        /// before they are rounded to Float, and the placement puts it back.
        var origin = SIMD3<Double>.zero
        var whereabouts = Whereabouts()
        /// Filled when the object is first placed in the scene.
        var mesh: Int??
    }

    struct ModelFile {
        var objects: [Int: Object] = [:]
        /// Colours of base materials and colour groups, by the group's id (sRGB, with alpha).
        var colors: [Int: [SIMD4<Float>]] = [:]
        /// The looks that base materials name, and which one each entry of a group of
        /// base materials has (an index into `surfaces`, -1 for none), by the group's id.
        var surfaces: [Surface] = []
        var surfaceOf: [Int: [Int32]] = [:]
        /// Image coordinates by group id, with the id of the image they belong to.
        var coordinates: [Int: TextureGroup] = [:]
        /// Where in the package each image is, by its id.
        var images: [Int: String] = [:]
        /// The colour groups that are base materials: what a thing is made of, not a
        /// colour put on it.
        var materials: Set<Int> = []
        /// Properties laid over each other, by group id.
        var layered: [Int: Layered] = [:]
        /// The layered groups that are drawn as one image made here.
        var composed: Set<Int> = []
        var items: [Component] = []
        /// The objects that lie far out, by id, and their middles: a second reading takes
        /// the middle off before the corners are rounded.
        var far: [Int: SIMD3<Double>] = [:]
    }

    struct TextureGroup { var image: Int; var uvs: [SIMD2<Float>] = [] }

    /// `groups` are the property groups laid over each other; each entry holds one index
    /// into each of them. `multiplies` says, for each layer after the first, whether it is
    /// multiplied with what is beneath; otherwise it is mixed over it, by how solid it is.
    struct Layered {
        var groups: [Int]
        var multiplies: [Bool] = []
        var entries: [[Int32]] = []

        /// Whether layer `layer` is multiplied. Over a base material nothing is: the
        /// format has the material left out of the mixing, with the first method given.
        func multiplies(_ layer: Int, overMaterial: Bool) -> Bool {
            layer >= (overMaterial ? 2 : 1) && layer - 1 < multiplies.count && multiplies[layer - 1]
        }
    }

    /// A colour as seen on screen, as light, and back. Layers are put together as light.
    static func light(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func one(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return SIMD3(one(c.x), one(c.y), one(c.z))
    }
    static func seen(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func one(_ v: Float) -> Float { let v = min(max(v, 0), 1); return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        return SIMD3(one(c.x), one(c.y), one(c.z))
    }
    /// One colour over another, each as seen on screen with how solid it is.
    static func laid(_ over: SIMD4<Float>, on under: SIMD4<Float>, multiplied: Bool) -> SIMD4<Float> {
        let a = light(SIMD3(over.x, over.y, over.z)), b = light(SIMD3(under.x, under.y, under.z))
        if multiplied { return SIMD4(seen(a * b), over.w * under.w) }
        return SIMD4(seen(a * over.w + b * (1 - over.w)), over.w + under.w * (1 - over.w))
    }

    /// Images made here, from a colour with images laid over it, are numbered from here
    /// on, by the id of their group; ids in files are far smaller.
    static let composedImages = 1 << 40
    /// The longer side of an image made here.
    static let maxComposedSide = 2048

    /// How a base material is to look, from its display properties.
    struct Surface: Hashable {
        var metallic: Float = 0
        var roughness: Float = 0.65
        var opacity: Float = 1
    }

    /// The file gives a translucent material its absorption per metre and a refractive
    /// index, which this renderer has no use for; it is drawn this see-through instead.
    static let translucentOpacity: Float = 0.5

    /// What one corner of a triangle is given.
    struct Corner: Hashable {
        var color = SIMD4<Float>(1, 1, 1, 1)
        /// Index into the model file's `surfaces`; -1 for none.
        var surface: Int32 = -1
        var image: Int = -1
        var uv = SIMD2<Float>(0, 0)
        /// How the image lies over colours beneath it: 0 none, 1 multiplied, 2 mixed by its alpha.
        var beneath: UInt8 = 0
        /// How much of the surface layers over a base material cover (their accumulated alpha).
        var cover: Float = 0
    }

    /// Images in one model. A file can name any number; this many are plenty.
    static let maxImages = 256

    // MARK: Building the scene

    private struct MaterialKey: Hashable { var color: SIMD4<Float>; var texture: Int?; var surface: Surface?; var beneath: UInt8; var cover: Float }

    private struct Builder {
        let archive: ZipArchive
        var files: [String: ModelFile] = [:]
        var scene = ModelScene()
        var materialIndex: [MaterialKey: Int] = [:]
        /// For an image made here: the share of the surface its layers cover.
        var imageCover: [Int: Float] = [:]
        var imageIndex: [Reference: Int?] = [:]
        var instances = 0
        var triangles = 0

        mutating func build() throws -> ModelScene {
            guard let root = rootModel() else { throw Failure.noModel }
            let model = try file(root)
            // 3MF is Z up; the renderer's convention is Y up.
            scene.nodes.append(ModelScene.Node(name: "up", transform: simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))))
            if model.items.isEmpty {
                // No build section: every object of the file, where it is.
                for id in model.objects.keys.sorted() { try place(Reference(file: root, id: id), matrix_identity_float4x4, parent: 0, depth: 0) }
            } else {
                for item in model.items { try place(item.object, item.transform, parent: 0, depth: 0) }
            }
            guard scene.topology.faces > 0 else { throw Failure.empty }
            return scene
        }

        /// The package's main model file: the one its relationships name, else the usual
        /// place, else the first model file there is.
        private func rootModel() -> String? {
            if let rels = archive.resolve("_rels/.rels"), let data = try? archive.contents(of: rels) {
                let target: String? = data.withUnsafeBytes { raw in
                    var tags = XMLTags(raw.bindMemory(to: UInt8.self))
                    while let tag = tags.next() {
                        guard tags.name(tag, is: "Relationship"), let type = tags.attribute(tag, "Type"), tags.string(type).hasSuffix("/3dmodel"),
                              let target = tags.attribute(tag, "Target") else { continue }
                        return tags.string(target)
                    }
                    return nil
                }
                if let target, let found = archive.resolve(target) { return found }
            }
            return archive.resolve("3D/3dmodel.model") ?? archive.names.first { $0.lowercased().hasSuffix(".model") }
        }

        private mutating func file(_ name: String) throws -> ModelFile {
            if let known = files[name] { return known }
            let data: Data
            do { data = try archive.contents(of: name) } catch ZipArchive.Failure.tooLarge { throw Failure.tooLarge } catch { throw Failure.damaged }
            var parsed = data.withUnsafeBytes { ThreeMFReader.parse($0.bindMemory(to: UInt8.self), file: name, archive: archive, origins: [:]) }
            // An object far from its own origin is read again from its own middle, so that
            // its corners are near zero when they are rounded to Float.
            if !parsed.far.isEmpty {
                let origins = parsed.far
                parsed = data.withUnsafeBytes { ThreeMFReader.parse($0.bindMemory(to: UInt8.self), file: name, archive: archive, origins: origins) }
            }
            files[name] = parsed
            return parsed
        }

        private mutating func place(_ reference: Reference, _ transform: simd_float4x4, parent: Int, depth: Int) throws {
            guard depth <= ThreeMFReader.maxDepth else { return }
            instances += 1
            guard instances <= ThreeMFReader.maxInstances else { throw Failure.tooLarge }
            // An object that is not there is left out; the rest of the model still shows.
            guard let model = try? file(reference.file), let object = model.objects[reference.id] else { return }
            var node = ModelScene.Node(parent: parent, transform: transform)
            if object.origin != .zero {
                // The mesh is counted from the object's middle: put that back in the placement, in Double.
                let o = object.origin
                let moved = SIMD3<Double>(SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)) * o.x
                    + SIMD3<Double>(SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)) * o.y
                    + SIMD3<Double>(SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)) * o.z
                    + SIMD3<Double>(SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z))
                node.transform.columns.3 = SIMD4(SIMD3<Float>(moved), transform.columns.3.w)
            }
            if object.mesh == nil { object.mesh = .some(makeMesh(object, in: model, file: reference.file)) }
            if let mesh = object.mesh ?? nil {
                node.mesh = mesh
                let count = object.triangles.count / 3
                triangles += count
                guard triangles <= ThreeMFReader.maxTriangles else { throw Failure.tooLarge }
                scene.topology.faces += count
                scene.topology.triangles += count
                scene.topology.vertices += object.vertices.count
            }
            scene.nodes.append(node)
            let index = scene.nodes.count - 1
            for component in object.components { try place(component.object, component.transform, parent: index, depth: depth + 1) }
        }

        private mutating func makeMesh(_ object: Object, in model: ModelFile, file: String) -> Int? {
            guard !object.triangles.isEmpty, !object.vertices.isEmpty else { return nil }
            func corner(_ group: Int32, _ index: Int32) -> Corner? {
                guard group >= 0, index >= 0 else { return nil }
                return ThreeMFReader.corner(Int(group), Int(index), in: model)
            }
            let fallback = corner(object.defaultGroup, object.defaultIndex) ?? Corner()
            let count = object.triangles.count / 3

            // One colour and no image for the whole object, as most files have it?
            var uniform = true
            var first = fallback
            if !object.properties.isEmpty {
                var seen: Corner?
                scan: for t in 0..<count {
                    let group = object.properties[t * 4]
                    for k in 1...3 {
                        let c = corner(group, object.properties[t * 4 + k]) ?? fallback
                        if seen == nil { seen = c } else if seen != c { uniform = false; break scan }
                    }
                }
                if let seen, uniform { first = seen }
            }
            if uniform, first.image < 0 {
                var part = ModelScene.MeshPart()
                part.faceted = true
                part.positions = object.vertices
                part.triangleIndices = object.triangles
                part.material = material(first.color, texture: nil, surface: first.surface >= 0 ? model.surfaces[Int(first.surface)] : nil, cover: first.cover)
                scene.meshes.append(ModelScene.Mesh(parts: [part]))
                return scene.meshes.count - 1
            }

            // One part for the triangles without an image and one per image. A vertex
            // takes what the corner using it is given; where corners disagree, the vertex
            // is repeated. The copies of one vertex are kept in a chain, across all parts.
            struct Making { var part = ModelScene.MeshPart(); var texture: Int?; var surface: Int32 = -1; var color: SIMD4<Float>?; var varies = false; var beneath: UInt8 = 0; var cover: Float = 0 }
            struct Slot: Hashable { var image: Int; var surface: Int32; var beneath: UInt8; var cover: Float }
            struct Copy { var corner: Corner; var part: Int32; var index: UInt32; var next: Int32 }
            var makings: [Making] = []
            var bySlot: [Slot: Int] = [:]
            var head = [Int32](repeating: -1, count: object.vertices.count)
            var copies: [Copy] = []
            copies.reserveCapacity(object.vertices.count)
            // Triangles come in runs of one group and one image; what was looked up for
            // the last one mostly serves the next.
            var lastGroup = Int32.min
            var lastColors: [SIMD4<Float>]?
            var lastSurfaces: [Int32]?
            var lastCoordinates: TextureGroup?
            var lastImage = Int.min, lastTexture: Int?, lastMaking = 0, lastSlot = Slot(image: Int.min, surface: -1, beneath: 0, cover: 0)
            let white = SIMD4<Float>(1, 1, 1, 1)
            for t in 0..<count {
                var c0 = fallback, c1 = fallback, c2 = fallback
                if !object.properties.isEmpty {
                    let group = object.properties[t * 4]
                    if group != lastGroup {
                        lastGroup = group
                        lastColors = group >= 0 ? model.colors[Int(group)] : nil
                        lastSurfaces = lastColors == nil ? nil : model.surfaceOf[Int(group)]
                        lastCoordinates = group >= 0 && lastColors == nil ? model.coordinates[Int(group)] : nil
                    }
                    let i0 = Int(object.properties[t * 4 + 1]), i1 = Int(object.properties[t * 4 + 2]), i2 = Int(object.properties[t * 4 + 3])
                    if let lastColors {
                        if i0 >= 0, i0 < lastColors.count { c0 = Corner(color: lastColors[i0], surface: lastSurfaces?[i0] ?? -1) }
                        if i1 >= 0, i1 < lastColors.count { c1 = Corner(color: lastColors[i1], surface: lastSurfaces?[i1] ?? -1) }
                        if i2 >= 0, i2 < lastColors.count { c2 = Corner(color: lastColors[i2], surface: lastSurfaces?[i2] ?? -1) }
                    } else if let lastCoordinates {
                        let n = lastCoordinates.uvs.count
                        if i0 >= 0, i0 < n { c0 = Corner(image: lastCoordinates.image, uv: lastCoordinates.uvs[i0]) }
                        if i1 >= 0, i1 < n { c1 = Corner(image: lastCoordinates.image, uv: lastCoordinates.uvs[i1]) }
                        if i2 >= 0, i2 < n { c2 = Corner(image: lastCoordinates.image, uv: lastCoordinates.uvs[i2]) }
                    } else {
                        c0 = corner(group, Int32(i0)) ?? fallback; c1 = corner(group, Int32(i1)) ?? fallback; c2 = corner(group, Int32(i2)) ?? fallback
                    }
                }
                // A triangle is drawn with one image, when all its corners name the same.
                // And with one look: the first corner's.
                c1.surface = c0.surface; c2.surface = c0.surface
                c1.cover = c0.cover; c2.cover = c0.cover
                var slot = Slot(image: -1, surface: c0.surface, beneath: 0, cover: c0.cover)
                var texture: Int?
                if c0.image >= 0, c1.image == c0.image, c2.image == c0.image {
                    if c0.image != lastImage { lastImage = c0.image; lastTexture = image(Reference(file: file, id: c0.image), in: model) }
                    texture = lastTexture
                    if texture != nil { slot.image = c0.image }
                }
                if texture == nil {
                    c0.image = -1; c0.uv = .zero; c1.image = -1; c1.uv = .zero; c2.image = -1; c2.uv = .zero
                } else {
                    // Over an image the colour is the part's, not the corner's; except where
                    // the colours beneath it show (multiplied, or mixed by the image's alpha).
                    c1.beneath = c0.beneath; c2.beneath = c0.beneath
                    slot.beneath = c0.beneath
                    if c0.beneath == 0 { c0.color = white; c1.color = white; c2.color = white }
                }
                var m = lastMaking
                if slot != lastSlot {
                    lastSlot = slot
                    if let known = bySlot[slot] { m = known } else {
                        var making = Making()
                        making.part.faceted = true
                        making.texture = texture
                        making.surface = slot.surface
                        making.beneath = slot.beneath
                        making.cover = slot.cover
                        makings.append(making)
                        m = makings.count - 1
                        bySlot[slot] = m
                    }
                    lastMaking = m
                }
                for k in 0..<3 {
                    let corner = k == 0 ? c0 : (k == 1 ? c1 : c2)
                    if let color = makings[m].color { if color != corner.color { makings[m].varies = true } } else { makings[m].color = corner.color }
                    let vertex = Int(object.triangles[t * 3 + k])
                    var at = head[vertex]
                    while at >= 0, !(copies[Int(at)].part == Int32(m) && copies[Int(at)].corner == corner) { at = copies[Int(at)].next }
                    if at >= 0 {
                        makings[m].part.triangleIndices.append(copies[Int(at)].index)
                    } else {
                        let index = UInt32(makings[m].part.positions.count)
                        copies.append(Copy(corner: corner, part: Int32(m), index: index, next: head[vertex]))
                        head[vertex] = Int32(copies.count - 1)
                        makings[m].part.positions.append(object.vertices[vertex])
                        makings[m].part.colors.append(corner.color)
                        if texture != nil { makings[m].part.uv0.append(corner.uv) }
                        makings[m].part.triangleIndices.append(index)
                    }
                }
            }
            var parts: [ModelScene.MeshPart] = []
            for making in makings {
                var part = making.part
                let surface = making.surface >= 0 ? model.surfaces[Int(making.surface)] : nil
                if making.varies || making.beneath != 0 {
                    part.material = material(white, texture: making.texture, surface: surface, beneath: making.beneath, cover: making.cover)
                } else {
                    part.colors = []
                    part.material = material(making.color ?? white, texture: making.texture, surface: surface, cover: making.cover)
                }
                parts.append(part)
            }
            scene.meshes.append(ModelScene.Mesh(parts: parts))
            return scene.meshes.count - 1
        }

        /// The image with this id in this model file, as a texture of the scene; nil when
        /// it is not in the package.
        private mutating func image(_ reference: Reference, in model: ModelFile) -> Int? {
            if let known = imageIndex[reference] { return known }
            var made: Int?
            if reference.id >= ThreeMFReader.composedImages {
                if scene.textures.count < ThreeMFReader.maxImages, let (texture, share) = compose(reference.id - ThreeMFReader.composedImages, in: model) {
                    scene.textures.append(texture)
                    made = scene.textures.count - 1
                    imageCover[scene.textures.count - 1] = share
                }
            } else if scene.textures.count < ThreeMFReader.maxImages, let path = model.images[reference.id], let name = archive.resolve(path),
               let data = try? archive.contents(of: name), !data.isEmpty {
                scene.textures.append(.embedded(bytes: [UInt8](data), mime: ""))
                made = scene.textures.count - 1
            }
            imageIndex[reference] = .some(made)
            return made
        }

        /// The colour of a layered group with its images painted over it, as one image the
        /// size of the first (made smaller when that is very large).
        private func compose(_ group: Int, in model: ModelFile) -> (ModelScene.TextureRef, Float)? {
            guard let layered = model.layered[group], let base = layered.groups.first, let colours = model.colors[base] else { return nil }
            let index = Int(layered.entries.first?.first ?? 0)
            let colour = index >= 0 && index < colours.count ? colours[index] : SIMD4<Float>(1, 1, 1, 1)
            let overMaterial = model.materials.contains(base)
            var images: [(image: CGImage, multiplied: Bool)] = []
            for (layer, id) in layered.groups.enumerated().dropFirst() {
                guard let coordinates = model.coordinates[id], let path = model.images[coordinates.image], let name = archive.resolve(path),
                      let data = try? archive.contents(of: name), let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                images.append((image, layered.multiplies(layer, overMaterial: overMaterial)))
            }
            guard let first = images.first?.image, first.width > 0, first.height > 0 else { return nil }
            let scale = min(1, Double(ThreeMFReader.maxComposedSide) / Double(max(first.width, first.height)))
            let width = max(1, Int(Double(first.width) * scale)), height = max(1, Int(Double(first.height) * scale))
            // The layers are put together as light, which is how the format has them mixed:
            // painted in a space where a number is an amount of light, sixteen bits deep
            // so that the darks keep their steps, and brought back to what is seen.
            var deep = [UInt16](repeating: 0, count: width * height * 4)
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            let drawn: Bool = deep.withUnsafeMutableBytes { raw in
                guard let space = CGColorSpace(name: CGColorSpace.linearSRGB),
                      let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return false }
                let all = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(CGColor(srgbRed: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1))
                context.fill(all)
                for layer in images {
                    context.setBlendMode(layer.multiplied ? .multiply : .normal)
                    context.draw(layer.image, in: all)
                }
                return true
            }
            if drawn {
                // What each amount of light is on screen, worked out once for every 4096th of it.
                let steps = 4096
                let table = (0...steps).map { UInt8((ThreeMFReader.seen(SIMD3(repeating: Float($0) / Float(steps))).x * 255).rounded()) }
                for i in stride(from: 0, to: deep.count, by: 4) {
                    for channel in 0..<3 { rgba[i + channel] = table[(Int(deep[i + channel]) * steps + 32767) / 65535] }
                }
            }
            guard drawn else { return nil }
            // How much of the surface the images cover: their alpha laid over each other, on average.
            var share: Float = 0
            let side = max(1, min(256, max(width, height)))
            var alpha = [UInt8](repeating: 0, count: side * side)
            let counted: Bool = alpha.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
                for layer in images { context.draw(layer.image, in: CGRect(x: 0, y: 0, width: side, height: side)) }
                return true
            }
            if counted { share = Float(alpha.reduce(0) { $0 + Int($1) }) / Float(alpha.count * 255) }
            return (.pixels(width: width, height: height, rgba: rgba), share)
        }

        private mutating func material(_ color: SIMD4<Float>, texture: Int?, surface: Surface?, beneath: UInt8 = 0, cover: Float = 0) -> Int {
            // Layers laid over a base material cover that share of it: the image's (made here)
            // and the colours', accumulated. Where covered it is paint, not the material.
            var covered = cover
            if let texture, let share = imageCover[texture] { covered = 1 - (1 - covered) * (1 - share) }
            let key = MaterialKey(color: color, texture: texture, surface: surface, beneath: beneath, cover: covered)
            if let known = materialIndex[key] { return known }
            var material = ModelScene.Material()
            material.baseColor = SIMD4(color.x, color.y, color.z, 1)
            material.opacity = color.w
            material.baseColorTexture = texture
            material.roughness = 0.65
            if let surface {
                // Display properties are blended for the preview (Materials Extension 1.2.1,
                // ch. 5): paint's are a plain colour's, with no metal and the usual roughness.
                let paint = min(max(covered, 0), 1)
                material.metallic = surface.metallic * (1 - paint)
                material.roughness = surface.roughness * (1 - paint) + 0.65 * paint
                material.opacity *= surface.opacity
                material.authoredPBR = true
            }
            material.imageOverVertexColour = beneath == 2
            material.doubleSided = true
            scene.materials.append(material)
            materialIndex[key] = scene.materials.count - 1
            return scene.materials.count - 1
        }
    }

    /// What entry `index` of property group `group` gives a corner.
    static func corner(_ group: Int, _ index: Int, in model: ModelFile) -> Corner? {
        if let list = model.colors[group] {
            guard index < list.count else { return nil }
            return Corner(color: list[index], surface: model.surfaceOf[group]?[index] ?? -1)
        }
        if let coordinates = model.coordinates[group] {
            return index < coordinates.uvs.count ? Corner(image: coordinates.image, uv: coordinates.uvs[index]) : nil
        }
        if let layered = model.layered[group], index < layered.entries.count {
            var corner = Corner()
            let entry = layered.entries[index]
            if model.composed.contains(group) {
                // The colour is painted into the image; its look stays with the corner.
                let base = Int(entry.first ?? 0)
                let surface = layered.groups.first.flatMap { model.surfaceOf[$0] }.flatMap { base >= 0 && base < $0.count ? $0[base] : nil } ?? -1
                for (layer, id) in layered.groups.enumerated() {
                    let i = layer < entry.count ? Int(entry[layer]) : 0
                    if let coordinates = model.coordinates[id], i >= 0, i < coordinates.uvs.count {
                        return Corner(surface: surface, image: composedImages + group, uv: coordinates.uvs[i])
                    }
                }
            }
            // The colours are put together from the bottom up. A base material at the
            // bottom is left out of that, and what the layers come to is then mixed over
            // its colour: the surface stays as solid as the material is.
            let overMaterial = layered.groups.first.map { model.materials.contains($0) } ?? false
            var material: SIMD4<Float>?, colour: SIMD4<Float>?
            var imageLayer = -1
            for (layer, id) in layered.groups.enumerated() {
                let i = layer < entry.count ? Int(entry[layer]) : 0
                if let list = model.colors[id], i >= 0, i < list.count {
                    if layer == 0, overMaterial { material = list[i] }
                    else if let beneath = colour { colour = laid(list[i], on: beneath, multiplied: layered.multiplies(layer, overMaterial: overMaterial)) }
                    else { colour = list[i] }
                    if corner.surface < 0, let surfaces = model.surfaceOf[id], i < surfaces.count { corner.surface = surfaces[i] }
                } else if corner.image < 0, let coordinates = model.coordinates[id], i >= 0, i < coordinates.uvs.count {
                    corner.image = coordinates.image
                    corner.uv = coordinates.uvs[i]
                    imageLayer = layer
                }
            }
            if imageLayer > 0, material != nil || colour != nil {
                corner.beneath = layered.multiplies(imageLayer, overMaterial: overMaterial) ? 1 : 2
            }
            if material != nil, let colour { corner.cover = colour.w }
            if let material, let colour {
                let mixed = laid(colour, on: SIMD4(material.x, material.y, material.z, 1), multiplied: false)
                corner.color = SIMD4(mixed.x, mixed.y, mixed.z, material.w)
            } else if let only = material ?? colour {
                corner.color = only
            }
            return corner
        }
        return nil
    }

    // MARK: Parsing one model file

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, file: String, archive: ZipArchive, origins: [Int: SIMD3<Double>] = [:]) -> ModelFile {
        var model = ModelFile()
        var tags = XMLTags(bytes)
        var object: Object?
        var objectID = -1
        var group = -1             // the base materials or colour group being read
        var coordinates = -1       // the group of image coordinates being read
        var layered = -1           // the group of layered properties being read
        var entries = 0            // coordinates and layered entries read, all groups together
        var uvs: [SIMD2<Float>] = []   // of the group of coordinates being read
        var display = -1           // the display properties being read
        var displays: [Int: [Surface]] = [:]
        /// Which display properties a group of base materials names, and each of its bases.
        var groupDisplay: [Int: Int] = [:]
        var baseDisplay: [Int: [Int]] = [:]
        var inBuild = false

        /// "/3D/Objects/part.model" as the archive names it; the file itself when there is no path.
        func target(_ tag: XMLTags.Tag) -> String {
            guard let path = tags.attribute(tag, "path") else { return file }
            return archive.resolve(tags.string(path)) ?? ""
        }

        while let tag = tags.next() {
            if tag.closing {
                if tags.name(tag, is: "object"), let finished = object {
                    finish(finished)
                    // Objects built from others hold no corners of their own to move.
                    if finished.components.isEmpty, finished.origin == .zero, let middle = finished.whereabouts.farMiddle { model.far[objectID] = middle }
                    model.objects[objectID] = finished
                    object = nil
                } else if tags.name(tag, is: "basematerials") || tags.name(tag, is: "colorgroup") {
                    group = -1
                } else if tags.name(tag, is: "texture2dgroup") {
                    if coordinates >= 0 { model.coordinates[coordinates]?.uvs.append(contentsOf: uvs) }
                    uvs.removeAll(keepingCapacity: true)
                    coordinates = -1
                } else if tags.name(tag, is: "multiproperties") {
                    layered = -1
                } else if tags.name(tag, is: "pbmetallicdisplayproperties") || tags.name(tag, is: "pbspeculardisplayproperties")
                            || tags.name(tag, is: "translucentdisplayproperties") {
                    display = -1
                } else if tags.name(tag, is: "build") {
                    inBuild = false
                }
                continue
            }
            if let current = object {
                if tags.name(tag, is: "vertex") {
                    var from = tag.attributes.lowerBound
                    guard let x = tags.attribute(tag, "x", from: &from).flatMap(tags.number), let y = tags.attribute(tag, "y", from: &from).flatMap(tags.number),
                          let z = tags.attribute(tag, "z", from: &from).flatMap(tags.number) else {
                        // Kept, so that the triangles' numbering still fits.
                        current.vertices.append(.zero)
                        continue
                    }
                    let place = SIMD3(x, y, z)
                    current.whereabouts.include(place)
                    current.vertices.append(SIMD3<Float>(place - current.origin))
                } else if tags.name(tag, is: "triangle") {
                    var from = tag.attributes.lowerBound
                    guard let a = tags.attribute(tag, "v1", from: &from).flatMap(tags.index), let b = tags.attribute(tag, "v2", from: &from).flatMap(tags.index),
                          let c = tags.attribute(tag, "v3", from: &from).flatMap(tags.index), a <= Int(UInt32.max), b <= Int(UInt32.max), c <= Int(UInt32.max) else { continue }
                    let pid = tags.attribute(tag, "pid", from: &from).flatMap(tags.index), p1 = tags.attribute(tag, "p1", from: &from).flatMap(tags.index)
                    if pid != nil || p1 != nil || !current.properties.isEmpty || current.defaultGroup >= 0 {
                        if current.properties.isEmpty {
                            // The triangles so far named nothing.
                            current.properties = [Int32](repeating: -1, count: current.triangles.count / 3 * 4)
                            if current.defaultGroup >= 0 {
                                for t in 0..<(current.triangles.count / 3) {
                                    current.properties[t * 4] = current.defaultGroup
                                    for k in 1...3 { current.properties[t * 4 + k] = current.defaultIndex }
                                }
                            }
                        }
                        let groupID = pid.map { Int32(clamping: $0) } ?? current.defaultGroup
                        let first = p1.map { Int32(clamping: $0) } ?? (pid == nil ? current.defaultIndex : 0)
                        let second = tags.attribute(tag, "p2", from: &from).flatMap(tags.index).map { Int32(clamping: $0) } ?? first
                        let third = tags.attribute(tag, "p3", from: &from).flatMap(tags.index).map { Int32(clamping: $0) } ?? first
                        current.properties.append(groupID); current.properties.append(first); current.properties.append(second); current.properties.append(third)
                    }
                    current.triangles.append(UInt32(a)); current.triangles.append(UInt32(b)); current.triangles.append(UInt32(c))
                } else if tags.name(tag, is: "component") {
                    guard let id = tags.attribute(tag, "objectid").flatMap(tags.index), current.components.count < maxInstances else { continue }
                    current.components.append(Component(object: Reference(file: target(tag), id: id), transform: transform(tags, tag)))
                }
                if tag.selfClosing, tags.name(tag, is: "object") { object = nil }
                continue
            }
            if tags.name(tag, is: "object") {
                guard let id = tags.attribute(tag, "id").flatMap(tags.index) else { continue }
                let made = Object()
                if let pid = tags.attribute(tag, "pid").flatMap(tags.index) {
                    made.defaultGroup = Int32(clamping: pid)
                    made.defaultIndex = tags.attribute(tag, "pindex").flatMap(tags.index).map { Int32(clamping: $0) } ?? 0
                }
                objectID = id
                made.origin = origins[id] ?? .zero
                if tag.selfClosing { model.objects[id] = made } else { object = made }
            } else if tags.name(tag, is: "basematerials") || tags.name(tag, is: "colorgroup") {
                group = tags.attribute(tag, "id").flatMap(tags.index) ?? -1
                if group >= 0, model.colors[group] == nil {
                    model.colors[group] = []
                    if tags.name(tag, is: "basematerials") { model.materials.insert(group) }
                }
                if group >= 0, let id = tags.attribute(tag, "displaypropertiesid").flatMap(tags.index) { groupDisplay[group] = id }
            } else if group >= 0, tags.name(tag, is: "base") {
                model.colors[group]?.append(tags.attribute(tag, "displaycolor").flatMap { color(tags.string($0)) } ?? SIMD4(1, 1, 1, 1))
                // The specification puts the display properties on the group; files
                // (the consortium's own samples among them) also put them on the base.
                baseDisplay[group, default: []].append(tags.attribute(tag, "displaypropertiesid").flatMap(tags.index) ?? -1)
            } else if group >= 0, tags.name(tag, is: "color") {
                model.colors[group]?.append(tags.attribute(tag, "color").flatMap { color(tags.string($0)) } ?? SIMD4(1, 1, 1, 1))
                // A colour has no display properties of its own; its group's are for it too.
                baseDisplay[group, default: []].append(-1)
            } else if tags.name(tag, is: "texture2d") {
                guard let id = tags.attribute(tag, "id").flatMap(tags.index), let path = tags.attribute(tag, "path") else { continue }
                model.images[id] = tags.string(path)
            } else if tags.name(tag, is: "texture2dgroup") {
                coordinates = -1
                guard !tag.selfClosing, let id = tags.attribute(tag, "id").flatMap(tags.index), let image = tags.attribute(tag, "texid").flatMap(tags.index) else { continue }
                coordinates = id
                if model.coordinates[id] == nil { model.coordinates[id] = TextureGroup(image: image) }
            } else if coordinates >= 0, tags.name(tag, is: "tex2coord") {
                entries += 1
                guard entries <= maxTriangles * 3 else { continue }
                // 3MF measures v from the bottom of the image, the renderer from the top.
                var from = tag.attributes.lowerBound
                let u = tags.attribute(tag, "u", from: &from).flatMap(tags.number) ?? 0, v = tags.attribute(tag, "v", from: &from).flatMap(tags.number) ?? 0
                uvs.append(SIMD2(Float(u), 1 - Float(v)))
            } else if tags.name(tag, is: "multiproperties") {
                layered = -1
                guard !tag.selfClosing, let id = tags.attribute(tag, "id").flatMap(tags.index), let groups = tags.attribute(tag, "pids") else { continue }
                layered = id
                if model.layered[id] == nil {
                    let methods = tags.attribute(tag, "blendmethods").map(tags.string) ?? ""
                    model.layered[id] = Layered(groups: Array(numbers(tags.string(groups)).prefix(16)).map { Int($0) },
                                                multiplies: methods.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).prefix(16).map { $0 == "multiply" })
                }
            } else if layered >= 0, tags.name(tag, is: "multi") {
                entries += 1
                guard entries <= maxTriangles * 3 else { continue }
                model.layered[layered]?.entries.append(Array(numbers(tags.attribute(tag, "pindices").map(tags.string) ?? "").prefix(16)))
            } else if tags.name(tag, is: "pbmetallicdisplayproperties") || tags.name(tag, is: "pbspeculardisplayproperties")
                        || tags.name(tag, is: "translucentdisplayproperties") {
                display = tag.selfClosing ? -1 : (tags.attribute(tag, "id").flatMap(tags.index) ?? -1)
                if display >= 0, displays[display] == nil { displays[display] = [] }
            } else if display >= 0, (displays[display]?.count ?? 0) < 65_536,
                      tags.name(tag, is: "pbmetallic") || tags.name(tag, is: "pbspecular") || tags.name(tag, is: "translucent") {
                func unit(_ name: StaticString) -> Float? {
                    tags.attribute(tag, name).flatMap(tags.number).flatMap { $0.isFinite ? Float(min(max($0, 0), 1)) : nil }
                }
                var surface = Surface()
                if tags.name(tag, is: "pbmetallic") {
                    surface.metallic = unit("metallicness") ?? 0
                    surface.roughness = unit("roughness") ?? 1
                } else if tags.name(tag, is: "pbspecular") {
                    // No metal value in this model; a glossy surface is a smooth one.
                    surface.roughness = 1 - (unit("glossiness") ?? 0)
                } else {
                    surface.roughness = unit("roughness") ?? 0.2
                    surface.opacity = translucentOpacity
                }
                displays[display]?.append(surface)
            } else if tags.name(tag, is: "build") {
                inBuild = !tag.selfClosing
            } else if inBuild, tags.name(tag, is: "item") {
                guard let id = tags.attribute(tag, "objectid").flatMap(tags.index), model.items.count < maxInstances else { continue }
                model.items.append(Component(object: Reference(file: target(tag), id: id), transform: transform(tags, tag)))
            }
        }
        // A group the file never closed.
        if coordinates >= 0 { model.coordinates[coordinates]?.uvs.append(contentsOf: uvs) }
        // Display properties may come after the materials that name them.
        if !displays.isEmpty {
            var known: [Surface: Int32] = [:]
            for (group, bases) in baseDisplay {
                var indices = [Int32](repeating: -1, count: bases.count)
                for (i, own) in bases.enumerated() {
                    var surface: Surface?
                    if own >= 0, let list = displays[own] {
                        surface = i < list.count ? list[i] : list.first
                    } else if let id = groupDisplay[group], let list = displays[id], i < list.count {
                        surface = list[i]
                    }
                    guard let surface else { continue }
                    if let index = known[surface] { indices[i] = index } else {
                        model.surfaces.append(surface)
                        known[surface] = Int32(model.surfaces.count - 1)
                        indices[i] = Int32(model.surfaces.count - 1)
                    }
                }
                if indices.contains(where: { $0 >= 0 }) { model.surfaceOf[group] = indices }
            }
        }
        for (id, layered) in model.layered where composes(layered, in: model) { model.composed.insert(id) }
        return model
    }

    /// Whether the layers are one colour, the same at every corner, with images over it
    /// that all lie the same way: then they can be painted into one image.
    private static func composes(_ layered: Layered, in model: ModelFile) -> Bool {
        guard let base = layered.groups.first, model.colors[base] != nil, layered.groups.count >= 2, !layered.entries.isEmpty,
              layered.groups.dropFirst().allSatisfy({ model.coordinates[$0] != nil }) else { return false }
        let colour = layered.entries[0].first ?? 0
        for entry in layered.entries {
            guard (entry.first ?? 0) == colour else { return false }
            var uv: SIMD2<Float>?
            for (layer, id) in layered.groups.enumerated().dropFirst() {
                let i = layer < entry.count ? Int(entry[layer]) : 0
                guard let uvs = model.coordinates[id]?.uvs, i >= 0, i < uvs.count else { return false }
                if let uv { guard uv == uvs[i] else { return false } } else { uv = uvs[i] }
            }
        }
        return true
    }

    /// "0 3 12" as numbers; anything that is not a whole number counts as 0.
    private static func numbers(_ text: String) -> [Int32] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map { Int32($0).map { max(0, $0) } ?? 0 }
    }

    /// Drops triangles that point outside the vertices or name a vertex twice.
    private static func finish(_ object: Object) {
        let count = object.vertices.count
        let hasProperties = !object.properties.isEmpty
        var kept = 0
        for t in 0..<(object.triangles.count / 3) {
            let a = object.triangles[t * 3], b = object.triangles[t * 3 + 1], c = object.triangles[t * 3 + 2]
            guard Int(a) < count, Int(b) < count, Int(c) < count, a != b, b != c, c != a else { continue }
            if kept != t {
                object.triangles[kept * 3] = a; object.triangles[kept * 3 + 1] = b; object.triangles[kept * 3 + 2] = c
                if hasProperties { for k in 0..<4 { object.properties[kept * 4 + k] = object.properties[t * 4 + k] } }
            }
            kept += 1
        }
        object.triangles.removeLast(object.triangles.count - kept * 3)
        if hasProperties { object.properties.removeLast(object.properties.count - kept * 4) }
    }

    /// "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32": the first three rows turn and
    /// scale, the last one moves, with points as row vectors.
    private static func transform(_ tags: XMLTags, _ tag: XMLTags.Tag) -> simd_float4x4 {
        guard let range = tags.attribute(tag, "transform") else { return matrix_identity_float4x4 }
        let values = tags.string(range).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).compactMap { Float($0) }
        guard values.count == 12, values.allSatisfy(\.isFinite) else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (SIMD4(values[0], values[1], values[2], 0), SIMD4(values[3], values[4], values[5], 0),
                                       SIMD4(values[6], values[7], values[8], 0), SIMD4(values[9], values[10], values[11], 1)))
    }

    /// "#RRGGBB" or "#RRGGBBAA", sRGB.
    static func color(_ text: String) -> SIMD4<Float>? {
        let hex = text.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#"), hex.utf8.count == 7 || hex.utf8.count == 9, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        if hex.utf8.count == 7 { return SIMD4(Float((value >> 16) & 0xff), Float((value >> 8) & 0xff), Float(value & 0xff), 255) / 255 }
        return SIMD4(Float((value >> 24) & 0xff), Float((value >> 16) & 0xff), Float((value >> 8) & 0xff), Float(value & 0xff)) / 255
    }
}
