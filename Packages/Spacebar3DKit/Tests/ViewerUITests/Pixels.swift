import AppKit
import SwiftUI
import XCTest
@testable import ViewerUI

/// Drawing, read back as pixels: a view is rendered the way the screen would show it, so
/// that a test can say what is lit and where.
struct Picture {
    let width: Int, height: Int
    /// Premultiplied RGBA, row by row from the top.
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        width = w; height = h
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        bytes = data
    }

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    /// How many pixels are not clear.
    var drawn: Int { stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 8 }.count }

    /// The sum of every colour channel of every pixel: how much light there is.
    var light: Int { stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) + Int(bytes[$1 + 1]) + Int(bytes[$1 + 2]) } }

    /// The box all drawn pixels lie in, or nil when nothing is drawn.
    var extent: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                box = box.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
            }
        }
        return box
    }

    /// Whether two pictures differ anywhere.
    func differs(from other: Picture) -> Bool { width != other.width || height != other.height || bytes != other.bytes }
}

@MainActor
enum Render {
    /// A view drawn once at `size` (points) on a transparent ground, at scale 1.
    static func image<V: View>(_ view: V, size: CGSize) -> Picture? {
        // Glass is not drawn off the screen: the panels are asked for their solid form, so
        // that a picture does not depend on this Mac's transparency setting.
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.glassIsOff, true))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage.flatMap(Picture.init)
    }

    /// A view put on a window that is never shown, run for `seconds` so that what happens
    /// when it appears has happened, then read back.
    static func hosted<V: View>(_ view: V, size: CGSize, seconds: TimeInterval = 0.1) -> (picture: Picture?, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).environment(\.glassIsOff, true)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (nil, host) }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep.cgImage.flatMap(Picture.init), host)
    }
}
