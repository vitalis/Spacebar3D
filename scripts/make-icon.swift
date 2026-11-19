// Make the app icon from the artwork in scripts/icon/art.png: the picture, cut to the
// macOS rounded square with its soft shadow, at every size the asset catalog wants.
//   xcrun swift scripts/make-icon.swift [art.png] [AppIcon.appiconset]
import AppKit

let arguments = CommandLine.arguments
let artPath = arguments.count > 1 ? arguments[1] : "scripts/icon/art.png"
let setPath = arguments.count > 2 ? arguments[2] : "Spacebar3D/App/Assets.xcassets/AppIcon.appiconset"
guard let art = NSImage(contentsOfFile: artPath) else { fatalError("no artwork at \(artPath)") }

/// How much of the artwork is kept: the subject fills more of a small icon.
let kept = 0.86
/// Where the subject's middle is, from the left and from the bottom of the artwork.
let middle = (x: 0.50, y: 0.53)

func icon(_ pixels: Int) -> Data {
    let size = Double(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // The macOS shape: 824 of 1024, corner radius 185.4.
    let side = size * 824 / 1024
    let rect = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    let radius = size * 185.4 / 1024
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 10 / 1024)
    shadow.shadowBlurRadius = size * 20 / 1024
    shadow.set()
    NSColor(srgbRed: 0x07 / 255, green: 0x11 / 255, blue: 0x0C / 255, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    shape.addClip()
    let whole = art.size
    let cut = NSRect(
        x: whole.width * (middle.x - kept / 2), y: whole.height * (middle.y - kept / 2),
        width: whole.width * kept, height: whole.height * kept)
    art.draw(in: rect, from: cut, operation: .sourceOver, fraction: 1)

    // A hairline of light on the edge, as glass has.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let edge = NSBezierPath(
        roundedRect: rect.insetBy(dx: size / 1024, dy: size / 1024), xRadius: radius, yRadius: radius)
    edge.lineWidth = max(1, size * 2 / 1024)
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let url = URL(fileURLWithPath: setPath).appendingPathComponent("icon_\(pixels).png")
    try icon(pixels).write(to: url)
}
