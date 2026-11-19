import SwiftUI
import XCTest

/// The settings being edited, against a settings file in the test's own folder. The shared
/// file in the App Group's container is never passed: no model here is made without `file:`.
final class SettingsModelTests: TempDirTestCase {
    private var file: URL { modelDir.appendingPathComponent("viewer-settings.json") }
    private var onDisk: [String: Any] { ViewerSettings.load(from: file) }

    private func assertDefaults(_ values: [String: Any], line: UInt = #line) {
        XCTAssertEqual(NSDictionary(dictionary: values), NSDictionary(dictionary: ViewerSettings.defaults), line: line)
    }

    // MARK: At launch

    func testTheFileIsCreatedWithTheDefaultsAtFirstLaunch() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let model = SettingsModel(file: file)
        XCTAssertTrue(model.available)
        XCTAssertFalse(model.saveFailed)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        assertDefaults(written)
    }

    func testAnExistingFileIsReadAndLeftAsItIs() throws {
        let text = #"{"showGrid":false,"lightIntensity":1.5,"defaultShading":"celShaded","unknown":1}"#
        try Data(text.utf8).write(to: file)
        let model = SettingsModel(file: file)
        XCTAssertFalse(model.bool(.showGrid).wrappedValue)
        XCTAssertEqual(model.double(.lightIntensity).wrappedValue, 1.5)
        XCTAssertEqual(model.string(.defaultShading).wrappedValue, "celShaded")
        // What the file does not say is the default.
        XCTAssertEqual(model.string(.backgroundColor).wrappedValue, "#07110c")
        XCTAssertTrue(model.bool(.autoplay).wrappedValue)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text, "nothing is written until something is changed")
    }

    func testADamagedFileGivesTheDefaults() throws {
        try Data("{ not json".utf8).write(to: file)
        let model = SettingsModel(file: file)
        for key in ViewerSettings.Key.allCases {
            switch ViewerSettings.defaults[key.rawValue] {
            case let value as Bool: XCTAssertEqual(model.bool(key).wrappedValue, value, key.rawValue)
            case let value as Double: XCTAssertEqual(model.double(key).wrappedValue, value, key.rawValue)
            case let value as String: XCTAssertEqual(model.string(key).wrappedValue, value, key.rawValue)
            default: XCTFail(key.rawValue)
            }
        }
        XCTAssertFalse(model.saveFailed)
    }

    // MARK: Editing

    func testEverySwitchIsReadAndWrittenThrough() {
        let model = SettingsModel(file: file)
        for key in ViewerSettings.Key.allCases {
            guard let usual = ViewerSettings.defaults[key.rawValue] as? Bool else { continue }
            let binding = model.bool(key)
            XCTAssertEqual(binding.wrappedValue, usual, key.rawValue)
            binding.wrappedValue = !usual
            XCTAssertEqual(binding.wrappedValue, !usual, key.rawValue)
            XCTAssertEqual(onDisk[key.rawValue] as? Bool, !usual, key.rawValue)
        }
        XCTAssertFalse(model.saveFailed)
    }

    func testTextAndNumbersAreReadAndWrittenThrough() {
        let model = SettingsModel(file: file)
        model.string(.defaultShading).wrappedValue = "hologram"
        model.string(.backgroundColor).wrappedValue = "#102030"
        model.string(.solidColor).wrappedValue = "#a0b0c0"
        model.double(.lightIntensity).wrappedValue = 1.75
        XCTAssertEqual(model.string(.defaultShading).wrappedValue, "hologram")
        XCTAssertEqual(model.double(.lightIntensity).wrappedValue, 1.75)
        XCTAssertEqual(onDisk["defaultShading"] as? String, "hologram")
        XCTAssertEqual(onDisk["backgroundColor"] as? String, "#102030")
        XCTAssertEqual(onDisk["solidColor"] as? String, "#a0b0c0")
        XCTAssertEqual(onDisk["lightIntensity"] as? Double, 1.75)
    }

    func testOneChangeLeavesTheOtherSettingsAlone() {
        let model = SettingsModel(file: file)
        model.bool(.autoRotate).wrappedValue = true
        var expected = ViewerSettings.defaults
        expected["autoRotate"] = true
        XCTAssertEqual(NSDictionary(dictionary: onDisk), NSDictionary(dictionary: expected))
    }

    func testWhatIsWrittenIsThereForTheNextLaunch() {
        SettingsModel(file: file).bool(.showGrid).wrappedValue = false
        let next = SettingsModel(file: file)
        XCTAssertFalse(next.bool(.showGrid).wrappedValue)
        XCTAssertTrue(next.bool(.autoplay).wrappedValue)
    }

    func testABindingOfTheWrongKindGivesItsEmptyValue() {
        let model = SettingsModel(file: file)
        XCTAssertEqual(model.string(.showGrid).wrappedValue, "")
        XCTAssertEqual(model.double(.defaultShading).wrappedValue, 0)
        XCTAssertFalse(model.bool(.defaultShading).wrappedValue)
    }

    func testRestoringTheDefaultsWritesThem() {
        let model = SettingsModel(file: file)
        model.bool(.showGrid).wrappedValue = false
        model.string(.defaultShading).wrappedValue = "clay"
        model.double(.lightIntensity).wrappedValue = 0.4
        model.reset()
        assertDefaults(onDisk)
        XCTAssertTrue(model.bool(.showGrid).wrappedValue)
        XCTAssertEqual(model.string(.defaultShading).wrappedValue, "original")
        XCTAssertEqual(model.double(.lightIntensity).wrappedValue, 1.0)
        XCTAssertFalse(model.saveFailed)
    }

    func testEveryChangeIsPublished() {
        let model = SettingsModel(file: file)
        var changes = 0
        let watching = model.objectWillChange.sink { changes += 1 }
        model.bool(.showGrid).wrappedValue = false
        XCTAssertGreaterThan(changes, 0)
        let before = changes
        model.reset()
        XCTAssertGreaterThan(changes, before)
        watching.cancel()
    }

    // MARK: When the file cannot be written

    func testAFileThatCannotBeCreatedIsSaidAtOnce() throws {
        // Under a file, where a folder would have to be.
        let model = SettingsModel(file: try put("blocker").appendingPathComponent("viewer-settings.json"))
        XCTAssertTrue(model.available)
        XCTAssertTrue(model.saveFailed)
    }

    func testAFailedWriteIsSaidAndTheNextGoodOneClearsIt() throws {
        let folder = modelDir.appendingPathComponent("settings", isDirectory: true)
        let file = folder.appendingPathComponent("viewer-settings.json")
        let model = SettingsModel(file: file)
        XCTAssertFalse(model.saveFailed)
        // The folder is replaced by a file: nothing can be written into it.
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: URL(fileURLWithPath: folder.path))
        model.bool(.showGrid).wrappedValue = false
        XCTAssertTrue(model.saveFailed)
        XCTAssertFalse(model.bool(.showGrid).wrappedValue, "the window still shows what was chosen")
        model.reset()
        XCTAssertTrue(model.saveFailed)
        // The folder can be made again: the next change is written, and the notice goes.
        try FileManager.default.removeItem(atPath: folder.path)
        model.bool(.autoplay).wrappedValue = false
        XCTAssertFalse(model.saveFailed)
        XCTAssertEqual(ViewerSettings.load(from: file)["autoplay"] as? Bool, false)
    }

    func testWithoutASettingsLocationNothingIsAvailableAndNothingIsWritten() throws {
        let model = SettingsModel(file: nil)
        XCTAssertFalse(model.available)
        XCTAssertFalse(model.saveFailed, "nothing has been tried yet")
        XCTAssertTrue(model.bool(.showGrid).wrappedValue, "the defaults stand in")
        model.bool(.showGrid).wrappedValue = false
        XCTAssertTrue(model.saveFailed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: modelDir.path), [])
    }
}
