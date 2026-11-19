// Regenerate the custom SF Symbol from the original manga-eye artwork.
// Run from the repository root: swift scripts/generate-anime-symbol.swift
import Foundation
import SwiftUI

struct AnimeEyeIcon: Shape {
    var weight: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        var eye = Path()
        eye.move(to: CGPoint(x: 2, y: 11))
        eye.addCurve(to: CGPoint(x: 21, y: 9), control1: CGPoint(x: 7, y: 3), control2: CGPoint(x: 15, y: 3))
        eye.addLine(to: CGPoint(x: 23, y: 6))
        eye.addLine(to: CGPoint(x: 22, y: 11 + weight))
        eye.addCurve(to: CGPoint(x: 3, y: 12 + weight), control1: CGPoint(x: 14, y: 5 + weight), control2: CGPoint(x: 8, y: 6 + weight))
        eye.closeSubpath()
        var lower = Path()
        lower.move(to: CGPoint(x: 4, y: 15))
        lower.addCurve(to: CGPoint(x: 21, y: 14), control1: CGPoint(x: 10, y: 21), control2: CGPoint(x: 16, y: 20))
        eye.addPath(lower.strokedPath(StrokeStyle(lineWidth: 1.4 + weight * 0.6, lineCap: .round)))
        eye.addEllipse(in: CGRect(x: 9, y: 8, width: 7, height: 10))
        // Reverse winding: the symbol compiler uses nonzero-filled contours.
        eye.move(to: CGPoint(x: 13, y: 11))
        eye.addCurve(to: CGPoint(x: 11.5, y: 9), control1: CGPoint(x: 13, y: 9.89543), control2: CGPoint(x: 12.328427, y: 9))
        eye.addCurve(to: CGPoint(x: 10, y: 11), control1: CGPoint(x: 10.671573, y: 9), control2: CGPoint(x: 10, y: 9.89543))
        eye.addCurve(to: CGPoint(x: 11.5, y: 13), control1: CGPoint(x: 10, y: 12.10457), control2: CGPoint(x: 10.671573, y: 13))
        eye.addCurve(to: CGPoint(x: 13, y: 11), control1: CGPoint(x: 12.328427, y: 13), control2: CGPoint(x: 13, y: 12.10457))
        eye.closeSubpath()
        return eye.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}


func svgPath(_ path: CGPath) -> String {
    var result = ""
    func point(_ p: CGPoint) -> String { String(format: "%.6f %.6f", Double(p.x), Double(p.y)) }
    path.applyWithBlock { item in
        let e = item.pointee
        switch e.type {
        case .moveToPoint: result += "M" + point(e.points[0])
        case .addLineToPoint: result += "L" + point(e.points[0])
        case .addQuadCurveToPoint: result += "Q" + point(e.points[0]) + " " + point(e.points[1])
        case .addCurveToPoint: result += "C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2])
        case .closeSubpath: result += "Z"
        @unknown default: break
        }
    }
    return result
}
let weights: [(String, CGFloat)] = [("Ultralight", -1), ("Thin", -0.75), ("Light", -0.4), ("Regular", 0), ("Medium", 0.3), ("Semibold", 0.6), ("Bold", 0.9), ("Heavy", 1.2), ("Black", 1.5)]
let scales: [(String, CGFloat, CGFloat)] = [("S", 0.783, 696), ("M", 1, 1126), ("L", 1.29, 1556)]
var guides = "", symbols = ""
for (scaleName, scale, baseline) in scales {
    for (name, y) in [("Baseline", baseline), ("Capline", baseline - 70.459)] {
        guides += "<line id=\"\(name)-\(scaleName)\" x1=\"263\" x2=\"3036\" y1=\"\(y)\" y2=\"\(y)\"/>\n"
    }
    for (index, weight) in weights.enumerated() {
        let variant = "\(weight.0)-\(scaleName)"
        let x = CGFloat(560 + index * 296)
        let unit = 4.2 * scale
        let path = AnimeEyeIcon(weight: weight.1).path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
            .applying(CGAffineTransform(scaleX: unit, y: unit)
                .concatenating(CGAffineTransform(translationX: x - 12 * unit, y: baseline - 35.2295 - 12 * unit)))
        symbols += "<g id=\"\(variant)\"><path fill=\"black\" fill-rule=\"evenodd\" d=\"\(svgPath(path.cgPath))\"/></g>\n"
        for (name, margin) in [("left", x - 12 * unit), ("right", x + 12 * unit)] {
            guides += "<line id=\"\(name)-margin-\(variant)\" x1=\"\(margin)\" x2=\"\(margin)\" y1=\"\(baseline - 100)\" y2=\"\(baseline + 25)\"/>\n"
        }
    }
}
let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 3300 2200">
<g id="Notes"><text id="template-version">Template v.3.0</text><rect id="artboard" width="3300" height="2200" fill="white"/></g>
<g id="Guides" fill="none" stroke="#27AAE1" stroke-width="0.5">\(guides)</g>
<g id="Symbols">\(symbols)</g>
</svg>
"""
try svg.write(toFile: "Packages/Spacebar3DKit/Sources/ViewerUI/Resources/Symbols.xcassets/anime-eye.symbolset/anime-eye.svg", atomically: true, encoding: .utf8)
