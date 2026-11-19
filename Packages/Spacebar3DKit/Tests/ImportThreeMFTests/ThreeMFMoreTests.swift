import CoreGraphics
import Foundation
import ImageIO
import ModelCore
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

    func testTwoColoursLaidOverEachOtherAreMultipliedAndKeepTheirLook() throws {
        let body = """
        <resources>
          <m:pbmetallicdisplayproperties id="9"><m:pbmetallic name="m" metallicness="0.5" roughness="0.4"/></m:pbmetallicdisplayproperties>
          <basematerials id="1" displaypropertiesid="9"><base name="red" displaycolor="#FF0000"/></basematerials>
          <m:colorgroup id="2"><m:color color="#808080"/></m:colorgroup>
          <m:multiproperties id="3" pids="1 2"><m:multi pindices="0 0"/></m:multiproperties>
          <object id="1">\(triangle)<triangles><triangle v1="0" v2="1" v3="2" pid="3" p1="0"/></triangles></mesh></object>
        </resources><build><item objectid="1"/></build>
        """
        let scene = try ThreeMFReader.scene(from: zip(files(body)))
        let material = try XCTUnwrap(scene.meshes.first?.parts.first?.material.map { scene.materials[$0] })
        XCTAssertGreaterThan(material.baseColor.x, 0.4)
        XCTAssertLessThan(material.baseColor.x, 0.6, "red times half grey")
        XCTAssertEqual(material.baseColor.y, 0)
        XCTAssertEqual(material.metallic, 0.5, accuracy: 1e-6)
        XCTAssertEqual(material.roughness, 0.4, accuracy: 1e-6)
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
}
