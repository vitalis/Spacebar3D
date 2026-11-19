import Compression
import Foundation
import ImportBlend
import XCTest

/// Headers and wrappers the fixture does not use.
final class BlendGapsTests: XCTestCase {
    func testOversizedDNADimensionsAreRejectedBeforeMultiplication() {
        let builder = BlendBuilder()
        builder.define("Probe", [("float", "co[2][2]")])
        for name in ["co[9223372036854775807][2]", "co[999999999999999999999999][2]", "co[16777216][2]", "co[-1][2]"] {
            XCTAssertThrowsError(try BlendReader.scene(from: builder.build(fieldNames: ["co[2][2]": name]))) {
                XCTAssertEqual($0 as? BlendReader.Failure, .damaged)
            }
        }
    }

    func testAFileWithFourBytePointersAndNothingInItIsRefusedCleanly() {
        // "BLENDER_v300", then the end block alone.
        var data = Data("BLENDER_v300".utf8)
        data += Data("ENDB".utf8) + Data(count: 16)
        data += Data(count: 16)
        XCTAssertThrowsError(try BlendReader.scene(from: data))
    }

    func testAGzipHeaderWithAnExtraFieldIsStepped() throws {
        let plain = BlendFixture.make(.records)
        let capacity = plain.count + 4096
        var packed = Data(count: capacity)
        let written = packed.withUnsafeMutableBytes { out in plain.withUnsafeBytes { source in
            compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity, source.bindMemory(to: UInt8.self).baseAddress!, plain.count, nil, COMPRESSION_ZLIB)
        } }
        // Flag 4: two bytes of length, then that many bytes.
        let gzip = Data([0x1f, 0x8b, 8, 4, 0, 0, 0, 0, 0, 3, 3, 0, 1, 2, 3]) + packed.prefix(written) + Data(count: 8)
        XCTAssertEqual(try BlendReader.scene(from: gzip).topology.faces, 6)
        // An extra field that is cut off.
        XCTAssertThrowsError(try BlendReader.scene(from: Data([0x1f, 0x8b, 8, 4, 0, 0, 0, 0, 0, 3, 3])))
    }
}
