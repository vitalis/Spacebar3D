import Foundation
import CoreGraphics
import ImageIO
import ModelCore
@testable import RenderMetal
import ImportGLTF
import simd
import XCTest

/// Normal maps need a tangent frame. These draw glTF squares with one constant, strongly
/// tilting normal-map texel, so any change in the picture comes from the frame alone.
final class NormalMapTangentTests: XCTestCase {
    private func png(_ rgba: [UInt8]) throws -> String {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    /// A flat square facing the camera (corners bottom-left, bottom-right, top-right,
    /// top-left), split along the diagonal from bottom-left to top-right, with a
    /// tilting normal map and optionally the file's own tangents.
    private func glTF(uv: [SIMD2<Float>], tangents: [SIMD4<Float>]?) throws -> ModelScene {
        let positions: [Float] = [-1,-1,0, 1,-1,0, 1,1,0, -1,1,0]
        let normals: [Float] = [0,0,1, 0,0,1, 0,0,1, 0,0,1]
        let coordinates: [Float] = uv.flatMap { [$0.x, $0.y] }
        let indices: [UInt16] = [0,1,2, 0,2,3]
        var bytes = Data()
        bytes.append(positions.withUnsafeBytes { Data($0) })
        bytes.append(normals.withUnsafeBytes { Data($0) })
        bytes.append(coordinates.withUnsafeBytes { Data($0) })
        bytes.append(indices.withUnsafeBytes { Data($0) })
        var attributes = "\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2"
        var accessors = """
        {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5126,"count":4,"type":"VEC3"},
        {"bufferView":2,"componentType":5126,"count":4,"type":"VEC2"},{"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"}
        """
        var views = """
        {"buffer":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":48},
        {"buffer":0,"byteOffset":96,"byteLength":32},{"buffer":0,"byteOffset":128,"byteLength":12}
        """
        if let tangents {
            let values = tangents.flatMap { [$0.x, $0.y, $0.z, $0.w] }
            bytes.append(values.withUnsafeBytes { Data($0) })
            attributes += ",\"TANGENT\":4"
            accessors += ",{\"bufferView\":4,\"componentType\":5126,\"count\":4,\"type\":\"VEC4\"}"
            views += ",{\"buffer\":0,\"byteOffset\":140,\"byteLength\":64}"
        }
        // Texel (0.1, 0.5, 0.6): a tangent-space normal of about (-0.8, 0, 0.2), tilted far over.
        let normalMap = try png([26, 128, 153, 255])
        let json = """
        {"asset":{"version":"2.0"},"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{\(attributes)},"indices":3,"material":0}]}],
         "accessors":[\(accessors)],"bufferViews":[\(views)],
         "buffers":[{"byteLength":\(bytes.count),"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}],
         "images":[{"uri":"\(normalMap)"}],"textures":[{"source":0}],
         "materials":[{"doubleSided":true,"normalTexture":{"index":0},
           "pbrMetallicRoughness":{"baseColorFactor":[0.6,0.6,0.6,1],"metallicFactor":0,"roughnessFactor":0.8}}]}
        """
        return try GLTFReader.scene(from: Data(json.utf8))
    }

    private func draw(_ scene: ModelScene) throws -> OffscreenImage {
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false
        renderer.backgroundAlpha = 0
        renderer.show(try renderer.makeScene(scene))
        renderer.look = RenderLook(view: .textured)
        renderer.camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100)
        return try renderer.renderOffscreen(width: 96, height: 96)
    }

    private func luma(_ image: OffscreenImage, _ x: Int, _ y: Int) -> Double {
        let p = image.pixel(x, y)
        return 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
    }

    /// Mean brightness of the middle of the picture, away from every edge.
    private func middle(_ image: OffscreenImage) -> Double {
        var sum = 0.0, count = 0.0
        for y in 36..<60 { for x in 36..<60 { sum += luma(image, x, y); count += 1 } }
        return sum / count
    }

    private let square: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
    private let alongU = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: 4)
    /// The same tangents turned a quarter turn about the normal.
    private let alongV = [SIMD4<Float>](repeating: SIMD4(0, 1, 0, 1), count: 4)

    /// A baked normal map is laid on the surface by the file's own tangents. The tangent
    /// of the file was ignored, so a map made for tangents turned a quarter way round
    /// was lit as if it were laid along the texture's U direction.
    func testAFilesOwnTangentsDecideWhichWayANormalMapTilts() throws {
        let along = middle(try draw(try glTF(uv: square, tangents: alongU)))
        let turned = middle(try draw(try glTF(uv: square, tangents: alongV)))
        XCTAssertGreaterThan(abs(along - turned), 15, "tangents along U: \(along), turned a quarter: \(turned)")
    }

    /// Where nothing is given and the texture coordinates are a plain axis-aligned
    /// rectangle, the surface is lit as if the tangents ran along U. The picture must not
    /// change for such models.
    func testASimpleSquareWithoutTangentsIsLitAsWithTangentsAlongU() throws {
        let without = try draw(try glTF(uv: square, tangents: nil))
        let with = try draw(try glTF(uv: square, tangents: alongU))
        var worst = 0, at = (0, 0)
        for y in 30..<66 { for x in 30..<66 {
            let a = without.pixel(x, y), b = with.pixel(x, y)
            let d = max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)))
            if d > worst { worst = d; at = (x, y) }
        } }
        XCTAssertLessThanOrEqual(worst, 2, "largest difference \(worst) at \(at); middle \(middle(without)) vs \(middle(with))")
    }

    /// A smooth flat square cut along a diagonal, its texture coordinates a trapezoid, so the two
    /// triangles stretch the image differently. The surface and the map are both smooth, yet a
    /// frame worked out per triangle jumped at the diagonal and showed a crease there.
    func testASmoothSquareShowsNoCreaseWhereTwoTrianglesMeet() throws {
        let trapezoid: [SIMD2<Float>] = [SIMD2(0, 0.8), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0.2)]
        let image = try draw(try glTF(uv: trapezoid, tangents: nil))
        // Find the square on screen, so the diagonal is found rather than assumed.
        var minX = 96, maxX = -1, minY = 96, maxY = -1
        for y in 0..<96 { for x in 0..<96 where image.pixel(x, y).a == 255 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        XCTAssertGreaterThan(maxX - minX, 30, "the square is drawn")
        let cx = Double(minX + maxX + 1) / 2, cy = Double(minY + maxY + 1) / 2
        let half = Double(maxX - minX + 1) / 2
        var crossing = 0.0, inside = 0.0
        var report: [String] = []
        // Horizontal scans over rows away from the corners; the diagonal runs up and to the right.
        for y in Int(cy - half * 0.6)...Int(cy + half * 0.6) {
            let hit = Int((cx + (cy - (Double(y) + 0.5))).rounded())
            var row: [Double] = []
            for x in (minX + 3)...(maxX - 3) { row.append(luma(image, x, y)) }
            for (i, x) in ((minX + 3)...(maxX - 3)).enumerated() where i > 0 {
                let delta = abs(row[i] - row[i - 1])
                if abs(x - hit) <= 1 { crossing = max(crossing, delta) }
                else if abs(x - hit) > 3 { inside = max(inside, delta) }
            }
            if y % 8 == 0 { report.append("y\(y) hit \(hit): \(row.map { Int($0) }.filter { _ in true }.dropFirst(max(0, hit - minX - 6)).prefix(12))") }
        }
        XCTAssertLessThanOrEqual(crossing, inside + 2, "largest step at the diagonal \(crossing), largest step elsewhere \(inside)\n\(report.joined(separator: "\n"))")
    }
}
