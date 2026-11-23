/// The kind of model file, as far as choosing a reader goes.
///
/// `gltf` is the binary container (GLB, which VRM and VRMA also use); `gltfJSON` is the
/// text form. Telling VRM and VRMA apart from plain glTF needs the JSON inside and is done
/// by the glTF reader, not here.
public enum Format: String, CaseIterable, Sendable {
    case blend
    case stl
    case usd
    case threeMF = "3mf"
    case ply
    case dae
    case threeDS = "3ds"
    case gltfJSON = "gltf-json"
    case obj
    case fbx
    case gltf
}
