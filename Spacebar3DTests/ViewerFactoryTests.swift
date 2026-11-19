import ViewerUI
import XCTest

/// How the stored settings become the viewer's. Nothing is read from the settings file here:
/// every dictionary is the test's own.
@MainActor
final class ViewerFactoryTests: XCTestCase {
    /// A settings dictionary with nothing in it, or with values of the wrong kind, still
    /// gives a whole set of settings: the viewer's own defaults.
    func testMissingOrMistypedSettingsFallBackToTheViewersDefaults() {
        let mistyped: [String: Any] = [
            "defaultShading": "no such look", "backgroundColor": 7, "solidColor": false, "lightIntensity": "bright",
            "showGrid": "yes", "autoRotate": 1.5, "repeatAnimations": "no",
        ]
        for values in [[:], mistyped] {
            XCTAssertEqual(ViewerFactory.nativeSettings(from: values), NativeViewerSettings())
        }
        let settings = ViewerFactory.nativeSettings(from: [:])
        XCTAssertEqual(settings.defaultLook, .original)
        XCTAssertEqual(settings.backgroundColor, NativeViewerSettings.defaultBackground)
        XCTAssertEqual(settings.solidColor, NativeViewerSettings.defaultSolid)
        XCTAssertEqual(settings.lightIntensity, 1)
        // Everything shown, nothing moving by itself.
        XCTAssertTrue(settings.showGrid && settings.showGizmo && settings.showStats && settings.autoplay)
        XCTAssertFalse(settings.autoRotate)
        XCTAssertFalse(settings.repeatAnimations)
    }

    /// The app's defaults and the viewer's own are the same settings.
    func testTheAppsDefaultsAreTheViewersDefaults() {
        XCTAssertEqual(ViewerFactory.nativeSettings(from: ViewerSettings.defaults), NativeViewerSettings())
    }

    func testEverySettingReachesTheViewer() {
        var values = ViewerSettings.defaults
        values["defaultShading"] = "celShaded"
        values["backgroundColor"] = "#102030"
        values["solidColor"] = "#a0b0c0"
        values["lightIntensity"] = 1.75
        values["autoRotate"] = true
        values["repeatAnimations"] = true
        let switches = ["showGrid", "autoplay"]
        for key in switches { values[key] = false }
        let expected = NativeViewerSettings(
            defaultLook: .celShaded, backgroundColor: "#102030", solidColor: "#a0b0c0", lightIntensity: 1.75,
            showGrid: false, autoRotate: true, autoplay: false, repeatAnimations: true)
        XCTAssertEqual(ViewerFactory.nativeSettings(from: values), expected)
    }

    /// One switch turned off alone changes one thing in the viewer's settings.
    func testEachSwitchMovesOnlyItsOwnSetting() {
        let usual = NativeViewerSettings()
        let paths: [(String, WritableKeyPath<NativeViewerSettings, Bool>)] = [
            ("showGrid", \.showGrid), ("autoplay", \.autoplay),
            ("autoRotate", \.autoRotate), ("repeatAnimations", \.repeatAnimations),
        ]
        for (key, path) in paths {
            var values = ViewerSettings.defaults
            values[key] = !usual[keyPath: path]
            var expected = usual
            expected[keyPath: path].toggle()
            XCTAssertEqual(ViewerFactory.nativeSettings(from: values), expected, key)
        }
        // Every on-or-off setting is in the list above.
        let onOrOff = ViewerSettings.Key.allCases.filter { ViewerSettings.defaults[$0.rawValue] is Bool }.map(\.rawValue)
        XCTAssertEqual(Set(paths.map(\.0)), Set(onOrOff))
    }

    func testObsoleteVisibilityPreferencesCannotHideControls() {
        let legacy = Dictionary(uniqueKeysWithValues: [
            "showShadingButton", "showFitButton", "showLightButton", "showGridButton",
            "showRotateButton", "showAnimationBar", "showGizmo", "showStats",
        ].map { ($0, false as Any) })
        XCTAssertEqual(ViewerFactory.nativeSettings(from: legacy), NativeViewerSettings())
        XCTAssertEqual(NSDictionary(dictionary: ViewerSettings.normalize(legacy)), NSDictionary(dictionary: ViewerSettings.defaults))
    }

    /// Every look the settings offer is one the viewer knows.
    func testEveryLookOfferedIsOneTheViewerKnows() {
        for mode in ViewerSettings.shadingModes {
            XCTAssertEqual(ViewerFactory.nativeSettings(from: ["defaultShading": mode]).defaultLook.rawValue, mode)
        }
    }

    /// The app and the extension each keep their own grants; every viewer made here is
    /// given the one set.
    func testEveryViewerIsGivenTheSameFolderGrants() throws {
        let viewer = try XCTUnwrap(try ViewerFactory.makeViewer(frame: .zero) as? NativeViewer)
        XCTAssertTrue(viewer.folderGrants === ViewerFactory.folderGrants)
    }
}
