import Foundation
import ModelCore
import XCTest

/// Corners of the format check, the token scanner and the folder of files beside a model.
final class CoreGapsTests: XCTestCase {
    private func glb(_ json: String) -> Data {
        var text = Data(json.utf8)
        while text.count % 4 != 0 { text.append(0x20) }
        func le(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        return Data("glTF".utf8) + le(2) + le(20 + text.count) + le(text.count) + Data("JSON".utf8) + text
    }

    func testAnAvatarIsRecognisedInTheTextFormAndInTheBinaryContainer() {
        let vrm1 = "{\"asset\": {\"version\": \"2.0\"}, \"extensions\": {\"VRMC_vrm\": {}}}"
        let vrm0 = "{\"asset\": {\"version\": \"2.0\"}, \"extensions\": {\"VRM\": {}}}"
        let animation = "{\"asset\": {\"version\": \"2.0\"}, \"extensions\": {\"VRMC_vrm_animation\": {}}}"
        let plain = "{\"asset\": {\"version\": \"2.0\"}}"
        for form in [{ (s: String) in Data(s.utf8) }, glb] {
            XCTAssertTrue(FormatDetector.isVRM(form(vrm1)))
            XCTAssertTrue(FormatDetector.isVRM(form(vrm0)))
            XCTAssertTrue(FormatDetector.isVRM(form(animation)))
            XCTAssertFalse(FormatDetector.isVRM(form(plain)))
            XCTAssertTrue(FormatDetector.isVRMAnimation(form(animation)))
            XCTAssertFalse(FormatDetector.isVRMAnimation(form(vrm1)))
        }
        XCTAssertFalse(FormatDetector.isVRM(Data()))
    }

    func testABinaryContainerWithAnImpossibleDescriptionLengthIsNotAnAvatar() {
        var damaged = glb("{\"VRM\": 1}")
        // The first chunk claims more bytes than the file has.
        damaged.replaceSubrange(12..<16, with: [0xff, 0xff, 0x00, 0x00])
        XCTAssertFalse(FormatDetector.isVRM(damaged))
        // A length of nothing.
        damaged.replaceSubrange(12..<16, with: [0, 0, 0, 0])
        XCTAssertFalse(FormatDetector.isVRM(damaged))
    }

    func testLineTokensAlwaysAdvanceAcrossControlWhitespace() {
        let bytes = Array("\u{000B}alpha\u{000C}\t beta\r\nnext".utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var scanner = ByteScanner(buffer)
            var words: [String] = []
            // Bounded even if a future regression returns the same empty token forever.
            for _ in 0..<bytes.count {
                let before = scanner.at
                guard let token = scanner.tokenOnLine() else { break }
                XCTAssertGreaterThan(scanner.at, before)
                XCTAssertFalse(token.isEmpty)
                words.append(scanner.string(token))
            }
            XCTAssertEqual(words, ["alpha", "beta"])
            XCTAssertEqual(bytes[scanner.at], 0x0a)
            scanner.skipLine()
            XCTAssertEqual(scanner.tokenOnLine().map(scanner.string), "next")
        }
    }

    func testAScannerHandsOutTokensAsText() {
        let bytes = Array("alpha  beta\ngamma".utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var scanner = ByteScanner(buffer)
            let first = scanner.token()!, second = scanner.token()!
            XCTAssertEqual(scanner.string(first), "alpha")
            XCTAssertEqual(scanner.string(second), "beta")
            XCTAssertEqual(scanner.string(scanner.token()!), "gamma")
            XCTAssertNil(scanner.token())
            XCTAssertTrue(scanner.isAtEnd)
        }
    }

    func testALinkOutOfTheFolderIsNotFollowedForAFileOfAnotherName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-core-\(UUID().uuidString)").resolvingSymlinksInPath()
        let inside = base.appendingPathComponent("inside"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("hidden.png"))
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("wood.png"), withDestinationURL: outside.appendingPathComponent("hidden.png"))
        let source = SidecarFolder(modelURL: inside.appendingPathComponent("ship.obj"))
        XCTAssertNil(source.data(named: "wood.png"))
    }

    func testALinkWithTheModelsOwnNameDoesNotLeadOutOfTheFolderEither() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-core-\(UUID().uuidString)").resolvingSymlinksInPath()
        let inside = base.appendingPathComponent("inside"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("newmtl a\n".utf8).write(to: outside.appendingPathComponent("elsewhere.mtl"))
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("ship.mtl"), withDestinationURL: outside.appendingPathComponent("elsewhere.mtl"))
        let source = SidecarFolder(modelURL: inside.appendingPathComponent("ship.obj"))
        // The file with the model's own name is read in a second way (for the sandbox); that
        // way keeps to the folder too.
        XCTAssertNil(source.data(named: "ship.mtl"))
        XCTAssertNil(source.data(named: "ship.mtl"), "and is not found the second time either")
        // The same name as a real file in the folder is read.
        try FileManager.default.removeItem(at: inside.appendingPathComponent("ship.mtl"))
        try Data("newmtl here\n".utf8).write(to: inside.appendingPathComponent("ship.mtl"))
        XCTAssertEqual(SidecarFolder(modelURL: inside.appendingPathComponent("ship.obj")).data(named: "ship.mtl"), Data("newmtl here\n".utf8))
    }
}
