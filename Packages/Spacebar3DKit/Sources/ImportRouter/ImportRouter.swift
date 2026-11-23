import Foundation
import ImportAssimp
import ImportBlend
import ImportGLTF
import ImportModelIO
import ImportOBJ
import ImportPLY
import ImportSTL
import ImportThreeMF
import ModelCore

/// Sends a file to the importer for its format. The only module that knows every importer.
public enum ImportRouter {
    /// Formats some importer here can read.
    public static let importable: Set<Format> = [.stl, .ply, .obj, .usd, .threeMF, .threeDS, .fbx, .gltf, .gltfJSON, .blend]

    public static func load(_ url: URL, format: Format) throws -> ModelScene {
        try read(url, format: format).movedNearTheOrigin()
    }

    private static func read(_ url: URL, format: Format) throws -> ModelScene {
        switch format {
        case .stl: return try STLReader.load(url)
        case .ply: return try PLYReader.load(url)
        case .obj: return try OBJReader.load(url)
        case .usd: return try ModelIOImporter.load(url, format: .usd)
        case .threeMF: return try ThreeMFReader.load(url)
        case .threeDS, .fbx: return try AssimpImporter.load(url, format: format)
        case .gltf, .gltfJSON: return try GLTFReader.load(url)
        case .blend: return try BlendReader.load(url)
        case .dae: throw ImportError.unsupported(L10n.text("COLLADA files are not supported"))
        }
    }
}
