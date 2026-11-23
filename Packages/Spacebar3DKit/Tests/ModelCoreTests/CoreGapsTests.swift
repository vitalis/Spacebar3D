import Foundation
import ModelCore
import simd
import XCTest

/// Corners of the format check, the token scanner and the folder of files beside a model.
final class CoreGapsTests: XCTestCase {
    private func glb(_ json: String) -> Data {
        var text = Data(json.utf8)
        while text.count % 4 != 0 { text.append(0x20) }
        func le(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        return Data("glTF".utf8) + le(2) + le(20 + text.count) + le(text.count) + Data("JSON".utf8) + text
    }
    /// A coordinate a file gives as infinite, or as no number at all, is no part of the
    /// model's size: the box is round what can be drawn. One such corner used to leave the
    /// box without an end, and the view with nothing in it.
    func testACoordinateThatIsNoPlaceIsLeftOutOfTheBounds() throws {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 2, 0), SIMD3(0, .infinity, 0), SIMD3(.nan, 0, 3), SIMD3(-.infinity, 0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 1, 3, 0, 1, 4, 1, 2, 5]
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        let bounds = try XCTUnwrap(scene.bounds)
        XCTAssertEqual(bounds.min, SIMD3(0, 0, 0))
        XCTAssertEqual(bounds.max, SIMD3(1, 2, 0))
        // With nothing but such corners there is nothing to frame.
        scene.meshes[0].parts[0].positions = [SIMD3(.infinity, 0, 0), SIMD3(0, .nan, 0), SIMD3(0, 0, -.infinity)]
        scene.meshes[0].parts[0].triangleIndices = [0, 1, 2]
        XCTAssertNil(scene.bounds)
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

    /// A scene far from the origin is brought there by its roots alone: a node under a
    /// root goes with it and is not moved a second time. A scene that is merely large, or
    /// a little way off, is left where its file put it.
    func testASceneFarOffIsMovedByItsRootsAndANearOneIsLeft() throws {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        part.triangleIndices = [0, 1, 2]
        var away = matrix_identity_float4x4, beside = matrix_identity_float4x4
        away.columns.3 = SIMD4(8_388_608, 0, 0, 1)
        beside.columns.3 = SIMD4(0, 0, 2, 1)
        var scene = ModelScene()
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(transform: away, mesh: 0), ModelScene.Node(parent: 0, transform: beside, mesh: 0)]

        let moved = scene.movedNearTheOrigin()
        let bounds = try XCTUnwrap(moved.bounds)
        XCTAssertEqual(bounds.min, SIMD3(-0.5, -0.5, -1))
        XCTAssertEqual(bounds.max, SIMD3(0.5, 0.5, 1))
        XCTAssertEqual(moved.nodes[1].transform, beside)

        // A hundred and fifty units off and two across: a Float holds that to a millionth.
        scene.nodes[0].transform.columns.3 = SIMD4(150, 0, 0, 1)
        XCTAssertEqual(scene.movedNearTheOrigin().nodes[0].transform, scene.nodes[0].transform)
        XCTAssertNil(ModelScene().movedNearTheOrigin().bounds)
    }

    /// A number is read with a point for its decimal mark however the computer itself writes
    /// numbers, and a file written with a comma there ("1,5", as some tools write where a
    /// comma is the custom) is read as it was meant, not as 1.
    func testNumbersAreReadTheSameEverywhereAndWithACommaForThePoint() throws {
        func number(_ text: String) -> Double? {
            Array(text.utf8).withUnsafeBufferPointer { buffer in
                var scanner = ByteScanner(buffer)
                return scanner.token().flatMap { scanner.number($0) }
            }
        }
        XCTAssertEqual(number("1.5"), 1.5)
        XCTAssertEqual(number("1,5"), 1.5)
        XCTAssertEqual(number("-0,25"), -0.25)
        XCTAssertEqual(number("1,5e3"), 1500)
        // More than one comma is a list, not a number with a decimal mark: read as it was.
        XCTAssertEqual(number("1,5,2"), 1)
        XCTAssertEqual(number("1,"), 1)
        XCTAssertEqual(number("1.5,2"), 1.5)
        XCTAssertNil(number(",5"))
        XCTAssertNil(number("abc"))
        // Where the computer's own decimal mark is a comma.
        let was = setlocale(LC_NUMERIC, nil).map { String(cString: $0) }
        defer { setlocale(LC_NUMERIC, was) }
        try XCTSkipIf(setlocale(LC_NUMERIC, "de_DE.UTF-8") == nil, "no such locale on this computer")
        XCTAssertEqual(strtod("1,5", nil), 1.5, "the locale is in force")
        XCTAssertEqual(number("1.5"), 1.5)
        XCTAssertEqual(number("2.75e2"), 275)
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
