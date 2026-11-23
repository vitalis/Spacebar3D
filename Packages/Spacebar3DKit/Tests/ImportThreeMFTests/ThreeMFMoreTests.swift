import CoreGraphics
import Foundation
import ImageIO
import ModelCore
import RenderMetal
import simd
import XCTest
import zlib
@testable import ImportThreeMF

/// More of 3MF: 64-bit zip records, odd markup, layered properties and the messages.
final class ThreeMFMoreTests: XCTestCase {
    // MARK: Building packages

    private enum Style { case plain, zip64End, zip64Entries(extra: Data), shortExtra, hugeValue, otherExtraFirst }

    private func put16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
    private func put32(_ v: Int, _ d: inout Data) { put16(v & 0xffff, &d); put16((v >> 16) & 0xffff, &d) }
    private func put64(_ v: Int, _ d: inout Data) { put32(v & 0xffff_ffff, &d); put32(v >> 32, &d) }

    /// A zip of stored files, its records written the way `style` says.
    private func zip(_ files: [(name: String, data: Data)], style: Style = .plain) -> Data {
        var out = Data(), directory = Data()
        for file in files {
            let name = Array(file.name.utf8), body = [UInt8](file.data)
            let crc = Int(body.withUnsafeBufferPointer { crc32(0, $0.baseAddress, UInt32($0.count)) })
            let offset = out.count
            put32(0x0403_4b50, &out); put16(20, &out); put16(0, &out); put16(0, &out); put16(0, &out); put16(0, &out)
            put32(crc, &out); put32(body.count, &out); put32(body.count, &out); put16(name.count, &out); put16(0, &out)
            out.append(contentsOf: name); out.append(contentsOf: body)
            // Fields as the central record carries them, and the extra field after the name.
            var size = body.count, packed = body.count, header = offset
            var extra = Data()
            switch style {
            case .zip64Entries:
                size = 0xffff_ffff; packed = 0xffff_ffff; header = 0xffff_ffff
                put16(1, &extra); put16(24, &extra); put64(body.count, &extra); put64(body.count, &extra); put64(offset, &extra)
            case .shortExtra:
                size = 0xffff_ffff
                put16(1, &extra); put16(4, &extra); put32(0, &extra)
            case .hugeValue:
                size = 0xffff_ffff
                put16(1, &extra); put16(8, &extra); put64(1 << 62, &extra)
            case .otherExtraFirst:
                size = 0xffff_ffff
                put16(0x5455, &extra); put16(2, &extra); put16(0, &extra)
                put16(1, &extra); put16(8, &extra); put64(body.count, &extra)
            default: break
            }
            put32(0x0201_4b50, &directory); put16(20, &directory); put16(20, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory)
            put32(crc, &directory); put32(packed, &directory); put32(size, &directory); put16(name.count, &directory)
            put16(extra.count, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory); put32(0, &directory); put32(header, &directory)
            directory.append(contentsOf: name); directory.append(extra)
        }
        let start = out.count
        out.append(directory)
        if case .zip64End = style {
            let record = out.count
            put32(0x0606_4b50, &out); put64(44, &out); put16(45, &out); put16(45, &out); put32(0, &out); put32(0, &out)
            put64(files.count, &out); put64(files.count, &out); put64(directory.count, &out); put64(start, &out)
            put32(0x0706_4b50, &out); put32(0, &out); put64(record, &out); put32(1, &out)
            put32(0x0605_4b50, &out); put16(0, &out); put16(0, &out); put16(0xffff, &out); put16(0xffff, &out)
            put32(0xffff_ffff, &out); put32(0xffff_ffff, &out); put16(0, &out)
        } else {
            put32(0x0605_4b50, &out); put16(0, &out); put16(0, &out); put16(files.count, &out); put16(files.count, &out)
            put32(directory.count, &out); put32(start, &out); put16(0, &out)
        }
        return out
    }

    private let rels = "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>"

    private let triangle = "<mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"0\" z=\"0\"/><vertex x=\"0\" y=\"1\" z=\"0\"/></vertices>"

    private func model(_ body: String) -> Data {
        Data("<?xml version=\"1.0\"?>\n<model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" xmlns:m=\"http://schemas.microsoft.com/3dmanufacturing/material/2015/02\">\(body)</model>".utf8)
    }

    private func files(_ body: String, relationships: String? = nil) -> [(name: String, data: Data)] {
        [(name: "_rels/.rels", data: Data((relationships ?? rels).utf8)), (name: "3D/3dmodel.model", data: model(body))]
    }

    private let plainBody = "<resources><object id=\"1\"><mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"0\" z=\"0\"/><vertex x=\"0\" y=\"1\" z=\"0\"/></vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh></object></resources><build><item objectid=\"1\"/></build>"

    // MARK: Zip records

    func testSixtyFourBitRecordsReadLikeThePlainOnes() throws {
        for style in [Style.zip64End, .zip64Entries(extra: Data()), .otherExtraFirst] {
            let scene = try ThreeMFReader.scene(from: zip(files(plainBody), style: style))
            XCTAssertEqual(scene.topology.faces, 1, "\(style)")
        }
    }

    func testSixtyFourBitRecordsThatLieAreSkippedNotTrusted() throws {
        // An entry whose real size is missing, or absurd, is left out: so the package has no model.
        for style in [Style.shortExtra, .hugeValue] {
            XCTAssertThrowsError(try ThreeMFReader.scene(from: zip(files(plainBody), style: style)), "\(style)")
        }
    }

    // MARK: Markup

    func testCommentsDeclarationsAndTextSectionsAreSteppedOver() throws {
        let body = "<!DOCTYPE model><![CDATA[ <vertex x=\"9\"/> ]]><!-- <triangle/> -->" + plainBody
        XCTAssertEqual(try ThreeMFReader.scene(from: zip(files(body))).topology.faces, 1)
        // Cut off in the middle of a text section or a declaration: no crash, nothing to show.
        for tail in ["<![CDATA[ never closed", "<!DOCTYPE never closed", "<!-- never closed"] {
            XCTAssertThrowsError(try ThreeMFReader.scene(from: zip(files(tail))), tail)
        }
    }

    func testAPackageWhoseRelationshipsNameNoModelFallsBackToTheFirstModelFile() throws {
        let thumbnails = rels.replacingOccurrences(of: "3dmodel\"", with: "thumbnail\"")
        XCTAssertEqual(try ThreeMFReader.scene(from: zip(files(plainBody, relationships: thumbnails))).topology.faces, 1)
    }

    func testEveryFailureHasAMessage() {
        let all: [ThreeMFReader.Failure] = [.notAPackage, .noModel, .damaged, .tooLarge, .empty]
        let messages = all.map { $0.errorDescription ?? "" }
        XCTAssertFalse(messages.contains(""))
        XCTAssertEqual(Set(messages).count, all.count)
    }

    // MARK: Properties

    private func png() throws -> Data {
        var pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testAGlossySurfaceIsASmoothOne() throws {
        let body = """
        <resources>
          <m:pbspeculardisplayproperties id="9"><m:pbspecular name="s" glossiness="0.75"/></m:pbspeculardisplayproperties>
          <basematerials id="1"><base name="a" displaycolor="#FF0000" displaypropertiesid="9"/></basematerials>
          <object id="1" pid="1" pindex="0">\(triangle)<triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>
        </resources><build><item objectid="1"/></build>
        """
        let scene = try ThreeMFReader.scene(from: zip(files(body)))
        let material = try XCTUnwrap(scene.meshes.first?.parts.first?.material.map { scene.materials[$0] })
        XCTAssertEqual(material.roughness, 0.25, accuracy: 1e-6)
        XCTAssertEqual(material.metallic, 0)
    }

    /// A colour group may name display properties as a group of base materials does: one
    /// entry for each of its colours, in their order.
    func testAColourGroupsDisplayPropertiesAreUsedForItsColours() throws {
        let body = """
        <resources>
          <m:pbmetallicdisplayproperties id="9">
            <m:pbmetallic name="a" metallicness="0.5" roughness="0.4"/>
            <m:pbmetallic name="b" metallicness="1" roughness="0.1"/>
          </m:pbmetallicdisplayproperties>
          <m:colorgroup id="2" displaypropertiesid="9"><m:color color="#FF0000"/><m:color color="#0000FF"/></m:colorgroup>
          <m:colorgroup id="4"><m:color color="#00FF00"/></m:colorgroup>
          <object id="1">\(triangle)<triangles>
            <triangle v1="0" v2="1" v3="2" pid="2" p1="0"/>
            <triangle v1="0" v2="2" v3="1" pid="2" p1="1"/>
            <triangle v1="1" v2="2" v3="0" pid="4" p1="0"/>
          </triangles></mesh></object>
        </resources><build><item objectid="1"/></build>
        """
        let scene = try ThreeMFReader.scene(from: zip(files(body)))
        let materials = try XCTUnwrap(scene.meshes.first).parts.compactMap { $0.material.map { scene.materials[$0] } }
        let red = try XCTUnwrap(materials.first { $0.baseColor.x > 0.9 && $0.baseColor.z < 0.1 })
        XCTAssertEqual(red.metallic, 0.5, accuracy: 1e-6)
        XCTAssertEqual(red.roughness, 0.4, accuracy: 1e-6)
        let blue = try XCTUnwrap(materials.first { $0.baseColor.z > 0.9 && $0.baseColor.x < 0.1 })
        XCTAssertEqual(blue.metallic, 1, accuracy: 1e-6)
        XCTAssertEqual(blue.roughness, 0.1, accuracy: 1e-6)
        // A group that names none keeps the plain look.
        let green = try XCTUnwrap(materials.first { $0.baseColor.y > 0.9 && $0.baseColor.x < 0.1 })
        XCTAssertEqual(green.metallic, 0)
        XCTAssertNotEqual(green.roughness, 0.4)
    }

    /// A colour laid over a base material takes the place of the material's own colour, by
    /// as much as the colour is solid: the format has a reader leave the material's colour
    /// out of the mixing and put the result on it. Where the colour covers the surface it is
    /// paint, no longer metal (Materials and Properties Extension 1.2.1, chapter 5: the new
    /// layer "should statistically cover" that share of the micro-facet area, and "when
    /// rendering on screen, the display color and display properties SHOULD be blended to
    /// provide a realistic preview"): a solid colour over a metal is not shown as metal.
    func testAColourLaidOverAMaterialTakesItsPlaceAndPaintsOverItsLook() throws {
        func material(_ colour: String, methods: String = "", plain: Bool = false) throws -> ModelScene.Material {
            if plain {
                let body = "<resources><m:colorgroup id=\"2\"><m:color color=\"\(colour)\"/></m:colorgroup><object id=\"1\">\(triangle)<triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\" pid=\"2\" p1=\"0\"/></triangles></mesh></object></resources><build><item objectid=\"1\"/></build>"
                let scene = try ThreeMFReader.scene(from: zip(files(body)))
                return try XCTUnwrap(scene.meshes.first?.parts.first?.material.map { scene.materials[$0] })
            }
            let body = """
            <resources>
              <m:pbmetallicdisplayproperties id="9"><m:pbmetallic name="m" metallicness="0.5" roughness="0.4"/></m:pbmetallicdisplayproperties>
              <basematerials id="1" displaypropertiesid="9"><base name="red" displaycolor="#FF0000"/></basematerials>
              <m:colorgroup id="2"><m:color color="\(colour)"/></m:colorgroup>
              <m:multiproperties id="3" pids="1 2"\(methods)><m:multi pindices="0 0"/></m:multiproperties>
              <object id="1">\(triangle)<triangles><triangle v1="0" v2="1" v3="2" pid="3" p1="0"/></triangles></mesh></object>
            </resources><build><item objectid="1"/></build>
            """
            let scene = try ThreeMFReader.scene(from: zip(files(body)))
            return try XCTUnwrap(scene.meshes.first?.parts.first?.material.map { scene.materials[$0] })
        }
        for methods in ["", " blendmethods=\"multiply\""] {
            let grey = try material("#808080", methods: methods)
            XCTAssertEqual(simd_distance(grey.baseColor, SIMD4(128, 128, 128, 255) / 255), 0, accuracy: 1e-3, "the grey, not red times grey\(methods)")
            XCTAssertEqual(grey.metallic, 0, accuracy: 1e-6, "solid paint over a metal is not metal\(methods)")
            XCTAssertEqual(grey.roughness, try material("#808080", plain: true).roughness, accuracy: 1e-6, "it looks as a plain colour does\(methods)")
        }
        // Half clear, it is mixed with the material's colour as light mixes: half of each is lighter than half the numbers.
        let half = try material("#00FF0080")
        XCTAssertEqual(simd_distance(half.baseColor, SIMD4(0.734, 0.737, 0, 1)), 0, accuracy: 4e-3)
        XCTAssertEqual(half.opacity, 1, "how solid the colour is says how much of it there is, not how solid the surface is")
        // And the metal left is the share the colour does not cover: half of 0.5.
        XCTAssertEqual(half.metallic, 0.25, accuracy: 0.02, "half covered by paint, half metal still")
    }

    func testColoursThatDifferFromCornerToCornerKeepTheImageBesideThem() throws {
        // The colour changes between the two entries, so the image cannot be painted into one.
        let body = """
        <resources>
          <m:colorgroup id="1"><m:color color="#FF0000"/><m:color color="#0000FF"/></m:colorgroup>
          <m:texture2d id="2" path="/3D/Textures/a.png" contenttype="image/png"/>
          <m:texture2dgroup id="4" texid="2"><m:tex2coord u="0" v="0"/><m:tex2coord u="1" v="1"/></m:texture2dgroup>
          <m:multiproperties id="6" pids="1 4"><m:multi pindices="0 0"/><m:multi pindices="1 1"/></m:multiproperties>
          <object id="1">\(triangle)<triangles><triangle v1="0" v2="1" v3="2" pid="6" p1="0" p2="1" p3="0"/></triangles></mesh></object>
        </resources><build><item objectid="1"/></build>
        """
        var all = files(body)
        all.append((name: "3D/Textures/a.png", data: try png()))
        let scene = try ThreeMFReader.scene(from: zip(all))
        XCTAssertEqual(scene.topology.faces, 1)
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertTrue(parts.contains { !$0.uv0.isEmpty }, "the coordinates survive")
        XCTAssertFalse(scene.textures.isEmpty)
    }

    // MARK: Layers over a metal, and colours beneath an image

    /// A 2 x 2 PNG of one colour (given multiplied by its alpha, as the picture is stored).
    private func solidPNG(_ pixel: [UInt8]) throws -> Data {
        var pixels = Array((0..<4).map { _ in pixel }.joined())
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Two triangles: one with an image laid over a base material that is polished metal,
    /// one in the plain metal. The image is one colour, `picture`, (as stored, multiplied by its alpha).
    private func metalWithImage(_ picture: [UInt8]) throws -> (scene: ModelScene, layered: ModelScene.Material, plain: ModelScene.Material) {
        let body = """
        <resources>
          <m:pbmetallicdisplayproperties id="9"><m:pbmetallic name="m" metallicness="1" roughness="0.2"/></m:pbmetallicdisplayproperties>
          <basematerials id="1"><base name="Metal" displaycolor="#C0C0C0" displaypropertiesid="9"/></basematerials>
          <m:texture2d id="2" path="/3D/Textures/a.png" contenttype="image/png"/>
          <m:texture2dgroup id="4" texid="2"><m:tex2coord u="0" v="0"/><m:tex2coord u="1" v="0"/><m:tex2coord u="0" v="1"/></m:texture2dgroup>
          <m:multiproperties id="6" pids="1 4"><m:multi pindices="0 0"/><m:multi pindices="0 1"/><m:multi pindices="0 2"/></m:multiproperties>
          <object id="1"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="1" y="1" z="0"/></vertices><triangles>
            <triangle v1="0" v2="1" v3="2" pid="6" p1="0" p2="1" p3="2"/>
            <triangle v1="1" v2="3" v3="2" pid="1" p1="0"/>
          </triangles></mesh></object>
        </resources><build><item objectid="1"/></build>
        """
        var all = files(body)
        all.append((name: "3D/Textures/a.png", data: try solidPNG(picture)))
        let scene = try ThreeMFReader.scene(from: zip(all))
        let parts = try XCTUnwrap(scene.meshes.first?.parts)
        XCTAssertEqual(parts.count, 2)
        let layered = try XCTUnwrap(parts.first { !$0.uv0.isEmpty }?.material.map { scene.materials[$0] })
        let plain = try XCTUnwrap(parts.first { $0.uv0.isEmpty }?.material.map { scene.materials[$0] })
        return (scene, layered, plain)
    }

    /// The consortium's own "multiprop-metallic" sample (a box of polished metal with a
    /// star and a smiley laid over one face) is pictured by the consortium with the face
    /// as paint. Here the face kept the metal's gloss and mirror look, so a painting on a
    /// metal looked like a metal sheet. Spec (Materials and Properties Extension 1.2.1, ch. 5):
    /// the layers' accumulated opacity is how much of the surface they cover, and on screen
    /// the display properties "SHOULD be blended". Solid paint is not metal; half-covering
    /// paint leaves half of it; faces with no layer stay polished metal.
    func testAnImageLaidOverMetalIsPaintWhereItCoversAndTheOtherFacesStayMetal() throws {
        let solid = try metalWithImage([255, 0, 0, 255])
        XCTAssertEqual(solid.layered.metallic, 0, accuracy: 0.05, "solid paint over metal")
        XCTAssertGreaterThan(solid.layered.roughness, 0.5, "and not the metal's polished 0.2")
        XCTAssertEqual(solid.plain.metallic, 1, accuracy: 1e-6, "a face with no layer is still metal")
        XCTAssertEqual(solid.plain.roughness, 0.2, accuracy: 1e-6)

        let half = try metalWithImage([128, 0, 0, 128])
        XCTAssertEqual(half.layered.metallic, 0.5, accuracy: 0.1, "half covered, half metal")
        XCTAssertEqual(half.plain.metallic, 1, accuracy: 1e-6)
    }

    /// Triangle in the 3MF's XZ plane (so it faces the viewer once turned Y up), each corner
    /// with its own colour of a colour group and, over the colours, one image of one colour.
    /// Rendered unlit, flat on to the camera: the colour at the pixel near each corner.
    private func cornerPixels(colours: [String], methods: String, picture: [UInt8]) throws -> [[Int]] {
        let body = """
        <resources>
          <m:colorgroup id="1"><m:color color="\(colours[0])"/><m:color color="\(colours[1])"/><m:color color="\(colours[2])"/></m:colorgroup>
          <m:texture2d id="2" path="/3D/Textures/a.png" contenttype="image/png"/>
          <m:texture2dgroup id="4" texid="2"><m:tex2coord u="0.5" v="0.5"/><m:tex2coord u="0.5" v="0.5"/><m:tex2coord u="0.5" v="0.5"/></m:texture2dgroup>
          <m:multiproperties id="6" pids="1 4"\(methods)><m:multi pindices="0 0"/><m:multi pindices="1 1"/><m:multi pindices="2 2"/></m:multiproperties>
          <object id="1"><mesh><vertices><vertex x="-1" y="0" z="-1"/><vertex x="1" y="0" z="-1"/><vertex x="0" y="0" z="1"/></vertices>
            <triangles><triangle v1="0" v2="1" v3="2" pid="6" p1="0" p2="1" p3="2"/></triangles></mesh></object>
        </resources><build><item objectid="1"/></build>
        """
        var all = files(body)
        all.append((name: "3D/Textures/a.png", data: try solidPNG(picture)))
        let scene = try ThreeMFReader.scene(from: zip(all))
        let renderer = try MetalRenderer()
        renderer.showGrid = false; renderer.showShadow = false; renderer.backgroundAlpha = 0
        renderer.look = RenderLook(view: .textured, style: .unlit)
        renderer.show(try renderer.makeScene(scene))
        renderer.camera = OrbitCamera(target: .zero, distance: 4, yaw: 0, pitch: 0, near: 0.01, far: 100)
        let image = try renderer.renderOffscreen(width: 256, height: 256)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<image.height { for x in 0..<image.width where image.pixel(x, y).a > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX > minX, maxY > minY else { XCTFail("nothing was drawn"); return [] }
        // The triangle's corners (-1, -1), (1, -1), (0, 1) span the drawn area.
        let corners = [SIMD2<Double>(-1, -1), SIMD2(1, -1), SIMD2(0, 1)]
        return (0..<3).map { k in
            var weights = [0.05, 0.05, 0.05]; weights[k] = 0.9
            let p = Swift.zip(weights, corners).reduce(SIMD2<Double>.zero) { $0 + $1.0 * $1.1 }
            let x = Int((Double(minX) + (p.x + 1) / 2 * Double(maxX - minX + 1)).rounded(.down))
            let y = Int((Double(maxY + 1) - (p.y + 1) / 2 * Double(maxY - minY + 1)).rounded(.down))
            let pixel = image.pixel(x, y)
            return [Int(pixel.r), Int(pixel.g), Int(pixel.b), Int(pixel.a)]
        }
    }

    /// What the screen shows near a corner whose colour is `corner` and whose neighbours' are
    /// `others`, the three mixed as light 90 : 5 : 5 (colours are interpolated as light).
    private func nearCorner(_ corner: [Double], _ others: [[Double]]) -> [Int] {
        func light(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func seen(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        return (0..<3).map { c in
            let l = 0.9 * light(corner[c] / 255) + 0.05 * light(others[0][c] / 255) + 0.05 * light(others[1][c] / 255)
            return Int((seen(l) * 255).rounded())
        }
    }

    private func assertPictures(_ got: [[Int]], _ expected: [[Double]], _ message: String, line: UInt = #line) {
        guard got.count == 3 else { return XCTFail("no pixels", line: line) }
        for k in 0..<3 {
            let others = [expected[(k + 1) % 3], expected[(k + 2) % 3]]
            let want = nearCorner(expected[k], others)
            for c in 0..<3 { XCTAssertEqual(Double(got[k][c]), Double(want[c]), accuracy: 30, "\(message): corner \(k) \(got[k]) expected \(want)", line: line) }
            XCTAssertGreaterThan(got[k][3], 250, "\(message): corner \(k) is solid", line: line)
        }
    }

    private let cyanMagentaWhite = ["#00FFFF", "#FF00FF", "#FFFFFF"]
    private let cyanMagentaWhiteRGB: [[Double]] = [[0, 255, 255], [255, 0, 255], [255, 255, 255]]

    /// An image set to multiply over colours that differ from corner to corner: yellow
    /// light through cyan, magenta and white filters is green, red and yellow (spec, chapter 5:
    /// "multiply": new layer rgb times what is beneath, blended in linear light). The image
    /// was drawn alone, as if the colours were not there.
    func testAnImageSetToMultiplyKeepsTheColoursBeneathItFromCornerToCorner() throws {
        let got = try cornerPixels(colours: cyanMagentaWhite, methods: " blendmethods=\"multiply\"", picture: [255, 255, 0, 255])
        assertPictures(got, [[0, 255, 0], [255, 0, 0], [255, 255, 0]], "yellow times the colour")
    }

    /// An image that is solid, set to mix (the default, and when named), covers the
    /// colours beneath it entirely (mix: new rgb * alpha + beneath * (1 - alpha), alpha 1):
    /// the colours at the corners must not tint it, multiplied in or otherwise.
    func testASolidImageSetToMixCoversTheColoursBeneathIt() throws {
        for methods in ["", " blendmethods=\"mix\""] {
            let got = try cornerPixels(colours: cyanMagentaWhite, methods: methods, picture: [255, 255, 0, 255])
            assertPictures(got, [[255, 255, 0], [255, 255, 0], [255, 255, 0]], "the image alone\(methods)")
        }
    }

    /// Where the image is fully clear, mix leaves the colour beneath untouched (alpha 0), so
    /// each corner shows its own colour, which the surface is solid with: a clear image over
    /// a colour that differs from corner to corner is that colour's gradient.
    func testAClearImageSetToMixShowsTheColoursBeneathItFromCornerToCorner() throws {
        let got = try cornerPixels(colours: cyanMagentaWhite, methods: "", picture: [0, 0, 0, 0])
        assertPictures(got, cyanMagentaWhiteRGB, "the colours alone")
    }
}
