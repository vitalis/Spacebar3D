// Make the loader's picture from the icon's artwork: the part about the subject, with the
// dark of its background turned to clear, so that it stands in the viewer's own room.
//   xcrun swift scripts/make-mark.swift [art.png] [Mark.png]
import AppKit

let arguments = CommandLine.arguments
let artPath = arguments.count > 1 ? arguments[1] : "scripts/icon/art.png"
let outPath = arguments.count > 2 ? arguments[2] : "Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Mark.png"
guard let art = NSImage(contentsOfFile: artPath) else { fatalError("no artwork at \(artPath)") }

/// The part kept, in fractions of the artwork from its top left: a square about the subject.
let part = (x: 0.12, y: 0.07, side: 0.76)
let pixels = 512
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
let whole = art.size
let cut = NSRect(
    x: whole.width * part.x, y: whole.height * (1 - part.y - part.side),
    width: whole.width * part.side, height: whole.height * part.side)
art.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: cut, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

// What is as dark as the background is clear; what is lit is there, in its own colour.
let floor = 0.085, full = 0.30
let data = rep.bitmapData!
for index in 0..<(pixels * pixels) {
    let p = data + index * 4
    let r = Double(p[0]) / 255, g = Double(p[1]) / 255, b = Double(p[2]) / 255
    let t = min(1, max(0, (max(r, g, b) - floor) / (full - floor)))
    let alpha = t * t * (3 - 2 * t)
    // The bitmap keeps its colours already multiplied by how much of them is there.
    p[0] = UInt8((r * alpha * 255).rounded()); p[1] = UInt8((g * alpha * 255).rounded()); p[2] = UInt8((b * alpha * 255).rounded())
    p[3] = UInt8((alpha * 255).rounded())
}
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
