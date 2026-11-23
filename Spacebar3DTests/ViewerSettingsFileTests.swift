import XCTest

/// Exercises ViewerSettings through its injectable URL / pure `normalize`. Every file lives in a
/// temp dir; the real settings file is never passed, and `save` is never called without `to:`.
final class ViewerSettingsFileTests: TempDirTestCase {
    private var file: URL { modelDir.appendingPathComponent("viewer-settings.json") }
    private var d: [String: Any] { ViewerSettings.defaults }

    private func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    private func writeJSON(_ text: String) throws { try Data(text.utf8).write(to: file) }
    private func assertEqualToDefaults(_ values: [String: Any], _ msg: String = "", line: UInt = #line) {
        XCTAssertEqual(NSDictionary(dictionary: values), NSDictionary(dictionary: d), msg, line: line)
    }

    // MARK: normalize: types

    func testNormalizeEmptyGivesDefaults() { assertEqualToDefaults(ViewerSettings.normalize([:])) }

    func testNormalizeValidValuesOfEachKind() {
        let out = ViewerSettings.normalize(["showGrid": false, "lightIntensity": 2.5, "backgroundColor": "#000000", "defaultShading": "clay"])
        XCTAssertEqual(out["showGrid"] as? Bool, false)
        XCTAssertEqual(out["lightIntensity"] as? Double, 2.5)
        XCTAssertEqual(out["backgroundColor"] as? String, "#000000")
        XCTAssertEqual(out["defaultShading"] as? String, "clay")
        XCTAssertEqual(out.count, d.count)
    }

    func testNormalizeBoolKeysRejectWrongTypes() {
        let bad: [Any] = [1, 0, 1.0, "true", "false", NSNull(), [true], ["a": true], 2.5]
        for v in bad {
            let out = ViewerSettings.normalize(["showGrid": v, "autoRotate": v])
            XCTAssertEqual(out["showGrid"] as? Bool, true, "\(v)")
            XCTAssertEqual(out["autoRotate"] as? Bool, false, "\(v)")
        }
    }

    func testNormalizeNumberKeyRejectsWrongTypes() {
        let bad: [Any] = [true, false, "2", "abc", NSNull(), [1], ["a": 1]]
        for v in bad { XCTAssertEqual(ViewerSettings.normalize(["lightIntensity": v])["lightIntensity"] as? Double, 1.0, "\(v)") }
    }

    func testNormalizeStringKeysRejectWrongTypes() {
        let bad: [Any] = [1, 1.5, true, NSNull(), ["#fff"], ["a": "b"]]
        for v in bad {
            let out = ViewerSettings.normalize(["backgroundColor": v, "solidColor": v, "defaultShading": v])
            XCTAssertEqual(out["backgroundColor"] as? String, "#07110c", "\(v)")
            XCTAssertEqual(out["solidColor"] as? String, "#b4b4b8", "\(v)")
            XCTAssertEqual(out["defaultShading"] as? String, "original", "\(v)")
        }
    }

    func testNormalizeIntegerIsAcceptedAsNumber() {
        XCTAssertEqual(ViewerSettings.normalize(["lightIntensity": 3])["lightIntensity"] as? Double, 3.0)
    }

    func testNormalizeResultTypesStayBoolAndDouble() {
        let out = ViewerSettings.normalize(["showGrid": false, "lightIntensity": 3])
        XCTAssertTrue(isBool(out["showGrid"]))
        XCTAssertFalse(isBool(out["lightIntensity"]))
    }

    func testNormalizeDropsUnknownKeys() {
        let out = ViewerSettings.normalize(["bogus": 1, "__proto__": "x", "ShowGrid": false, "showgrid": false, "showGrid ": false])
        assertEqualToDefaults(out)
    }

    func testNormalizeOneBadValueDoesNotAffectOthers() {
        let out = ViewerSettings.normalize(["showGrid": "yes", "autoRotate": true, "lightIntensity": "x", "solidColor": "#FFF000"])
        XCTAssertEqual(out["showGrid"] as? Bool, true)
        XCTAssertEqual(out["autoRotate"] as? Bool, true)
        XCTAssertEqual(out["lightIntensity"] as? Double, 1.0)
        XCTAssertEqual(out["solidColor"] as? String, "#fff000")
    }

    // MARK: bool vs number bridging through real JSON (the CFBoolean check)

    func testJSONNumbersAreNotBools() throws {
        try writeJSON(#"{"showGrid":1,"autoRotate":1,"autoplay":0,"repeatAnimations":1.0}"#)
        let out = ViewerSettings.load(from: file)
        XCTAssertEqual(out["showGrid"] as? Bool, true)     // default, not the 1
        XCTAssertEqual(out["autoRotate"] as? Bool, false)  // default, NOT true
        XCTAssertEqual(out["autoplay"] as? Bool, true)     // default, NOT false
        XCTAssertEqual(out["repeatAnimations"] as? Bool, false)
    }

    func testJSONBoolsAreNotNumbers() throws {
        try writeJSON(#"{"lightIntensity":true}"#)
        XCTAssertEqual(ViewerSettings.load(from: file)["lightIntensity"] as? Double, 1.0)
        try writeJSON(#"{"lightIntensity":false}"#)
        XCTAssertEqual(ViewerSettings.load(from: file)["lightIntensity"] as? Double, 1.0)
    }

    func testJSONBoolsAndNumbersAcceptedOnTheirOwnKeys() throws {
        try writeJSON(#"{"autoRotate":true,"showGrid":false,"lightIntensity":0.5}"#)
        let out = ViewerSettings.load(from: file)
        XCTAssertEqual(out["autoRotate"] as? Bool, true)
        XCTAssertEqual(out["showGrid"] as? Bool, false)
        XCTAssertEqual(out["lightIntensity"] as? Double, 0.5)
        XCTAssertFalse(isBool(out["lightIntensity"]))
    }

    // MARK: legacy looks

    func testLegacyLookMapping() {
        let map = ["textured": "original", "smooth": "clay", "flat": "clay", "chrome": "original", "custom": "original"]
        for (old, new) in map {
            XCTAssertEqual(ViewerSettings.normalize(["defaultShading": old])["defaultShading"] as? String, new, old)
        }
    }

    func testLegacyMappingOnlyAppliesToDefaultShading() {
        // Legacy names are not looks for the colour keys, and are not colours either.
        let out = ViewerSettings.normalize(["backgroundColor": "smooth", "solidColor": "flat"])
        XCTAssertEqual(out["backgroundColor"] as? String, "#07110c")
        XCTAssertEqual(out["solidColor"] as? String, "#b4b4b8")
    }

    func testCurrentLooksPassThroughUnchanged() {
        for mode in ViewerSettings.shadingModes {
            XCTAssertEqual(ViewerSettings.normalize(["defaultShading": mode])["defaultShading"] as? String, mode)
        }
    }

    func testLegacyMappingIsCaseSensitive() {
        // Not mapped, and not a known look either: the default stays.
        XCTAssertEqual(ViewerSettings.normalize(["defaultShading": "Smooth"])["defaultShading"] as? String, "original")
    }

    // MARK: Value validation

    func testUnknownShadingModeKeepsDefault() {
        for v in ["not-a-look", "", "Original", "CLAY", " clay", "clay ", "clay\n", "constructor", "__proto__", "toString", "モデル"] {
            XCTAssertEqual(ViewerSettings.normalize(["defaultShading": v])["defaultShading"] as? String, "original", v.debugDescription)
        }
    }

    func testShadingModeDefaultStaysWhenInvalidEvenIfDefaultIsNotOriginal() {
        // The fallback is the default, not the previous stored value.
        XCTAssertEqual(ViewerSettings.normalize(["defaultShading": "bogus"])["defaultShading"] as? String, ViewerSettings.defaults["defaultShading"] as? String)
    }

    /// A file written by an earlier version holds that version's default background; it was
    /// never chosen, so it follows the default. Any other colour is the user's and stays.
    func testTheEarlierDefaultBackgroundFollowsTheDefault() {
        XCTAssertEqual(ViewerSettings.defaults["backgroundColor"] as? String, "#07110c")
        XCTAssertEqual(ViewerSettings.normalize(["backgroundColor": "#1c1c1e"])["backgroundColor"] as? String, "#07110c")
        XCTAssertEqual(ViewerSettings.normalize(["backgroundColor": "#1C1C1E"])["backgroundColor"] as? String, "#07110c")
        XCTAssertEqual(ViewerSettings.normalize(["backgroundColor": "#1c1c1f"])["backgroundColor"] as? String, "#1c1c1f")
        XCTAssertEqual(ViewerSettings.normalize(["solidColor": "#1c1c1e"])["solidColor"] as? String, "#1c1c1e", "only the background")
    }

    func testHexColorAccepted() {
        for c in ["#000000", "#ffffff", "#FFFFFF", "#1c1c1e", "#AbCdEf", "#0a9F3b"] {
            XCTAssertTrue(ViewerSettings.isHexColor(c), c)
        }
    }

    func testHexColorRejected() {
        let bad = ["", "#", "#fff", "#ffff", "#fffff", "#fffffff", "#ffffffff", "ffffff", "1c1c1e", "red", "#gggggg", "#12345g",
                   "#１２３４５６", "#ffffff ", " #ffffff", "#ffffff\n", "#ff ff", "##ffffff", "#ffffé", "rgb(0,0,0)",
                   "url(javascript:alert(1))", "#1c1c1e; x", "0x1c1c1e", "#ffff\u{0}f"]
        for c in bad { XCTAssertFalse(ViewerSettings.isHexColor(c), c.debugDescription) }
    }

    func testColoursAreStoredLowercased() {
        let out = ViewerSettings.normalize(["backgroundColor": "#ABCDEF", "solidColor": "#A1B2C3"])
        XCTAssertEqual(out["backgroundColor"] as? String, "#abcdef")
        XCTAssertEqual(out["solidColor"] as? String, "#a1b2c3")
    }

    func testMalformedColoursKeepDefaults() {
        for c in ["red", "#12", "#fff", "#ffffffff", "ffffff", "#gggggg", "", "url(javascript:alert(1))", "#1c1c1e; x", "#１２３４５６", "#ffffff\n"] {
            let out = ViewerSettings.normalize(["backgroundColor": c, "solidColor": c])
            XCTAssertEqual(out["backgroundColor"] as? String, "#07110c", c.debugDescription)
            XCTAssertEqual(out["solidColor"] as? String, "#b4b4b8", c.debugDescription)
        }
    }

    func testOneColourInvalidDoesNotAffectTheOther() {
        let out = ViewerSettings.normalize(["backgroundColor": "nope", "solidColor": "#00FF00"])
        XCTAssertEqual(out["backgroundColor"] as? String, "#07110c")
        XCTAssertEqual(out["solidColor"] as? String, "#00ff00")
    }

    func testLightIntensityRangeIsPointOneToThree() {
        XCTAssertEqual(ViewerSettings.lightIntensityRange, 0.1...3.0)
    }

    func testLightIntensityInRangeIsKeptAndBoundsAreInclusive() {
        let r = ViewerSettings.lightIntensityRange
        for v in [r.lowerBound, 0.5, 1, 2.999, r.upperBound] {
            XCTAssertEqual(ViewerSettings.normalize(["lightIntensity": v])["lightIntensity"] as? Double, v, "\(v)")
        }
    }

    func testLightIntensityIsClampedToRange() {
        let r = ViewerSettings.lightIntensityRange
        for v in [0.0, -1, -1e300, 0.0999, 0.05, 1e-300] {
            XCTAssertEqual(ViewerSettings.normalize(["lightIntensity": v])["lightIntensity"] as? Double, r.lowerBound, "\(v)")
        }
        for v in [3.0001, 4, 99999, 1e300, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(ViewerSettings.normalize(["lightIntensity": v])["lightIntensity"] as? Double, r.upperBound, "\(v)")
        }
    }

    func testNonFiniteLightIntensityKeepsDefault() {
        for v in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(ViewerSettings.normalize(["lightIntensity": NSNumber(value: v)])["lightIntensity"] as? Double, 1.0, "\(v)")
        }
    }

    func testLightIntensityThroughJSONIsClamped() throws {
        try writeJSON(#"{"lightIntensity":100}"#)
        XCTAssertEqual(ViewerSettings.load(from: file)["lightIntensity"] as? Double, 3.0)
        try writeJSON(#"{"lightIntensity":-2}"#)
        XCTAssertEqual(ViewerSettings.load(from: file)["lightIntensity"] as? Double, 0.1)
        try writeJSON(#"{"lightIntensity":1e999}"#)  // overflows: either parse failure (defaults) or clamp, never a non-finite value
        let v = try XCTUnwrap(ViewerSettings.load(from: file)["lightIntensity"] as? Double)
        XCTAssertTrue(v.isFinite && ViewerSettings.lightIntensityRange.contains(v), "\(v)")
    }

    func testBoolKeysAreNotSubjectToValueValidation() {
        let out = ViewerSettings.normalize(["showGrid": false, "autoRotate": true])
        XCTAssertEqual(out["showGrid"] as? Bool, false)
        XCTAssertEqual(out["autoRotate"] as? Bool, true)
    }

    func testEveryNormalizedOutputIsValidWhateverTheInput() {
        let junk: [Any] = ["x", "#zzzzzz", 1e9, -1e9, true, NSNull(), "", [1], ["a": 1], "textured", "#ABCDEF"]
        for a in junk { for b in junk {
            let out = ViewerSettings.normalize(["defaultShading": a, "backgroundColor": b, "solidColor": a, "lightIntensity": b])
            XCTAssertTrue(ViewerSettings.shadingModes.contains(out["defaultShading"] as? String ?? ""))
            for k in ["backgroundColor", "solidColor"] {
                let c = out[k] as? String ?? ""
                XCTAssertTrue(ViewerSettings.isHexColor(c) && c == c.lowercased(), "\(k)=\(c)")
            }
            let v = out["lightIntensity"] as? Double ?? .nan
            XCTAssertTrue(ViewerSettings.lightIntensityRange.contains(v))
        } }
    }

    func testHugeStringsKeepDefaults() {
        let big = String(repeating: "a", count: 50_000)
        let out = ViewerSettings.normalize(["solidColor": big, "defaultShading": big])
        XCTAssertEqual(out["solidColor"] as? String, "#b4b4b8")
        XCTAssertEqual(out["defaultShading"] as? String, "original")
    }

    // MARK: load(from:)

    func testLoadMissingFileGivesDefaults() { assertEqualToDefaults(ViewerSettings.load(from: file)) }
    func testLoadNilGivesDefaults() { assertEqualToDefaults(ViewerSettings.load(from: nil)) }
    func testLoadDirectoryGivesDefaults() { assertEqualToDefaults(ViewerSettings.load(from: modelDir)) }

    func testLoadDamagedAndNonObjectFilesGiveDefaults() throws {
        for text in ["", "{", "not json", "[]", "[1,2]", "null", "true", "42", "\"str\"", "{\"showGrid\":", "\u{FEFF}{}x"] {
            try writeJSON(text)
            assertEqualToDefaults(ViewerSettings.load(from: file), text)
        }
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: file)
        assertEqualToDefaults(ViewerSettings.load(from: file), "binary")
    }

    func testLoadEmptyObjectGivesDefaults() throws {
        try writeJSON("{}")
        assertEqualToDefaults(ViewerSettings.load(from: file))
    }

    func testLoadMergesStoredOverDefaultsAndDropsUnknown() throws {
        try writeJSON(#"{"showGrid":false,"unknown":1,"defaultShading":"flat"}"#)
        let out = ViewerSettings.load(from: file)
        XCTAssertEqual(out["showGrid"] as? Bool, false)
        XCTAssertEqual(out["defaultShading"] as? String, "clay")
        XCTAssertNil(out["unknown"])
        XCTAssertEqual(out.count, d.count)
    }

    func testLoadFollowsSymlinkedFile() throws {
        let real = try put("real.json", in: outsideDir, bytes: Data(#"{"autoRotate":true}"#.utf8))
        let link = modelDir.appendingPathComponent("link.json")
        try symlink(link, to: real)
        XCTAssertEqual(ViewerSettings.load(from: link)["autoRotate"] as? Bool, true)
    }

    // MARK: size cap (load reads only files with size < maxFileBytes)

    func testMaxFileBytesIs64KiB() { XCTAssertEqual(ViewerSettings.maxFileBytes, 64 * 1024) }

    /// A valid JSON object of exactly `size` bytes that sets autoRotate to true (padding in a string value).
    private func objectFile(size: Int) throws {
        let prefix = #"{"autoRotate":true,"pad":""#, suffix = #""}"#
        let pad = String(repeating: "p", count: size - prefix.utf8.count - suffix.utf8.count)
        let text = prefix + pad + suffix
        XCTAssertEqual(text.utf8.count, size)
        try writeJSON(text)
    }

    func testFileJustUnderCapIsRead() throws {
        try objectFile(size: ViewerSettings.maxFileBytes - 1)
        XCTAssertEqual(ViewerSettings.load(from: file)["autoRotate"] as? Bool, true)
    }

    func testFileExactlyAtCapIsTreatedAsDamaged() throws {
        // Pins `data.count < maxFileBytes`: the cap itself is rejected.
        try objectFile(size: ViewerSettings.maxFileBytes)
        assertEqualToDefaults(ViewerSettings.load(from: file))
    }

    func testFileOverCapIsTreatedAsDamaged() throws {
        try objectFile(size: ViewerSettings.maxFileBytes + 1)
        assertEqualToDefaults(ViewerSettings.load(from: file))
    }

    // MARK: save(_:to:)

    func testSaveToNilReturnsFalse() { XCTAssertFalse(ViewerSettings.save(["showGrid": false], to: nil)) }

    func testSaveCreatesMissingIntermediateFolders() {
        let nested = root.appendingPathComponent("a/b/c/settings.json")
        XCTAssertTrue(ViewerSettings.save([:], to: nested))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testSaveFillsDefaultsForMissingKeys() throws {
        XCTAssertTrue(ViewerSettings.save(["showGrid": false], to: file))
        let stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(stored.keys), Set(d.keys))
        XCTAssertEqual(stored["showGrid"] as? Bool, false)
        XCTAssertEqual(stored["autoplay"] as? Bool, true)
        XCTAssertEqual(stored["backgroundColor"] as? String, "#07110c")
    }

    func testSaveDropsUnknownKeys() throws {
        XCTAssertTrue(ViewerSettings.save(["bogus": 1, "showGrid": false], to: file))
        let stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(stored["bogus"])
    }

    func testSaveWritesBooleansAsJSONBooleans() throws {
        XCTAssertTrue(ViewerSettings.save(["autoRotate": true, "showGrid": false], to: file))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(#""autoRotate" : true"#), text)
        XCTAssertTrue(text.contains(#""showGrid" : false"#), text)
    }

    func testSaveOverwritesExistingFile() throws {
        XCTAssertTrue(ViewerSettings.save(["showGrid": false], to: file))
        XCTAssertTrue(ViewerSettings.save(["autoRotate": true], to: file))
        let out = ViewerSettings.load(from: file)
        XCTAssertEqual(out["autoRotate"] as? Bool, true)
        XCTAssertEqual(out["showGrid"] as? Bool, true)  // second save reset it to default
    }

    func testSaveFailsWhenParentIsAFile() throws {
        let blocker = try put("blocker", bytes: Data("x".utf8))
        XCTAssertFalse(ViewerSettings.save([:], to: blocker.appendingPathComponent("s.json")))
    }

    /// Values JSON cannot hold (a Date, NaN, a custom object) used to reach JSONSerialization,
    /// which raises an Objective-C exception Swift cannot catch. `save` now writes only
    /// normalized values, so such a value is replaced by the default and the save succeeds.
    func testSaveReplacesNonJSONValuesWithDefaults() {
        XCTAssertTrue(ViewerSettings.save(["backgroundColor": Date(), "lightIntensity": Double.nan, "showGrid": NSObject()], to: file))
        let loaded = ViewerSettings.load(from: file)
        XCTAssertEqual(loaded["backgroundColor"] as? String, ViewerSettings.defaults["backgroundColor"] as? String)
        XCTAssertEqual(loaded["lightIntensity"] as? Double, ViewerSettings.defaults["lightIntensity"] as? Double)
        XCTAssertEqual(loaded["showGrid"] as? Bool, ViewerSettings.defaults["showGrid"] as? Bool)
    }

    func testRoundTrip() throws {
        let values: [String: Any] = [
            "defaultShading": "hologram", "showGrid": false, "autoRotate": true, "autoplay": false,
            "backgroundColor": "#123456", "lightIntensity": 1.75, "solidColor": "#abcdef",
            "repeatAnimations": true,
        ]
        XCTAssertEqual(Set(values.keys), Set(d.keys))
        XCTAssertTrue(ViewerSettings.save(values, to: file))
        XCTAssertEqual(NSDictionary(dictionary: ViewerSettings.load(from: file)), NSDictionary(dictionary: values))
    }

    func testRoundTripOfDefaults() {
        XCTAssertTrue(ViewerSettings.save(d, to: file))
        assertEqualToDefaults(ViewerSettings.load(from: file))
    }

    func testSavedFileIsFarBelowTheReadCap() throws {
        XCTAssertTrue(ViewerSettings.save(d, to: file))
        XCTAssertLessThan(try Data(contentsOf: file).count, ViewerSettings.maxFileBytes / 10)
    }
}
