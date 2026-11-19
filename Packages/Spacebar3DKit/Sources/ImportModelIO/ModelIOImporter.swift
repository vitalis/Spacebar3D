import Foundation
import ModelCore
import ModelIO
import simd

public enum ImportError: Error, LocalizedError, Equatable {
    case empty
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return L10n.text("The file contains no geometry.")
        case .unsupported(let what): return L10n.format("This file cannot be shown: %@.", String(describing: what))
        }
    }
}

/// Reads the formats Apple's Model I/O understands into a `ModelScene`: the USD family.
/// (STL is still readable here, for comparison with our own reader in tests.)
public enum ModelIOImporter {
    public static func load(_ url: URL, format: Format) throws -> ModelScene {
        // Model I/O hands out autoreleased objects that hold the whole file and its buffers.
        // Imports run on threads with no pool of their own, where those would never be
        // released, so they get one here.
        try autoreleasepool { try loadInPool(url, format: format) }
    }

    /// The extension Model I/O needs to see for a file of this format, from its first bytes
    /// for the USD family (a package, the binary form, or text).
    private static func neededExtension(_ url: URL, format: Format) throws -> String {
        switch format {
        case .stl: return "stl"
        case .usd:
            let head = (try? FileHandle(forReadingFrom: url))?.readData(ofLength: 8) ?? Data()
            if head.starts(with: [0x50, 0x4b]) { return "usdz" }
            if head.starts(with: Array("PXR-USDC".utf8)) { return "usdc" }
            return "usda"
        default: throw ImportError.unsupported(L10n.format("%@ is not read natively yet", String(describing: format.rawValue)))
        }
    }

    private static func loadInPool(_ url: URL, format: Format) throws -> ModelScene {
        let needed = try neededExtension(url, format: format)
        // Model I/O picks its reader from the file extension, while the format here was
        // worked out from the file's content. A file with another extension is read through
        // a link that carries the right one. (".usd" may hold either USD form and is left alone.)
        var readURL = url
        var linkFolder: URL?
        let ext = url.pathExtension.lowercased()
        if ext != needed, !(format == .usd && ext == "usd") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let link = folder.appendingPathComponent("model.\(needed)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url.resolvingSymlinksInPath())
            readURL = link
            linkFolder = folder
        }
        defer { if let linkFolder { try? FileManager.default.removeItem(at: linkFolder) } }
        if format == .usd { return try USDScene.load(readURL) }
        let asset = MDLAsset(url: readURL)
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
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            guard let part = part(from: mesh) else { continue }
            scene.meshes.append(ModelScene.Mesh(name: mesh.name, parts: [part]))
            // STL is Z-up (3D printing and CAD); the renderer's convention is Y up.
            let zUpToYUp = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))
            scene.nodes.append(ModelScene.Node(name: mesh.name, transform: zUpToYUp, mesh: scene.meshes.count - 1))
            // STL stores every triangle with its own three corners; count them as the file does.
            let triangles = part.triangleIndices.count / 3
            scene.topology.faces += triangles
            scene.topology.triangles += triangles
            scene.topology.vertices += triangles * 3
        }
        guard scene.topology.faces > 0 else { throw ImportError.empty }
        return scene
    }

    private static func part(from mesh: MDLMesh) -> ModelScene.MeshPart? {
        guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return nil }
        var part = ModelScene.MeshPart()
        part.material = 0
        let count = mesh.vertexCount
        part.positions.reserveCapacity(count)
        for i in 0..<count {
            let p = positions.dataStart.advanced(by: i * positions.stride).loadUnaligned(as: (Float, Float, Float).self)
            part.positions.append(SIMD3(p.0, p.1, p.2))
        }
        if let normals = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) {
            part.normals.reserveCapacity(count)
            for i in 0..<count {
                let n = normals.dataStart.advanced(by: i * normals.stride).loadUnaligned(as: (Float, Float, Float).self)
                part.normals.append(SIMD3(n.0, n.1, n.2))
            }
        }
        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
            let buffer = submesh.indexBuffer(asIndexType: .uint32)
            let map = buffer.map()
            let indices = UnsafeRawBufferPointer(start: map.bytes, count: submesh.indexCount * 4).bindMemory(to: UInt32.self)
            part.triangleIndices.append(contentsOf: indices)
        }
        if part.triangleIndices.isEmpty { return nil }
        guard part.triangleIndices.allSatisfy({ Int($0) < count }) else { return nil }
        return part
    }
}
