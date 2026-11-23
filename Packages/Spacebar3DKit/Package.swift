// swift-tools-version: 6.0
import PackageDescription

// The native side of Spacebar3D, shared by the app and the Quick Look extension.
// See docs/architecture/native-rewrite.md, section 2.2, for the planned modules.
let package = Package(
    name: "Spacebar3DKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ModelCore", targets: ["ModelCore"]),
        .library(name: "ViewerUI", targets: ["ViewerUI"]),
        .library(name: "RenderMetal", targets: ["RenderMetal"]),
    ],
    dependencies: [
        // Tests only: reads SwiftUI views in the test process, so the controls are
        // exercised without driving the screen.
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
    ],
    targets: [
        // Pure Swift, no GPU and no AppKit: formats, scene types, statistics.
        .target(name: "ModelCore", resources: [.process("Resources")]),
        // Model I/O → ModelScene (STL so far; PLY, OBJ and USD follow).
        .target(name: "ImportModelIO", dependencies: ["ModelCore"]),
        // Format → importer; the only module that knows all importers.
        // STL read straight from the file's bytes.
        .target(name: "ImportSTL", dependencies: ["ModelCore"]),
        // PLY and OBJ likewise.
        .target(name: "ImportPLY", dependencies: ["ModelCore"]),
        .target(name: "ImportOBJ", dependencies: ["ModelCore"]),
        // Assimp (C++), built by scripts/build-assimp.sh; its C interface is all we call.
        .binaryTarget(name: "Assimp", path: "Vendor/Assimp.xcframework"),
        // Assimp → ModelScene (3DS; FBX follows).
        .target(name: "ImportAssimp", dependencies: ["ModelCore", "Assimp"],
                linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z")]),
        // 3MF: a zip of XML, read here because Assimp's reader does not assemble objects
        // kept in separate model files.
        .target(name: "ImportThreeMF", dependencies: ["ModelCore"]),
        // glTF 2.0 and GLB, read by our own code (which VRM builds on).
        .target(name: "ImportGLTF", dependencies: ["ModelCore"]),
        // Zstandard's reference decoder (the decoding half of the library only), as its
        // authors publish it: Blender saves compressed files with it.
        .target(name: "CZstd", exclude: ["LICENSE"],
                cSettings: [.define("ZSTD_DISABLE_ASM"), .define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("ZSTD_STRIP_ERROR_STRINGS"), .define("DEBUGLEVEL", to: "0")]),
        // Blender files, read by our own code.
        .target(name: "ImportBlend", dependencies: ["ModelCore", "CZstd"]),
        .target(name: "ImportRouter", dependencies: ["ModelCore", "ImportModelIO", "ImportSTL", "ImportPLY", "ImportOBJ", "ImportAssimp", "ImportThreeMF", "ImportGLTF", "ImportBlend"]),
        // What the hosts talk to: the viewer interface and the choice of renderer.
        .target(
            name: "ViewerUI", dependencies: ["ModelCore", "RenderMetal", "ImportRouter"],
            // The app's mark, shown while a file is read.
            resources: [.process("Resources")]),
        // GPU scene, camera, passes and shaders (Metal). Depends on ModelCore only.
        .target(name: "RenderMetal", dependencies: ["ModelCore"]),
        .testTarget(name: "ModelCoreTests", dependencies: ["ModelCore"]),
        .testTarget(name: "ImportModelIOTests", dependencies: ["ImportModelIO", "ImportSTL", "ImportRouter", "RenderMetal"]),
        .testTarget(name: "ImportAssimpTests", dependencies: ["ImportAssimp", "ImportRouter", "ModelCore", "RenderMetal"]),
        .testTarget(name: "ImportThreeMFTests", dependencies: ["ImportThreeMF", "ImportRouter", "ModelCore", "RenderMetal"]),
        .testTarget(name: "ImportTextTests", dependencies: ["ImportPLY", "ImportOBJ", "ImportRouter", "ModelCore"]),
        .testTarget(name: "ImportGLTFTests", dependencies: ["ImportGLTF", "ImportRouter", "ModelCore", "RenderMetal"]),
        .testTarget(name: "ImportBlendTests", dependencies: ["ImportBlend", "ImportRouter", "ModelCore", "RenderMetal"]),
        .testTarget(name: "ViewerUITests", dependencies: ["ViewerUI", .product(name: "ViewInspector", package: "ViewInspector")]),
        .testTarget(name: "RenderMetalTests", dependencies: ["RenderMetal", "ImportRouter", "ImportSTL", "ImportPLY", "ImportOBJ", "ModelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
