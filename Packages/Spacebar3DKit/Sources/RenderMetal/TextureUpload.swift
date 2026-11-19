import CoreGraphics
import Foundation
import ImageIO
import Metal
import ModelCore

/// Turns a model's image into a GPU texture with its smaller versions (mipmaps).
public enum TextureUpload {
    /// Images larger than this on a side are scaled down to it: 4096 x 4096 is 85 MB on the
    /// GPU with its mipmaps, and a preview does not show more detail than that.
    public static let maxSide = 4096

    /// Memory for decoded pixels, taken straight from the system and given straight back
    /// when it is let go. A decoded image is tens of megabytes held for a moment; from the
    /// ordinary allocator such blocks linger after they are freed and pile up, image after
    /// image, into the highest memory use of the whole load.
    final class Buffer {
        let bytes: UnsafeMutablePointer<UInt8>
        let count: Int

        /// Zero-filled.
        init?(count: Int) {
            guard count > 0, let memory = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), memory != MAP_FAILED else { return nil }
            bytes = memory.assumingMemoryBound(to: UInt8.self)
            self.count = count
        }

        deinit { munmap(bytes, count) }
    }

    /// Colour RGB encodes linear-light premultiplied values as sRGB; alpha is linear.
    /// Data-map channels are unchanged. Top row first.
    struct Pixels { var width: Int; var height: Int; var rgba: Buffer }

    /// Nil when the image is missing, cannot be decoded, or is empty; the part is then
    /// drawn with its material colour.
    /// `srgb` is true for colours and false for data (normal maps, metallic and roughness).
    static func make(_ texture: ModelScene.TextureRef, device: MTLDevice, srgb: Bool = true, maxSide: Int = TextureUpload.maxSide, ignoresAlpha: Bool = false) -> MTLTexture? {
        // Data maps keep their channel values. Colour pixels need premultiplied alpha.
        if case .pixels(let width, let height, let rgba) = texture, !srgb, width > 0, height > 0, rgba.count >= width * height * 4, max(width, height) <= maxSide {
            return rgba.withUnsafeBytes { upload($0.baseAddress!, width: width, height: height, device: device, srgb: srgb) }
        }
        // Uploads run on threads with no autorelease pool of their own; the decoder's
        // temporary objects would otherwise stay until the thread ends.
        return autoreleasepool {
            guard let pixels = pixels(of: texture, colour: srgb, maxSide: maxSide, ignoresAlpha: ignoresAlpha) else { return nil }
            return upload(pixels.rgba.bytes, width: pixels.width, height: pixels.height, device: device, srgb: srgb)
        }
    }

    static func make(_ image: CGImage, device: MTLDevice, srgb: Bool = true, maxSide: Int = TextureUpload.maxSide, ignoresAlpha: Bool = false) -> MTLTexture? {
        guard let pixels = pixels(of: image, colour: srgb, maxSide: maxSide, ignoresAlpha: ignoresAlpha) else { return nil }
        return upload(pixels.rgba.bytes, width: pixels.width, height: pixels.height, device: device, srgb: srgb)
    }

    /// An image as pixels no larger than `maxSide`. Colours are brought to sRGB. Data
    /// (normal maps, metallic, roughness) keeps the numbers stored in the file, whatever
    /// colour profile the file claims.
    static func pixels(of image: CGImage, colour: Bool, maxSide: Int, ignoresAlpha: Bool = false) -> Pixels? {
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if (colour && ignoresAlpha) || (!colour && hasAlpha) {
            guard let opaque = opaqueImage(image, maxSide: maxSide, colour: colour) else { return nil }
            return pixels(of: opaque, colour: colour, maxSide: maxSide)
        }
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let rgba = Buffer(count: width * height * 4) else { return nil }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        if !colour, image.colorSpace?.model == .monochrome, let space = image.colorSpace {
            // Drawn in the image's own grey space, so nothing is converted, then spread to three channels.
            guard let grey = Buffer(count: width * height),
                  let context = CGContext(data: grey.bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for i in 0..<(width * height) {
                let v = grey.bytes[i]
                rgba.bytes[i * 4] = v; rgba.bytes[i * 4 + 1] = v; rgba.bytes[i * 4 + 2] = v; rgba.bytes[i * 4 + 3] = 255
            }
            return Pixels(width: width, height: height, rgba: rgba)
        }
        // Data in an RGB image: drawn in the image's own space for the same reason.
        let resizing = width != image.width || height != image.height
        // Resample in linear light with premultiplied alpha. At native size use sRGB
        // decoding to preserve the source's dark 8-bit colors before conversion below.
        let space = colour ? (resizing ? CGColorSpace(name: CGColorSpace.linearSRGB)! : sRGB) : (image.colorSpace?.model == .rgb ? image.colorSpace! : sRGB)
        guard let context = CGContext(data: rgba.bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: (colour ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if colour {
            if resizing {
                // The context already multiplied linear RGB by alpha; only encode it.
                for i in stride(from: 0, to: rgba.count, by: 4) {
                    for c in 0..<3 { rgba.bytes[i + c] = fromLinear[(Int(rgba.bytes[i + c]) * 4095 + 127) / 255] }
                }
            } else { premultiplyLinear(rgba, alreadyPremultiplied: true) }
        }
        return Pixels(width: width, height: height, rgba: rgba)
    }

    /// A model's image as pixels (see `pixels(of:colour:maxSide:)`).
    static func pixels(of texture: ModelScene.TextureRef, colour: Bool, maxSide: Int, ignoresAlpha: Bool = false) -> Pixels? {
        switch texture {
        case .pixels(let width, let height, let rgba):
            guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
            if max(width, height) <= maxSide {
                guard let copy = Buffer(count: width * height * 4) else { return nil }
                rgba.withUnsafeBytes { copy.bytes.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: width * height * 4) }
                if colour {
                    if ignoresAlpha { for i in stride(from: 3, to: copy.count, by: 4) { copy.bytes[i] = 255 } }
                    premultiplyLinear(copy, alreadyPremultiplied: false)
                }
                return Pixels(width: width, height: height, rgba: copy)
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: (colour && !ignoresAlpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast).rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return pixels(of: image, colour: colour, maxSide: maxSide, ignoresAlpha: ignoresAlpha)
        case .embedded(let bytes, _):
            // The decoder reads the compressed bytes where they are and is told not to keep
            // what it decodes: the pixels are wanted once, in the buffer drawn into.
            return bytes.withUnsafeBytes { raw -> Pixels? in
                guard let base = raw.baseAddress,
                      let data = CFDataCreateWithBytesNoCopy(nil, base.assumingMemoryBound(to: UInt8.self), raw.count, kCFAllocatorNull),
                      let image = decode(data, maxSide: maxSide, allowsSubsampling: colour && !ignoresAlpha) else { return nil }
                return pixels(of: image, colour: colour, maxSide: maxSide, ignoresAlpha: ignoresAlpha)
            }
        case .sidecar, .missing:
            return nil
        }
    }

    /// Drop straight alpha before decoding/resizing can erase invisible RGB. ImageIO
    /// exposes PNG samples with straight alpha, including their color at alpha zero.
    private static func opaqueImage(_ image: CGImage, maxSide: Int, colour: Bool = true) -> CGImage? {
        let alpha: CGImageAlphaInfo
        switch image.alphaInfo {
        case .last: alpha = .noneSkipLast
        case .first: alpha = .noneSkipFirst
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default:
            // A caller may supply an already-premultiplied CGImage. Recover colors
            // where alpha is nonzero; zero-alpha color was already lost by its producer.
            if !colour { return opaqueDataImage(image, maxSide: maxSide) }
            guard let pixels = pixels(of: image, colour: true, maxSide: maxSide) else { return nil }
            for i in stride(from: 0, to: pixels.rgba.count, by: 4) {
                let a = Int(pixels.rgba.bytes[i + 3])
                if a > 0 {
                    for c in 0..<3 {
                        let linear = Int(toLinear[Int(pixels.rgba.bytes[i + c])])
                        pixels.rgba.bytes[i + c] = fromLinear[min(4095, (linear * 255 + a / 2) / a)]
                    }
                }
                pixels.rgba.bytes[i + 3] = 255
            }
            guard let provider = CGDataProvider(data: Data(bytes: pixels.rgba.bytes, count: pixels.rgba.count) as CFData) else { return nil }
            return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let provider = image.dataProvider else { return nil }
        let info = CGBitmapInfo(rawValue: (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | alpha.rawValue)
        return CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                       bytesPerRow: image.bytesPerRow, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                       provider: provider, decode: image.decode, shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent)
    }

    /// A premultiplied data image has already lost RGB at alpha zero. Recover its other
    /// samples numerically, without applying the color texture's transfer function.
    private static func opaqueDataImage(_ image: CGImage, maxSide: Int) -> CGImage? {
        let ratio = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio)), height = max(1, Int(Double(image.height) * ratio))
        guard let rgba = Buffer(count: width * height * 4) else { return nil }
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: rgba.bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba.bytes[i + 3])
            if alpha > 0 { for c in 0..<3 { rgba.bytes[i + c] = UInt8(min(255, (Int(rgba.bytes[i + c]) * 255 + alpha / 2) / alpha)) } }
            rgba.bytes[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes: rgba.bytes, count: rgba.count) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Decodes a compressed image no larger than needed: a 8192-pixel JPEG wanted at 2048
    /// is decoded at a reduced size where the format allows it.
    private static func decode(_ data: CFData, maxSide: Int, allowsSubsampling: Bool = true) -> CGImage? {
        let uncached = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data, uncached) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, uncached) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            guard width > 0, height > 0, width <= 32768, height <= 32768 else { return nil }
            // Find the largest power-of-two reduction that still covers `maxSide`.
            var factor = 1
            while max(width, height) / (factor * 2) >= maxSide, factor < 8 { factor *= 2 }
            // Alpha-free images (notably JPEG) still benefit from decoder subsampling.
            let hasNoAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) == false
            if factor > 1, allowsSubsampling || hasNoAlpha {
                let options = [kCGImageSourceSubsampleFactor: factor, kCGImageSourceShouldCache: false] as CFDictionary
                if let image = CGImageSourceCreateImageAtIndex(source, 0, options) { return image }
            }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, uncached)
    }

    /// Roughness and metallic from two separate grey images, in the green and blue channels
    /// of one texture (the layout of a combined image). A missing side is left at full.
    static func makePacked(roughness: ModelScene.TextureRef?, metallic: ModelScene.TextureRef?, device: MTLDevice, maxSide: Int) -> MTLTexture? {
        // One at a time, each let go before the next is decoded.
        var packed: Pixels?
        func fill(_ channel: Int, from texture: ModelScene.TextureRef?) {
            guard let texture, let image = pixels(of: texture, colour: false, maxSide: maxSide) else { return }
            if packed == nil, let buffer = Buffer(count: image.width * image.height * 4) {
                memset(buffer.bytes, 255, buffer.count)
                packed = Pixels(width: image.width, height: image.height, rgba: buffer)
            }
            guard let like = packed else { return }
            if image.width == like.width, image.height == like.height {
                for i in 0..<(like.width * like.height) { like.rgba.bytes[i * 4 + channel] = image.rgba.bytes[i * 4] }
            } else {
                for y in 0..<like.height { for x in 0..<like.width {
                    like.rgba.bytes[(y * like.width + x) * 4 + channel] = image.rgba.bytes[((y * image.height / like.height) * image.width + x * image.width / like.width) * 4]
                } }
            }
        }
        autoreleasepool { fill(1, from: roughness) }
        autoreleasepool { fill(2, from: metallic) }
        guard let packed else { return nil }
        return upload(packed.rgba.bytes, width: packed.width, height: packed.height, device: device, srgb: false)
    }

    /// A one-pixel texture, to stand in where a part has no image of some kind.
    static func solid(_ rgba: [UInt8], device: MTLDevice) -> MTLTexture? {
        rgba.withUnsafeBytes { upload($0.baseAddress!, width: 1, height: 1, device: device, srgb: false) }
    }

    /// The smaller versions are made here, on the CPU, and not by the GPU: asking the GPU
    /// for them was measured to hold about 70 MB more for a second or so after each 4096
    /// pixel image, on top of the image itself.
    private static func upload(_ bytes: UnsafeRawPointer, width: Int, height: Int, device: MTLDevice, srgb: Bool) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        guard texture.mipmapLevelCount > 1, let a = Buffer(count: max(1, width / 2) * max(1, height / 2) * 4), let b = Buffer(count: a.count) else { return texture }
        var source = bytes.assumingMemoryBound(to: UInt8.self), sourceWidth = width, sourceHeight = height
        var target = a, other = b
        for level in 1..<texture.mipmapLevelCount {
            let w = max(1, sourceWidth / 2), h = max(1, sourceHeight / 2)
            halve(source, sourceWidth, sourceHeight, into: target.bytes, w, h, colour: srgb)
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level, withBytes: target.bytes, bytesPerRow: w * 4)
            source = UnsafePointer(target.bytes); sourceWidth = w; sourceHeight = h
            swap(&target, &other)
        }
        return texture
    }

    /// sRGB byte to linear light in 0...4095, and back.
    private static let toLinear: [UInt16] = (0..<256).map { i in
        let c = Double(i) / 255
        return UInt16((c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)) * 4095 + 0.5)
    }
    private static let fromLinear: [UInt8] = (0..<4096).map { i in
        let c = Double(i) / 4095
        return UInt8((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    /// The shader samples sRGB into linear light, then divides by alpha. Perform
    /// the matching multiplication in linear light too, before sRGB encoding.
    private static func premultiplyLinear(_ pixels: Buffer, alreadyPremultiplied: Bool) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels.bytes[i + 3])
            for c in 0..<3 {
                let v = Int(pixels.bytes[i + c])
                let straight = alreadyPremultiplied && alpha > 0 ? min(255, (v * 255 + alpha / 2) / alpha) : v
                pixels.bytes[i + c] = fromLinear[(Int(toLinear[straight]) * alpha + 127) / 255]
            }
        }
    }

    /// Each pixel of the half-size image is the average of the two by two above it.
    /// Colours are averaged as light, not as the bytes that encode it, which is what the
    /// GPU does for an sRGB texture; alpha and data are averaged as they are.
    private static func halve(_ source: UnsafePointer<UInt8>, _ sw: Int, _ sh: Int, into target: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int, colour: Bool) {
        toLinear.withUnsafeBufferPointer { linear in
            fromLinear.withUnsafeBufferPointer { encoded in
                for y in 0..<h {
                    let row0 = source + min(y * 2, sh - 1) * sw * 4, row1 = source + min(y * 2 + 1, sh - 1) * sw * 4
                    let out = target + y * w * 4
                    for x in 0..<w {
                        let x0 = min(x * 2, sw - 1) * 4, x1 = min(x * 2 + 1, sw - 1) * 4
                        for c in 0..<4 {
                            if colour && c < 3 {
                                let sum = Int(linear[Int(row0[x0 + c])]) + Int(linear[Int(row0[x1 + c])]) + Int(linear[Int(row1[x0 + c])]) + Int(linear[Int(row1[x1 + c])])
                                out[x * 4 + c] = encoded[(sum + 2) / 4]
                            } else {
                                out[x * 4 + c] = UInt8((Int(row0[x0 + c]) + Int(row0[x1 + c]) + Int(row1[x0 + c]) + Int(row1[x1 + c]) + 2) / 4)
                            }
                        }
                    }
                }
            }
        }
    }
}
