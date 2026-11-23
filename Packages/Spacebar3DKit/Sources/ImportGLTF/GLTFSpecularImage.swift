import CoreGraphics
import Foundation
import ImageIO
import ModelCore
import simd

/// What a specular-glossiness surface with a diffuse image becomes: the Khronos conversion
/// (`Document.metalAndBase`) is worked out for each texel, since the image's colour is the
/// diffuse that `c_diff = diffuse * (1 - max(specular))` and the metal share are taken from.
enum SpecularImage {
    /// The whole image has one colour: fold it into the factors, no image needed.
    case uniform(metallic: Float, base: SIMD3<Float>, alpha: Float)
    /// A base-colour image (sRGB, straight alpha) and, when the metal share varies, its map.
    case varying(base: [UInt8], metal: [UInt8]?, metallic: Float, width: Int, height: Int)

    /// More pixels than this are left to the old conversion (the image would be decoded and
    /// written again in memory: 16 million pixels is 64 MB each way).
    static let largest = 16_000_000

    /// The image as straight RGBA8, or nil when it cannot be read or is too large.
    static func decode(_ ref: ModelScene.TextureRef) -> (width: Int, height: Int, rgba: [UInt8])? {
        switch ref {
        case .pixels(let width, let height, let rgba):
            return width * height <= largest && rgba.count == width * height * 4 ? (width, height, rgba) : nil
        case .embedded(let bytes, _):
            guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w * h <= largest,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            // Back to straight alpha: the conversion is of the colour, not of what it was multiplied by.
            var i = 0
            while i < rgba.count {
                let a = Int(rgba[i + 3])
                if a > 0 && a < 255 { for k in 0..<3 { rgba[i + k] = UInt8(min(255, (Int(rgba[i + k]) * 255 + a / 2) / a)) } }
                i += 4
            }
            return (w, h, rgba)
        default:
            return nil
        }
    }

    /// `diffuse` is the file's linear diffuse factor; `specular` its linear specular factor.
    static func convert(_ image: (width: Int, height: Int, rgba: [UInt8]), diffuse: SIMD3<Float>, specular: SIMD3<Float>) -> SpecularImage {
        let decode = (0..<256).map { v -> Float in let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let count = image.width * image.height
        var base = [UInt8](repeating: 255, count: count * 4)
        var metal = [UInt8](repeating: 255, count: count * 4)
        var lastKey: UInt32?, last: (metallic: Float, base: SIMD3<Float>) = (0, .zero)
        var low: Float = 1, high: Float = 0
        var same = true
        image.rgba.withUnsafeBufferPointer { px in
            for i in 0..<count {
                let o = i * 4
                let key = UInt32(px[o]) << 16 | UInt32(px[o + 1]) << 8 | UInt32(px[o + 2])
                if key != lastKey {
                    let d = SIMD3(decode[Int(px[o])], decode[Int(px[o + 1])], decode[Int(px[o + 2])]) * diffuse
                    last = Document.metalAndBase(diffuse: d, specular: specular)
                    lastKey = key
                }
                low = min(low, last.metallic); high = max(high, last.metallic)
                base[o] = UInt8((Document.toSRGB(last.base.x) * 255).rounded())
                base[o + 1] = UInt8((Document.toSRGB(last.base.y) * 255).rounded())
                base[o + 2] = UInt8((Document.toSRGB(last.base.z) * 255).rounded())
                base[o + 3] = px[o + 3]
                metal[o + 2] = UInt8((last.metallic * 255).rounded())
                if same, o > 0, (px[o] != px[0] || px[o + 1] != px[1] || px[o + 2] != px[2] || px[o + 3] != px[3]) { same = false }
            }
        }
        if same {
            return .uniform(metallic: last.metallic, base: last.base, alpha: Float(image.rgba[3]) / 255)
        }
        // A metal share that hardly varies is one number; otherwise it needs its own map.
        let flat = high - low < 1.0 / 255
        return .varying(base: base, metal: flat ? nil : metal, metallic: flat ? (low + high) / 2 : 1, width: image.width, height: image.height)
    }
}
