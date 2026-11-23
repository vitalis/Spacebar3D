import Foundation
import CoreGraphics
import ImageIO
import ModelCore
import ImportGLTF
@testable import RenderMetal
import simd
import XCTest

private struct MaterialPack {
    var bytes = Data(), views: [[String:Any]] = [], accessors: [[String:Any]] = []
    mutating func floats(_ values: [Float], _ type: String) -> Int {
        let chunk = values.withUnsafeBufferPointer { Data(buffer: $0) }
        views.append(["buffer":0,"byteOffset":bytes.count,"byteLength":chunk.count]); bytes += chunk
        accessors.append(["bufferView":views.count-1,"componentType":5126,"count":values.count / ["SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4][type]!,"type":type])
        let width = ["SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4][type]!
        accessors[accessors.count-1]["min"] = (0..<width).map { c in stride(from:c,to:values.count,by:width).map { values[$0] }.min()! }
        accessors[accessors.count-1]["max"] = (0..<width).map { c in stride(from:c,to:values.count,by:width).map { values[$0] }.max()! }
        return accessors.count-1
    }
    func json(_ body: [String:Any]) throws -> Data {
        var root = body; root["asset"] = ["version":"2.0"]
        root["accessors"] = accessors; root["bufferViews"] = views
        root["buffers"] = [["byteLength":bytes.count,"uri":"data:application/octet-stream;base64,"+bytes.base64EncodedString()]]
        return try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys])
    }
}
private func materialPNG(_ rgba: [UInt8], width: Int = 1) -> Data {
    let image = CGImage(width:width,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:Data(rgba) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    return materialPNG(image)
}
private func materialPNG(_ image: CGImage) -> Data {
    let data = NSMutableData(); let dest = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(dest,image,nil); precondition(CGImageDestinationFinalize(dest)); return data as Data
}
private func materialModel(material: [String:Any], pixels: [UInt8], uv: [Float], sampler: [String:Any] = [:], baseImage: Bool = false) throws -> ModelScene {
    var p=MaterialPack()
    let position=p.floats([-1,-1,0, 1,-1,0, 1,1,0, -1,-1,0, 1,1,0, -1,1,0],"VEC3")
    let normal=p.floats(Array(repeating:[Float](arrayLiteral:0,0,1),count:6).flatMap{$0},"VEC3")
    let uSign: Float = uv[2] >= uv[0] ? 1 : -1
    let vSign: Float = uv[5] >= uv[1] ? 1 : -1
    let tangent=p.floats(Array(repeating:[Float](arrayLiteral:uSign,0,0,uSign*vSign),count:6).flatMap{$0},"VEC4")
    let coord=p.floats(uv,"VEC2")
    var textures = [["source":0,"sampler":0]]
    var samplers = [sampler]
    var images = [["uri":"data:image/png;base64,"+materialPNG(pixels,width:pixels.count/4).base64EncodedString()]]
    if baseImage {
        textures.append(["source":1,"sampler":1]); samplers.append(["wrapS":10497,"wrapT":10497,"magFilter":9728])
        images.append(["uri":"data:image/png;base64,"+materialPNG([255,255,255,255]).base64EncodedString()])
    }
    let data=try p.json(["nodes":[["mesh":0]],"meshes":[["primitives":[["attributes":["POSITION":position,"NORMAL":normal,"TANGENT":tangent,"TEXCOORD_0":coord],"material":0]]]],"materials":[material],"textures":textures,"samplers":samplers,"images":images])
    return try GLTFReader.scene(from:data)
}

final class MaterialRegressionTests: XCTestCase {
    private let normalMaterial: [String:Any] = ["pbrMetallicRoughness":["baseColorFactor":[1,1,1,1],"metallicFactor":0,"roughnessFactor":1],"normalTexture":["index":0]]
    private let upUV: [Float] = [0,0,1,0,1,1,0,0,1,1,0,1]
    private func renderer() throws -> MetalRenderer {
        let r = try MetalRenderer(); r.showGrid = false; r.showShadow = false; r.backgroundAlpha = 0
        r.look = RenderLook(view: .textured)
        return r
    }
    private func pixel(_ scene: ModelScene, _ renderer: MetalRenderer) throws -> [Int] {
        renderer.show(try renderer.makeScene(scene))
        let p = try renderer.renderOffscreen(width: 96, height: 96).pixel(48,48)
        return [Int(p.r),Int(p.g),Int(p.b),Int(p.a)]
    }
    private func equal(_ actual: [Int], _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        for (a,e) in zip(actual,expected) { XCTAssertEqual(a,e,accuracy: 2,file: file,line: line) }
    }
    func testEncodedDataMapIgnoresAlpha() throws {
        let r = try renderer()
        let opaque = try materialModel(material: normalMaterial, pixels: [128,204,230,255], uv: upUV)
        let expected = try pixel(opaque,r)
        for alpha: UInt8 in [0,128,255] {
            let png = materialPNG([128,204,230,alpha,128,204,230,alpha],width: 2)
            for limit in [1,4096] {
                let p = try XCTUnwrap(TextureUpload.pixels(of: .embedded(bytes: Array(png),mime:"image/png"),colour:false,maxSide:limit))
                XCTAssertEqual(Array(UnsafeBufferPointer(start:p.rgba.bytes,count:3)),[128,204,230])
            }
            equal(try pixel(materialModel(material:normalMaterial,pixels:[128,204,230,alpha],uv:upUV),r),expected)
        }
    }
    func testNormalMapDirectionsMatchExplicitNormals() throws {
        let r = try renderer()
        for mirrorU: Float in [1,-1] { for mirrorV: Float in [1,-1] {
            let uv = upUV.enumerated().map { $0.element * ($0.offset % 2 == 0 ? mirrorU : mirrorV) }
            for rgb: [UInt8] in [[204,128,230],[128,204,230],[64,160,230]] {
                let scene = try materialModel(material:normalMaterial,pixels:rgb+[255],uv:uv)
                var reference = scene
                reference.materials[0].normalTexture = nil
                let n = simd_normalize(SIMD3<Float>((Float(rgb[0])/255*2-1)*mirrorU,(Float(rgb[1])/255*2-1)*mirrorV,Float(rgb[2])/255*2-1))
                reference.meshes[0].parts[0].normals = Array(repeating:n,count:6)
                equal(try pixel(scene,r),try pixel(reference,r))
            }
        } }
    }
    func testNormalMapStrengthDoesNotDependOnUVScale() throws {
        let r = try renderer()
        for width: Float in [1,3] { for u: Float in [0.1,1,10] { for v: Float in [0.2,1,5] {
            let uv = upUV.enumerated().map { $0.element * ($0.offset % 2 == 0 ? u : v) }
            var scene = try materialModel(material:normalMaterial,pixels:[160,204,230,255],uv:uv)
            scene.meshes[0].parts[0].positions = scene.meshes[0].parts[0].positions.map { $0 * SIMD3(width,1,1) }
            var reference = scene; reference.materials[0].normalTexture = nil
            let n = simd_normalize(SIMD3<Float>(160.0/255*2-1,204.0/255*2-1,230.0/255*2-1))
            reference.meshes[0].parts[0].normals = Array(repeating:n,count:6)
            equal(try pixel(scene,r),try pixel(reference,r))
        } } }
    }

    /// A back face lit through a normal map must match the face with the reversed explicit normal. Under the
    /// rule that `normalYSign` applies only to frames the renderer works out itself (the flat, per-pixel
    /// path and generated tangents), green runs along sign x increasing stored v there, so the sign flips
    /// green; a frame from file tangents carries green in its handedness (w = +1 here, green toward
    /// cross(n, t)) and ignores the sign, so the picture must not change with it. Reference: Blender 5.2
    /// and the glTF specification, see `GLTFNormalMapGreenTests`.
    func testBackFaceNormalMapMatchesReversedExplicitNormal() throws {
        let r = try renderer()
        for sign: Float in [-1,1] {
            var scene = try materialModel(material:normalMaterial,pixels:[204,160,230,255],uv:upUV)
            scene.materials[0].doubleSided = true; scene.materials[0].oneSided = false
            scene.materials[0].normalYSign = sign
            scene.nodes[0].transform = simd_float4x4(simd_quatf(angle:.pi,axis:SIMD3(0,1,0)))
            for flat in [false,true] {
                // File tangents (w = +1) always give green +; the per-pixel path follows the sign.
                let green = flat ? sign : 1
                var reference = scene
                reference.materials[0].normalTexture = nil
                let n = simd_normalize(SIMD3<Float>(204.0/255*2-1,(160.0/255*2-1)*green,230.0/255*2-1))
                reference.meshes[0].parts[0].normals = Array(repeating:n,count:6)
                // The reference has explicit normals, which flat shading would ignore: draw it smooth.
                r.look.flat = false
                let expected = try pixel(reference,r)
                r.look.flat = flat
                equal(try pixel(scene,r),expected)
            }
        }
    }

    func testGrayDataImagesIgnoreAlphaAndPremultipliedRGBRecovers() throws {
        for alpha: UInt8 in [0,128,255] {
            let data = Data([180,alpha,180,alpha])
            let image = try XCTUnwrap(CGImage(width:2,height:1,bitsPerComponent:8,bitsPerPixel:16,bytesPerRow:4,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
            let png = materialPNG(image)
            for limit in [1,4096] {
                let pixels = try XCTUnwrap(TextureUpload.pixels(of:.embedded(bytes:Array(png),mime:"image/png"),colour:false,maxSide:limit))
                for i in 0..<3 { XCTAssertEqual(Int(pixels.rgba.bytes[i]),180,accuracy:1) }
            }
        }
        let data = Data([64,102,115,128])
        let image = try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let pixels = try XCTUnwrap(TextureUpload.pixels(of:image,colour:false,maxSide:4096))
        for (i,value) in [128,203,229].enumerated() { XCTAssertEqual(Int(pixels.rgba.bytes[i]),value,accuracy:1) }
    }

    func testMapSamplersRemainIndependentOfBaseColor() throws {
        let uv = upUV.enumerated().map { $0.offset % 2 == 0 ? 1.1 + $0.element * 0.3 : $0.element }
        let clamp: [String:Any] = ["wrapS":33071,"wrapT":33071,"magFilter":9728]
        let r = try renderer()
        for slot in ["emissiveTexture","normalTexture","metallicRoughnessTexture"] {
            for baseImage in [false,true] {
                var pbr: [String:Any] = ["baseColorFactor":slot == "emissiveTexture" ? [0,0,0,1] : [1,1,1,1],"metallicFactor":slot == "metallicRoughnessTexture" ? 1 : 0,"roughnessFactor":1]
                if baseImage { pbr["baseColorTexture"] = ["index":1] }
                var material: [String:Any] = [:]
                if slot == "metallicRoughnessTexture" { pbr[slot] = ["index":0] }
                else { material[slot] = ["index":0] }
                if slot == "emissiveTexture" { material["emissiveFactor"] = [1,1,1] }
                material["pbrMetallicRoughness"] = pbr
                let left: [UInt8] = slot == "normalTexture" ? [204,128,230,255] : [255,50,255,255]
                let right: [UInt8] = slot == "normalTexture" ? [64,128,230,255] : [0,240,0,255]
                let scene = try materialModel(material:material,pixels:left+right,uv:uv,sampler:clamp,baseImage:baseImage)
                let reference = try materialModel(material:material,pixels:right+right,uv:uv,sampler:clamp,baseImage:baseImage)
                if baseImage { XCTAssertEqual(scene.materials[0].sampling.wrapS,.repeat) }
                for flat in [false,true] {
                    r.look.flat = flat
                    equal(try pixel(scene,r),try pixel(reference,r))
                }
            }
        }
    }

    func testSoleEmissiveTextureUsesItsSampler() throws {
        let material: [String:Any] = ["pbrMetallicRoughness":["baseColorFactor":[0,0,0,1],"metallicFactor":0,"roughnessFactor":1],"emissiveFactor":[1,1,1],"emissiveTexture":["index":0]]
        let uv = Array(repeating:[Float](arrayLiteral:1.25,0.5),count:6).flatMap{$0}
        let sampler: [String:Any] = ["wrapS":33071,"wrapT":33071,"magFilter":9728]
        let scene = try materialModel(material:material,pixels:[255,0,0,255,0,255,0,255],uv:uv,sampler:sampler)
        let reference = try materialModel(material:material,pixels:[0,255,0,255,0,255,0,255],uv:uv,sampler:sampler)
        let r = try renderer()
        equal(try pixel(scene,r),try pixel(reference,r))
    }
}
