import Foundation
import ModelCore
import XCTest

// The cases come from the former web renderer's tests of format detection and of the
// topology label; each test name carries the title of the case it was taken from.
//
// A TypeScript `Uint8Array` view with a non-zero `byteOffset` becomes a `Data` slice with a
// non-zero `startIndex` (see `inSlice`).

// MARK: - Fixtures (same names and shapes as the TypeScript helpers)

private func text(_ s: String) -> Data { Data(s.utf8) }
private func bytes(_ b: UInt8...) -> Data { Data(b) }
private func cat(_ parts: Data...) -> Data {
    var out = Data()
    for p in parts { out.append(p) }
    return out
}
private func zeros(_ n: Int) -> Data { Data(repeating: 0, count: n) }

/// The same bytes as a slice of a larger `Data` filled with `fill`, so `startIndex` is `before`.
private func inSlice(_ d: Data, fill: UInt8 = 0xff, before: Int = 13, after: Int = 9) -> Data {
    var big = Data(repeating: fill, count: before + d.count + after)
    big.replaceSubrange(before..<(before + d.count), with: d)
    let s = big[before..<(before + d.count)]
    precondition(s.startIndex == before)
    return s
}

private func setUInt32LE(_ d: inout Data, at offset: Int, _ value: UInt32) {
    for i in 0..<4 { d[d.startIndex + offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xff) }
}

private func binaryStl(_ triangles: Int, extra: Int = 0, header: String = "binary stl") -> Data {
    var out = zeros(84 + triangles * 50 + extra)
    out.replaceSubrange(0..<header.utf8.count, with: text(header))
    setUInt32LE(&out, at: 80, UInt32(triangles))
    return out
}

/// 3D Studio header: 0x4D4D, then a little-endian chunk length (`nil` = the whole file).
private func ds3(_ length: UInt32?, total: Int = 32) -> Data {
    var out = zeros(total)
    out[0] = 0x4d
    out[1] = 0x4d
    setUInt32LE(&out, at: 2, length ?? UInt32(total))
    return out
}

private let BIN_FBX = cat(text("Kaydara FBX Binary  \0"), bytes(0x1a, 0), zeros(40))
private let ASCII_FBX = text("; FBX 7.4.0 project file\nFBXHeaderExtension:  {\n\tFBXHeaderVersion: 1003\n}\n")
private let OBJ = text("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
private func GLB(_ json: String) -> Data { cat(text("glTF"), bytes(2, 0, 0, 0, 0, 0, 0, 0), text(json)) }
private let ZIP = "PK\u{03}\u{04}"

private func detect(_ d: Data, _ ext: String) -> Format { FormatDetector.detect(d, ext: ext) }

// MARK: - describe('detectFormat: one case per branch')

final class DetectFormatBranchTests: XCTestCase {
    func testGLB() { XCTAssertEqual(detect(GLB("{}"), "glb"), .gltf) }
    func testBlendRaw() { XCTAssertEqual(detect(text("BLENDER-v305REND"), "blend"), .blend) }
    func testBlendZstd() { XCTAssertEqual(detect(bytes(0x28, 0xb5, 0x2f, 0xfd, 1, 2, 3, 4), "blend"), .blend) }
    func testBlendGzip() { XCTAssertEqual(detect(bytes(0x1f, 0x8b, 8, 0, 0, 0, 0, 0), "blend"), .blend) }
    func test3MFByExtension() { XCTAssertEqual(detect(cat(text(ZIP), zeros(40)), "3mf"), .threeMF) }
    func test3MFBy3dmodelModelEntry() { XCTAssertEqual(detect(cat(text(ZIP), text("3D/3dmodel.model")), ""), .threeMF) }
    func test3MFByContentTypesEntry() { XCTAssertEqual(detect(cat(text(ZIP), text("[Content_Types].xml")), ""), .threeMF) }
    func testUSDZZipWithUsdcEntry() { XCTAssertEqual(detect(cat(text(ZIP), text("model.usdc")), "usdz"), .usd) }
    func testAnyOtherZipIsTreatedAsUSDZWhateverTheExtension() {
        XCTAssertEqual(detect(cat(text(ZIP), zeros(20)), "glb"), .usd)
        XCTAssertEqual(detect(cat(text(ZIP), zeros(20)), ""), .usd)
    }
    func testZip3MFEntryNameBeyondFirst4096BytesIsNotSeenWithoutExtensionHint() {
        let zip = cat(text(ZIP), zeros(5000), text("3D/3dmodel.model"))
        XCTAssertEqual(detect(zip, ""), .usd)
        XCTAssertEqual(detect(zip, "3mf"), .threeMF)
    }
    func testOnly3BytesOfTheZipSignatureIsNotAZip() { XCTAssertEqual(detect(text("PK\u{03}"), ""), .gltf) }
    func testUSDC() { XCTAssertEqual(detect(text("PXR-USDC\0\0\0\0"), "usdc"), .usd) }
    func testUSDA() { XCTAssertEqual(detect(text("#usda 1.0\n(\n)\n"), "usda"), .usd) }
    func testUSDAMagicWinsOverANonUsdExtension() { XCTAssertEqual(detect(text("#usda 1.0\n"), "obj"), .usd) }
    func testPLYLFAndCRLF() {
        XCTAssertEqual(detect(text("ply\nformat ascii 1.0\n"), "ply"), .ply)
        XCTAssertEqual(detect(text("ply\r\nformat ascii 1.0\r\n"), "ply"), .ply)
    }
    func testPLYNeedsTheNewlineRightAfterTheMagic() {
        XCTAssertNotEqual(detect(text("plyfile\n"), "ply"), .ply)
        XCTAssertNotEqual(detect(text("PLY\n"), "ply"), .ply)
    }
    func testBinarySTL() { XCTAssertEqual(detect(binaryStl(3), "stl"), .stl) }
    func testTextSTL() { XCTAssertEqual(detect(text("solid cube\n facet normal 0 0 1\n  outer loop\n"), "stl"), .stl) }
    func test3DSChunkLengthEqualsFileLength() { XCTAssertEqual(detect(ds3(nil), ""), .threeDS) }
    func test3DSExtensionFallbackWhenTheLengthDoesNotMatch() { XCTAssertEqual(detect(ds3(999), "3ds"), .threeDS) }
    func testCollada() { XCTAssertEqual(detect(text("<?xml version=\"1.0\"?>\n<COLLADA xmlns=\"x\">"), "dae"), .dae) }
    func testGlTFJSONByLeadingBraceWithLeadingWhitespace() {
        XCTAssertEqual(detect(text("{\"asset\":{\"version\":\"2.0\"}}"), ""), .gltfJSON)
        XCTAssertEqual(detect(text("  \n\t {\"asset\":{}}"), "json"), .gltfJSON)
    }
    func testGlTFJSONByExtensionWhateverTheContent() { XCTAssertEqual(detect(text("not json at all"), "gltf"), .gltfJSON) }
    func testOBJ() { XCTAssertEqual(detect(OBJ, "obj"), .obj) }
    func testOBJIsDetectedWithoutAnExtension() { XCTAssertEqual(detect(OBJ, ""), .obj) }
    func testASCIIFBX() { XCTAssertEqual(detect(ASCII_FBX, "fbx"), .fbx) }
    func testBinaryFBX() { XCTAssertEqual(detect(BIN_FBX, "fbx"), .fbx) }
    func testUSDByExtensionWhenNothingElseMatches() {
        for ext in ["usd", "usda", "usdc", "usdz"] {
            XCTAssertEqual(detect(bytes(1, 2, 3, 4, 5, 6, 7, 8, 9), ext), .usd, ext)
        }
    }
    func testDefaultIsGltf() {
        XCTAssertEqual(detect(bytes(1, 2, 3, 4, 5, 6, 7, 8, 9), ""), .gltf)
        XCTAssertEqual(detect(bytes(1, 2, 3, 4, 5, 6, 7, 8, 9), "xyz"), .gltf)
    }
}

// MARK: - describe('detectFormat: order of checks')

final class DetectFormatOrderTests: XCTestCase {
    func testGLBWhoseJSONMentionsFBXIsGltfNotFbx() {
        XCTAssertEqual(detect(GLB("{\"asset\":{\"generator\":\"FBX2glTF\"}}"), "glb"), .gltf)
        XCTAssertEqual(detect(GLB("{\"asset\":{\"generator\":\"FBX2glTF\"}}"), "fbx"), .gltf)
    }
    func testGlTFMagicBeatsTheFileExtension() { XCTAssertEqual(detect(GLB("{}"), "obj"), .gltf) }
    func testGlTFMagicIsCheckedBeforeBlendZipAndTheRest() {
        XCTAssertEqual(detect(cat(text("glTF"), text("BLENDER")), ""), .gltf)
    }
    // 'blend is checked before zip/STL: a gzip-compressed non-blend file is "blend" whatever the extension'
    func testBlendIsCheckedBeforeZipSTLGzipIsBlendWhateverTheExtension() {
        let gz = bytes(0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 3, 0)
        for ext in ["obj", "stl", "ply", "fbx", "gltf", ""] { XCTAssertEqual(detect(gz, ext), .blend, ext) }
    }
    // 'zip is checked before STL: a zip is never a binary STL even if the size matches'
    func testZipIsCheckedBeforeSTL() {
        var z = binaryStl(2)
        z.replaceSubrange(0..<4, with: text(ZIP))
        XCTAssertEqual(detect(z, "stl"), .usd)
    }
    func testPLYIsCheckedBeforeSTL() {
        let p = binaryStl(2, header: "ply\nformat binary_little_endian 1.0")
        XCTAssertEqual(detect(p, "ply"), .ply)
    }
    func testBinarySTLBeats3DSWhenBothCouldMatch() {
        var s = binaryStl(2)
        s[0] = 0x4d
        s[1] = 0x4d
        XCTAssertEqual(detect(s, ""), .stl)
    }
    func testColladaBeatsTheGltfExtensionAndOBJ() { XCTAssertEqual(detect(text("<COLLADA>\nv 1 2 3\n"), "gltf"), .dae) }
    func testJSONBeatsOBJFBXAndTheUsdExtension() {
        XCTAssertEqual(detect(text("{\"note\":\"FBX\"}\nv 1 2 3\n"), "usd"), .gltfJSON)
    }
    func testTheGltfExtensionBeatsOBJContent() { XCTAssertEqual(detect(OBJ, "gltf"), .gltfJSON) }
    func testAnOBJWhoseCommentMentionsFBXIsObjNotFbx() {
        XCTAssertEqual(detect(text("# exported from FBX\nv 0 0 0\nf 1 2 3\n"), "obj"), .obj)
        XCTAssertEqual(detect(text("# FBX\n# FBX\nusemtl m\nv 0 0 0\n"), ""), .obj)
    }
    // 'ASCII FBX whose body has OBJ-looking lines stays fbx (FBXHeaderExtension rules OBJ out)'
    func testASCIIFBXWhoseBodyHasOBJLookingLinesStaysFbx() {
        let f = text("; FBX 7.4.0 project file\nFBXHeaderExtension:  {\n}\nv 1 2 3\n")
        XCTAssertEqual(detect(f, "fbx"), .fbx)
    }
    func testOBJAndFBXContentBeatTheUsdExtension() {
        XCTAssertEqual(detect(OBJ, "usd"), .obj)
        XCTAssertEqual(detect(ASCII_FBX, "usdz"), .fbx)
    }
    func test3DSMagicWithAMismatchingLengthAndNoExtensionIsNot3ds() {
        XCTAssertNotEqual(detect(ds3(999), ""), .threeDS)
    }
}

// MARK: - describe('detectFormat: adversarial inputs')

final class DetectFormatAdversarialTests: XCTestCase {
    func testEmptyBufferFallsThroughToTheDefault() {
        XCTAssertEqual(detect(Data(), ""), .gltf)
        XCTAssertEqual(detect(Data(), "usd"), .usd)
        XCTAssertEqual(detect(Data(), "gltf"), .gltfJSON)
    }
    // '1 to 7 byte buffers never throw, for a spread of extensions' (here: never trap)
    func test1To7ByteBuffersNeverTrapForASpreadOfExtensions() {
        let seeds = [text("BLENDER"), text("PK\u{03}\u{04}xyz"), text("glTF123"), text("ply\nabc"),
                     bytes(0x4d, 0x4d, 1, 2, 3, 4, 5), bytes(0x1f, 0x8b, 1, 2, 3, 4, 5), text("{ }{ }{ }")]
        for seed in seeds {
            for n in 1...7 {
                for ext in ["", "gltf", "3ds", "3mf", "usd", "stl"] {
                    _ = detect(seed.prefix(n), ext)
                }
            }
        }
    }
    func testTinyBuffersExpectedAnswers() {
        XCTAssertEqual(detect(text("BLENDER"), ""), .blend)
        XCTAssertEqual(detect(text("glTF"), ""), .gltf)
        XCTAssertEqual(detect(bytes(0x1f, 0x8b), ""), .blend)
        XCTAssertEqual(detect(text("{"), ""), .gltfJSON)
        XCTAssertEqual(detect(text("PK"), ""), .gltf)
    }
    func test3DSNeedsMoreThan6BytesEvenWithTheExtensionHint() {
        XCTAssertEqual(detect(bytes(0x4d, 0x4d, 6, 0, 0, 0), "3ds"), .gltf)
        XCTAssertEqual(detect(bytes(0x4d, 0x4d, 7, 0, 0, 0, 0), "3ds"), .threeDS)
    }
    // 'views with a non-zero byteOffset: the DataView reads respect the offset'
    func testSlicesWithANonZeroStartIndexTheReadsRespectTheOffset() {
        XCTAssertEqual(detect(inSlice(binaryStl(5)), ""), .stl)
        XCTAssertEqual(detect(inSlice(ds3(nil)), ""), .threeDS)
        XCTAssertEqual(detect(inSlice(GLB("{}")), ""), .gltf)
        XCTAssertEqual(detect(inSlice(OBJ, fill: 0), ""), .obj)
        XCTAssertEqual(detect(inSlice(text("BLENDER-v305"), fill: 0), ""), .blend)
        XCTAssertEqual(detect(inSlice(BIN_FBX, fill: 0), ""), .fbx)
    }
    // 'a view of a larger buffer is judged by its own length, not the buffer length'
    func testASliceOfALargerBufferIsJudgedByItsOwnLength() {
        let stl = binaryStl(5)
        let big = cat(stl, zeros(100))
        XCTAssertEqual(detect(big.prefix(stl.count), ""), .stl)
        XCTAssertNotEqual(detect(big, ""), .stl)
    }
    func testHugeDeclaredSTLTriangleCountThatDoesNotMatchTheSizeIsNotSTL() {
        for n in [UInt32(0xffff_ffff), 0x7fff_ffff, 1_000_000] {
            var s = binaryStl(0)
            setUInt32LE(&s, at: 80, n)
            XCTAssertNotEqual(detect(cat(s, zeros(500)), ""), .stl, String(n))
        }
    }
    func testBinarySTLWithAZeroTriangleCountIsNotRecognisedByItsBytesAlone() {
        XCTAssertEqual(detect(binaryStl(0), ""), .gltf)
    }
    func testATextFileThatMerelyStartsWithSolidIsNotSTL() {
        XCTAssertNotEqual(detect(text("solid state drives are fast\n"), "txt"), .stl)
        XCTAssertNotEqual(detect(text("solid\n"), ""), .stl)
        XCTAssertNotEqual(detect(text("solidify facet normal x"), ""), .stl)
    }
    func testSolidWithLeadingWhitespaceAndAFacetIsSTL() {
        XCTAssertEqual(detect(text("\n  solid x\nfacet   normal 0 0 1"), ""), .stl)
    }
    func testSolidHeaderOnABinarySTLWithTheExactSizeIsStillSTL() {
        XCTAssertEqual(detect(binaryStl(4, header: "solid exported by somebody"), ""), .stl)
    }
    func testNULHeavyAndRandomDataFallsThroughToTheDefaultWithoutThrowing() {
        XCTAssertEqual(detect(zeros(10_000), ""), .gltf)
        let random = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 131 + 7) })
        _ = detect(random, "")
    }
    func testAVeryLargeBufferIsClassifiedFromItsHeadOnly() {
        let big = cat(OBJ, Data(repeating: 0x20, count: 20_000_000))
        XCTAssertEqual(detect(big, "obj"), .obj)
    }
    // 'Gaps found by exercising the extension argument'
    func testABinarySTLWithTrailingBytesIsSTLWhenTheExtensionSaysSo() { XCTAssertEqual(detect(binaryStl(3, extra: 16), "stl"), .stl) }
    func testAnEmptyZeroTriangleBinarySTLWithExtSTLIsSTL() { XCTAssertEqual(detect(binaryStl(0), "stl"), .stl) }
}

// MARK: - describe('isFBX')

final class IsFBXTests: XCTestCase {
    func testBinarySignature() { XCTAssertTrue(FormatDetector.isFBX(BIN_FBX)) }
    func testBinarySignatureNeedsMoreThanThe18SignatureBytes() {
        // Both contain "FBX" in the first 64 bytes, so the ASCII rule accepts them.
        XCTAssertTrue(FormatDetector.isFBX(text("Kaydara FBX Binary")))
        XCTAssertTrue(FormatDetector.isFBX(text("Kaydara FBX Binarx\0\0\0\0")))
    }
    func testASCIIFBXWithinTheFirst64Bytes() {
        XCTAssertTrue(FormatDetector.isFBX(ASCII_FBX))
        XCTAssertTrue(FormatDetector.isFBX(cat(Data(), text(String(repeating: "x", count: 61) + "FBX"))))
    }
    func testASCIIFBXBeyondTheFirst64BytesIsNotSeen() {
        XCTAssertFalse(FormatDetector.isFBX(text(String(repeating: "x", count: 62) + "FBX")))
    }
    func testGLBMagicIsNeverFBXEvenWithFBXInTheHead() {
        XCTAssertFalse(FormatDetector.isFBX(GLB("{\"generator\":\"FBX2glTF\"}")))
    }
    func testEmptyAndUnrelatedInput() {
        XCTAssertFalse(FormatDetector.isFBX(Data()))
        XCTAssertFalse(FormatDetector.isFBX(OBJ))
        XCTAssertFalse(FormatDetector.isFBX(bytes(1, 2, 3)))
    }
    func testLowerCaseFbxDoesNotMatch() { XCTAssertFalse(FormatDetector.isFBX(text("; fbx 7.4.0"))) }
    func testRespectsAByteOffsetView() { XCTAssertTrue(FormatDetector.isFBX(inSlice(ASCII_FBX, fill: 0x41))) }
}

// MARK: - describe('isOBJ')

final class IsOBJTests: XCTestCase {
    func testEachKeyword() {
        for line in ["v 1 2 3", "vn 0 0 1", "vt 0 0", "f 1 2 3", "o name", "g group", "mtllib a.mtl", "usemtl mat"] {
            XCTAssertTrue(FormatDetector.isOBJ(text("\(line)\n")), line)
        }
    }
    func testKeywordIsFoundOnALaterLineWithIndentationTabsAndCRLF() {
        XCTAssertTrue(FormatDetector.isOBJ(text("# comment\r\n\r\n   \tv\t1 2 3\r\n")))
    }
    func testKeywordWithoutAnArgumentOrWithoutASeparatorIsNotEnough() {
        for s in ["v\n", "v \n", "vertex 1 2 3", "f1 2 3", "mtllib\n", "o\t\n"] {
            XCTAssertFalse(FormatDetector.isOBJ(text(s)), s.debugDescription)
        }
    }
    func testCommentsOnly() { XCTAssertFalse(FormatDetector.isOBJ(text("# v 1 2 3\n# f 1 2 3\n"))) }
    func testAnyNULByteInTheFirst8KiBRulesItOut() {
        XCTAssertFalse(FormatDetector.isOBJ(cat(OBJ, bytes(0))))
        // NUL beyond 8192 is not examined
        XCTAssertTrue(FormatDetector.isOBJ(cat(OBJ, Data(repeating: 0x20, count: 9000), bytes(0))))
    }
    func testEmpty() { XCTAssertFalse(FormatDetector.isOBJ(Data())) }
    func testFBXHeaderExtensionRulesItOut() { XCTAssertFalse(FormatDetector.isOBJ(text("FBXHeaderExtension\nv 1 2 3\n"))) }
    func testFBXInACommentDoesNot() { XCTAssertTrue(FormatDetector.isOBJ(text("# FBX\nv 1 2 3\n"))) }
    func testKeywordOnlyAfterTheFirst8192BytesIsNotSeen() {
        XCTAssertFalse(FormatDetector.isOBJ(cat(text(String(repeating: "#", count: 8300) + "\n"), OBJ)))
    }
    func testJSONAndColladaAreNotOBJ() {
        XCTAssertFalse(FormatDetector.isOBJ(text("{\"a\":1}")))
        XCTAssertFalse(FormatDetector.isOBJ(text("<COLLADA></COLLADA>")))
    }
    func testRespectsAByteOffsetView() { XCTAssertTrue(FormatDetector.isOBJ(inSlice(OBJ, fill: 0))) }
}

// MARK: - describe('isSTL')

final class IsSTLTests: XCTestCase {
    func testExactSizeRule() {
        XCTAssertTrue(FormatDetector.isSTL(binaryStl(1)))
        XCTAssertTrue(FormatDetector.isSTL(binaryStl(1000)))
        XCTAssertFalse(FormatDetector.isSTL(binaryStl(3, extra: 1)), "one byte too many")
        let short = binaryStl(3)
        XCTAssertFalse(FormatDetector.isSTL(short.prefix(short.count - 1)), "one byte too few")
    }
    func testZeroCountIsNeverBinarySTL() { XCTAssertFalse(FormatDetector.isSTL(binaryStl(0))) }
    func testFewerThan84BytesIsNeverBinary() { XCTAssertFalse(FormatDetector.isSTL(zeros(83))) }
    func testCountTimes50DoesNotOverflowIntoAFalseMatch() {
        var s = binaryStl(0)
        setUInt32LE(&s, at: 80, 0xffff_ffff)
        XCTAssertFalse(FormatDetector.isSTL(s))
    }
    func testTextSTLNeedsBothSolidFirstAndAFacetNormal() {
        XCTAssertTrue(FormatDetector.isSTL(text("solid a\nfacet normal 0 0 1\n")))
        XCTAssertFalse(FormatDetector.isSTL(text("solid a\nendsolid a\n")))
        XCTAssertFalse(FormatDetector.isSTL(text("facet normal 0 0 1\n")))
        XCTAssertFalse(FormatDetector.isSTL(text("my solid\nfacet normal 0 0 1\n")))
        XCTAssertFalse(FormatDetector.isSTL(text("SOLID a\nfacet normal 0 0 1\n")), "case-sensitive")
    }
    func testFacetMarkerPastTheFirst1024BytesIsNotSeen() {
        XCTAssertFalse(FormatDetector.isSTL(text("solid " + String(repeating: "n", count: 1100) + "\nfacet normal 0 0 1\n")))
    }
    func testEmpty() { XCTAssertFalse(FormatDetector.isSTL(Data())) }
    func testRespectsAByteOffsetViewForTheCountRead() {
        XCTAssertTrue(FormatDetector.isSTL(inSlice(binaryStl(7))))
        XCTAssertFalse(FormatDetector.isSTL(inSlice(binaryStl(7, extra: 3))))
    }
}

// MARK: - The topology label

final class TopologyLabelTests: XCTestCase {
    private func t(_ triangles: Int, _ quads: Int, _ ngons: Int) -> String {
        topologyLabel(triangles: triangles, quads: quads, ngons: ngons)
    }
    func testEmpty() { XCTAssertEqual(t(0, 0, 0), "–") }
    func testSingleKinds() {
        XCTAssertEqual(t(5, 0, 0), "Triangle")
        XCTAssertEqual(t(0, 5, 0), "Quad")
        XCTAssertEqual(t(0, 0, 5), "N-gon")
    }
    func testMixed() {
        XCTAssertEqual(t(1, 1, 0), "Mixed")
        XCTAssertEqual(t(1, 0, 1), "Mixed")
        XCTAssertEqual(t(0, 1, 1), "Mixed")
        XCTAssertEqual(t(1, 1, 1), "Mixed")
    }
}

// MARK: - Swift-specific cases (not in the TypeScript suite)

final class SwiftSpecificFormatTests: XCTestCase {
    func testEmptyDataThroughEveryPredicate() {
        XCTAssertFalse(FormatDetector.isBlend(Data()))
        XCTAssertFalse(FormatDetector.isFBX(Data()))
        XCTAssertFalse(FormatDetector.isOBJ(Data()))
        XCTAssertFalse(FormatDetector.isSTL(Data()))
    }
    func testInputsShorterThanTheirSignatures() {
        XCTAssertFalse(FormatDetector.isBlend(text("BLENDE")))
        XCTAssertFalse(FormatDetector.isBlend(bytes(0x28, 0xb5, 0x2f)))
        XCTAssertFalse(FormatDetector.isBlend(bytes(0x1f)))
        XCTAssertEqual(detect(text("glT"), ""), .gltf)  // default, not a crash
        XCTAssertEqual(detect(text("ply"), "ply"), .gltf)
        XCTAssertEqual(detect(text("#usd"), ""), .gltf)
        XCTAssertEqual(detect(text("PXR-USD"), ""), .gltf)
        XCTAssertEqual(detect(zeros(83), ""), .gltf)
        XCTAssertEqual(detect(zeros(83), "stl"), .stl)
        XCTAssertEqual(detect(bytes(0x4d), "3ds"), .gltf)
    }
    func testIsBlendDirect() {
        XCTAssertTrue(FormatDetector.isBlend(text("BLENDER-v305REND")))
        XCTAssertTrue(FormatDetector.isBlend(bytes(0x28, 0xb5, 0x2f, 0xfd)))
        XCTAssertTrue(FormatDetector.isBlend(bytes(0x1f, 0x8b)))
        XCTAssertFalse(FormatDetector.isBlend(text("blender")))
        XCTAssertFalse(FormatDetector.isBlend(inSlice(text("BLENDER"), fill: 0).dropFirst()))
    }
    func testSlicedDataForSignatureBranchesThatUsePrefixes() {
        XCTAssertEqual(detect(inSlice(cat(text(ZIP), text("3D/3dmodel.model")), fill: 0), ""), .threeMF)
        XCTAssertEqual(detect(inSlice(text("PXR-USDC\0\0\0\0")), ""), .usd)
        XCTAssertEqual(detect(inSlice(text("ply\r\nformat ascii 1.0\r\n")), ""), .ply)
        XCTAssertEqual(detect(inSlice(text("<COLLADA>"), fill: 0), ""), .dae)
        XCTAssertEqual(detect(inSlice(text("  {\"a\":1}"), fill: 0), ""), .gltfJSON)
        XCTAssertEqual(detect(inSlice(ASCII_FBX, fill: 0), ""), .fbx)
        XCTAssertEqual(detect(inSlice(ds3(999), fill: 0xff), "3ds"), .threeDS)
        XCTAssertTrue(FormatDetector.isSTL(inSlice(text("solid a\nfacet normal 0 0 1\n"), fill: 0)))
        XCTAssertTrue(FormatDetector.isOBJ(inSlice(OBJ, fill: 0xff).dropFirst(0)))
    }
    func testSliceOfSliceKeepsLength() {
        let stl = inSlice(binaryStl(5))
        XCTAssertEqual(detect(stl.dropFirst(0), ""), .stl)
        XCTAssertNotEqual(detect(stl.dropLast(1), ""), .stl)
    }
    func testFormatRawValuesMatchTheTypeScriptStrings() {
        XCTAssertEqual(Set(Format.allCases.map(\.rawValue)),
                       ["blend", "stl", "usd", "3mf", "ply", "dae", "3ds", "gltf-json", "obj", "fbx", "gltf"])
    }
    func testSourceTopologyAddFaceAndLabel() {
        var t = SourceTopology()
        XCTAssertEqual(t.label, "–")
        t.addFace(corners: 2)  // degenerate, ignored
        XCTAssertEqual(t.faces, 0)
        XCTAssertEqual(t.polygons, [])
        t.addFace(corners: 3)
        XCTAssertEqual(t.label, "Triangle")
        t.addFace(corners: 4)
        t.addFace(corners: 7)
        XCTAssertEqual(t.label, "Mixed")
        XCTAssertEqual(t, SourceTopology(faces: 3, vertices: 0, triangles: 1, quads: 1, ngons: 1, polygons: [[3, 4, 7]]))
    }
}
