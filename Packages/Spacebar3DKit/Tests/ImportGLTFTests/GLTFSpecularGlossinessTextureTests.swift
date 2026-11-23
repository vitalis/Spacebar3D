import CoreGraphics
import Foundation
import ImageIO
import ModelCore
import simd
import UniformTypeIdentifiers
import XCTest
@testable import ImportGLTF

/// `KHR_materials_pbrSpecularGlossiness` with a diffuse image. The extension's README
/// (KhronosGroup/glTF, extensions/2.0/Archived/KHR_materials_pbrSpecularGlossiness) says: the
/// factors scale the textures in linear space; `specularFactor` defaults to [1,1,1];
/// "c_diff = diffuse.rgb * (1 - max(specular.r, specular.g, specular.b))" and
/// "F0 = specular". So a specular of 1 leaves no diffuse at all: a white mirror on which the
/// diffuse image does not show. The importer converts from the factors only (`metalAndBase`),
/// then multiplies the image over the resulting base colour, so the image tints a metal.
/// (The Khronos glTF-Sample-Viewer shaders could not be fetched here: the Sample-Viewer
/// raw URLs returned 404, and the current Sample-Renderer has no spec-gloss path. The claim
/// rests on the README text above, quoted from the downloaded file.)
///
/// Each test uses an image of one uniform colour, so converting per texel and converting
/// the factors with that colour as the diffuse factor must agree: effective base colour
/// (factor times texel, in linear light) and metallic equal `metalAndBase`'s.
final class GLTFSpecularGlossinessTextureTests: XCTestCase {
    private let texel: [UInt8] = [200, 120, 60]

    private func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    private func png(_ rgb: [UInt8]) throws -> Data {
        var pixels = [UInt8]()
        for _ in 0..<16 { pixels += rgb + [255] }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: space,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func floats(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

    /// Serves the diffuse image as a file beside the glTF.
    private struct Beside: SidecarSource {
        let image: Data
        func data(named name: String) -> Data? { name == "diffuse.png" ? image : nil }
    }

    /// With `sidecar`, the diffuse image is a separate file ("diffuse.png") read through a `SidecarSource`.
    private func material(_ body: String, sidecar: Bool = false) throws -> ModelScene {
        var buffer = floats([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])
        for i: UInt16 in [0, 1, 2, 0, 2, 3] { buffer.append(contentsOf: withUnsafeBytes(of: i.littleEndian) { Array($0) }) }
        let image = try png(texel).base64EncodedString()
        let json = """
        {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
         "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "material": 0}]}],
         "materials": [{"extensions": {"KHR_materials_pbrSpecularGlossiness": {\(body)}}}],
         "textures": [{"source": 0}], "images": [{"uri": "\(sidecar ? "diffuse.png" : "data:image/png;base64," + image)"}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"},
                       {"bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR"}],
         "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48}, {"buffer": 0, "byteOffset": 48, "byteLength": 12}],
         "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": 60}]}
        """
        return try GLTFReader.scene(from: Data(json.utf8), sidecars: sidecar ? Beside(image: try png(texel)) : nil)
    }

    /// Imports the image-carrying material and checks it against the factor-only conversion.
    private func check(specular: [Float]?, sidecar: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let spec = specular.map { ", \"specularFactor\": [\($0[0]), \($0[1]), \($0[2])]" } ?? ""
        let scene = try material("\"diffuseTexture\": {\"index\": 0}, \"glossinessFactor\": 0.5" + spec, sidecar: sidecar)
        let read = try XCTUnwrap(scene.materials.first, file: file, line: line)
        if sidecar { XCTAssertEqual(scene.diagnostics.missingResources, [], "the sidecar image was not found", file: file, line: line) }
        let texelLinear = SIMD3(texel.map { linear(Float($0) / 255) })
        let s = specular ?? [1, 1, 1]
        let expected = Document.metalAndBase(diffuse: texelLinear, specular: SIMD3(s[0], s[1], s[2]))
        let factor = SIMD3(linear(read.baseColor.x), linear(read.baseColor.y), linear(read.baseColor.z))
        let effective = read.baseColorTexture == nil ? factor : factor * texelLinear
        let message = "metallic \(read.metallic) (want \(expected.metallic)), effective base \(effective) (want \(expected.base)), texture \(String(describing: read.baseColorTexture))"
        XCTAssertEqual(read.metallic, expected.metallic, accuracy: 2e-3, message, file: file, line: line)
        XCTAssertLessThan(simd_distance(effective, expected.base), 3e-3, message, file: file, line: line)
    }

    /// A glTF with a diffuse image and no `specularFactor` shows as a metal tinted by the
    /// image (the default specular of 1 makes it a metal with a white base, which the image
    /// then multiplies), where Khronos's model gives a white mirror with no diffuse left.
    /// Measured on 0df3825 (texel sRGB 200,120,60 = linear 0.578, 0.188, 0.045): metallic 1,
    /// effective base (0.578, 0.188, 0.045), wanted (1, 1, 1).
    func testADiffuseImageOnASurfaceWithDefaultSpecularIsAMirrorNotATintedMetal() throws {
        try check(specular: nil)
    }

    /// A plain non-metal (specular 0.04 grey) with a diffuse image is shown in the image's
    /// colours with no metal. This is the case the importer already gets right and must keep.
    func testADiffuseImageOnAPlainNonMetalKeepsItsColourAndIsNotMetal() throws {
        try check(specular: [0.04, 0.04, 0.04])
    }

    /// A coloured specular with a diffuse image: the metal share and the base colour follow
    /// the image's colour, not a white diffuse that the image later tints.
    func testADiffuseImageUnderAColouredSpecularIsConvertedFromTheImagesColour() throws {
        try check(specular: [0.6, 0.3, 0.1])
    }

    // MARK: the diffuse image is a file beside the .gltf

    /// The same three cases with the image stored beside the glTF (read through a `SidecarSource`),
    /// not embedded. The importer converts only embedded or already-decoded images per texel, so
    /// the user sees a tinted metal here and a white mirror for the same material embedded.

    func testASidecarDiffuseImageOnASurfaceWithDefaultSpecularIsAMirrorNotATintedMetal() throws {
        try check(specular: nil, sidecar: true)
    }

    /// Guard: a plain non-metal with a sidecar diffuse image keeps its colours and is no metal.
    func testASidecarDiffuseImageOnAPlainNonMetalKeepsItsColourAndIsNotMetal() throws {
        try check(specular: [0.04, 0.04, 0.04], sidecar: true)
    }

    func testASidecarDiffuseImageUnderAColouredSpecularIsConvertedFromTheImagesColour() throws {
        try check(specular: [0.6, 0.3, 0.1], sidecar: true)
    }
}
