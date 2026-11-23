import XCTest

/// Only side-effect-free surface of ViewerSettings is covered: `save`/`load` use the static
/// `fileURL` in the App Group container, so they are deliberately NOT called. `json()` reads that
/// file (never writes); assertions below hold whatever it contains.
final class ViewerSettingsTests: XCTestCase {
    /// The menu offers every look once, the default among them.
    func testTheLookMenuOffersEveryLookOnce() {
        let offered = ViewerSettings.lookGroups.flatMap { $0.map(\.mode) }
        XCTAssertEqual(offered.sorted(), ViewerSettings.shadingModes.sorted())
        let names = ViewerSettings.lookGroups.flatMap { $0.map(\.name) }
        XCTAssertEqual(Set(names).count, names.count)
        for name in names { XCTAssertFalse(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        XCTAssertEqual(ViewerSettings.lookGroups.count, 3, "views, wireframe, styles")
    }

    private let expectedKeys = [
        "defaultShading", "showGrid", "autoRotate", "autoplay", "backgroundColor", "lightIntensity",
        "solidColor", "repeatAnimations",
    ]

    private func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    private func isNumber(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false }

    func testKeyRawValuesAreTheRendererNames() {
        XCTAssertEqual(ViewerSettings.Key.allCases.map(\.rawValue), expectedKeys)
    }

    @MainActor func testRepeatReachesTheNativeViewer() {
        var values = ViewerSettings.defaults
        XCTAssertFalse(ViewerFactory.nativeSettings(from: values).repeatAnimations, "once, unless chosen")
        values["repeatAnimations"] = true
        XCTAssertTrue(ViewerFactory.nativeSettings(from: values).repeatAnimations)
        XCTAssertEqual(ViewerSettings.normalize(["repeatAnimations": true])["repeatAnimations"] as? Bool, true)
    }

    func testDefaultsCoverExactlyTheKeys() {
        XCTAssertEqual(Set(ViewerSettings.defaults.keys), Set(expectedKeys))
        XCTAssertEqual(ViewerSettings.defaults.count, ViewerSettings.Key.allCases.count)
    }

    func testDefaultValues() {
        let d = ViewerSettings.defaults
        XCTAssertEqual(d["defaultShading"] as? String, "original")
        XCTAssertEqual(d["backgroundColor"] as? String, "#07110c")
        XCTAssertEqual(d["solidColor"] as? String, "#b4b4b8")
        XCTAssertEqual(d["lightIntensity"] as? Double, 1.0)
        XCTAssertEqual(d["autoRotate"] as? Bool, false)
        XCTAssertEqual(d["repeatAnimations"] as? Bool, false)
        for key in expectedKeys where key.hasPrefix("show") || key == "autoplay" {
            XCTAssertEqual(d[key] as? Bool, true, key)
        }
    }

    func testDefaultTypesMatchWhatLoadSwitchesOn() {
        for (key, value) in ViewerSettings.defaults {
            switch key {
            case "lightIntensity": XCTAssertTrue(value is Double, key); XCTAssertFalse(isBool(value), key)
            case "defaultShading", "backgroundColor", "solidColor": XCTAssertTrue(value is String, key)
            default: XCTAssertTrue(isBool(value), key)
            }
        }
    }

    func testDefaultColoursAreSixDigitHex() {
        for key in ["backgroundColor", "solidColor"] {
            let value = ViewerSettings.defaults[key] as? String ?? ""
            XCTAssertNotNil(value.range(of: "^#[0-9a-f]{6}$", options: .regularExpression), key)
        }
    }

    func testShadingModes() {
        XCTAssertEqual(ViewerSettings.shadingModes,
                       ["original", "wireframe", "clay", "normals", "unlit", "anime", "celShaded", "retro", "voxel", "hologram"])
        XCTAssertEqual(Set(ViewerSettings.shadingModes).count, ViewerSettings.shadingModes.count)
        XCTAssertTrue(ViewerSettings.shadingModes.contains(ViewerSettings.defaults["defaultShading"] as? String ?? ""))
    }

    func testDefaultsSerializeBooleansAsJSONBooleans() throws {
        let data = try JSONSerialization.data(withJSONObject: ViewerSettings.defaults, options: .sortedKeys)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"showGrid\":true"))
        XCTAssertTrue(text.contains("\"autoRotate\":false"))
        XCTAssertTrue(text.contains("\"lightIntensity\":1"))
    }

    func testFileURLIsInTheAppGroupContainer() throws {
        let url = try XCTUnwrap(ViewerSettings.fileURL)  // read-only access to the constant
        XCTAssertEqual(url.lastPathComponent, "viewer-settings.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ViewerSettings.appGroup)
        XCTAssertFalse(url.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))
    }

    /// The group in the Swift constant is the one both targets are entitled to, and neither
    /// target carries a temporary sandbox exception (the App Store does not accept them).
    func testEntitlementsMatchTheAppGroupAndHaveNoExceptions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Spacebar3D/App/Spacebar3D.entitlements", "Spacebar3D/Extension/Spacebar3DExtension.entitlements"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
            XCTAssertEqual(plist["com.apple.security.application-groups"] as? [String], [ViewerSettings.appGroup], path)
            XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, path)
            XCTAssertTrue(plist.keys.allSatisfy { !$0.contains("temporary-exception") }, path)
            // Nothing here talks to the network (the web view that needed a network process is gone).
            XCTAssertTrue(plist.keys.allSatisfy { !$0.contains("network") }, path)
        }
        XCTAssertTrue(ViewerSettings.appGroup.hasSuffix(".com.vitalis.Spacebar3D"))
    }

    func testLoadAlwaysReturnsAllKeysAndNoUnknownOnes() {
        // Reads the real file (read-only); holds for any file content.
        let loaded = ViewerSettings.load()
        XCTAssertEqual(Set(loaded.keys), Set(expectedKeys))
    }
}
