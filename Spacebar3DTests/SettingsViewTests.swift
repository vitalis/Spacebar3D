import SwiftUI
import ViewInspector
import ViewerUI
import XCTest

/// The settings form as SwiftUI builds it, read in the test process: its groups, what each
/// control is bound to, and what a change writes. The file is one of the test's own.
@MainActor
final class SettingsViewTests: TempDirTestCase {
    private var file: URL { modelDir.appendingPathComponent("viewer-settings.json") }
    private var onDisk: [String: Any] { ViewerSettings.load(from: file) }

    private func form(_ stored: String? = nil) throws -> (view: InspectableView<ViewType.ClassifiedView>, model: SettingsModel) {
        if let stored { try Data(stored.utf8).write(to: file) }
        let model = SettingsModel(file: file)
        return (try SettingsView(model: model).inspect(), model)
    }

    /// The words of a control's label: its title, and the line under it when it has one.
    private func words(_ toggle: InspectableView<ViewType.Toggle>) throws -> [String] {
        try toggle.labelView().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: The groups

    func testTheFormHasThreeGroupsUnderTheirHeadings() throws {
        let sections = try form().view.findAll(ViewType.Section.self)
        let headings = try sections.map { try $0.header().find(ViewType.Text.self).string() }
        XCTAssertEqual(headings, ["When a model opens", "Appearance", "Default app"])
    }

    func testEachGroupHoldsItsOwnControls() throws {
        let sections = try form().view.findAll(ViewType.Section.self)
        XCTAssertEqual(sections.count, 3)
        func toggles(_ index: Int) throws -> [String] {
            try sections[index].findAll(ViewType.Toggle.self).map { try words($0)[0] }
        }
        XCTAssertEqual(try toggles(0), ["Show floor grid", "Auto-rotate the model", "Play animations automatically", "Repeat animations"])
        XCTAssertEqual(sections[0].findAll(ViewType.Picker.self).count, 1)
        XCTAssertEqual(try toggles(1), [])
        XCTAssertEqual(sections[1].findAll(ViewType.ColorPicker.self).count, 2)
        XCTAssertEqual(sections[1].findAll(ViewType.Slider.self).count, 1)
    }

    // MARK: The switches

    /// Every switch, in the form's order, with the setting it turns.
    private let switches: [(label: [String], key: ViewerSettings.Key)] = [
        (["Show floor grid"], .showGrid),
        (["Auto-rotate the model"], .autoRotate),
        (["Play animations automatically"], .autoplay),
        (["Repeat animations"], .repeatAnimations),
    ]

    func testThereIsOneSwitchForEveryOnOrOffSetting() throws {
        let toggles = try form().view.findAll(ViewType.Toggle.self)
        XCTAssertEqual(try toggles.map(words), switches.map(\.label))
        let onOrOff = ViewerSettings.Key.allCases.filter { ViewerSettings.defaults[$0.rawValue] is Bool }
        XCTAssertEqual(Set(switches.map(\.key)), Set(onOrOff))
        XCTAssertEqual(switches.count, onOrOff.count, "each setting once")
    }

    func testEachSwitchShowsItsSettingAndWritesOnlyThat() throws {
        for (index, entry) in switches.enumerated() {
            try? FileManager.default.removeItem(at: file)
            let (view, _) = try form()
            let usual = try XCTUnwrap(ViewerSettings.defaults[entry.key.rawValue] as? Bool)
            let toggle = view.findAll(ViewType.Toggle.self)[index]
            XCTAssertEqual(try toggle.isOn(), usual, entry.key.rawValue)
            try toggle.tap()
            var expected = ViewerSettings.defaults
            expected[entry.key.rawValue] = !usual
            XCTAssertEqual(NSDictionary(dictionary: onDisk), NSDictionary(dictionary: expected), entry.key.rawValue)
            // Read again, the form shows the new state.
            XCTAssertEqual(try view.findAll(ViewType.Toggle.self)[index].isOn(), !usual, entry.key.rawValue)
        }
    }

    func testTheSwitchesShowWhatTheFileSays() throws {
        let (view, _) = try form(#"{"showGrid":false,"autoRotate":true,"showAnimationBar":false}"#)
        let toggles = view.findAll(ViewType.Toggle.self)
        XCTAssertEqual(try toggles.map { try $0.isOn() },
                       [false, true, true, false])
    }

    // MARK: The look

    func testTheLookMenuOffersTheLooksInTheirGroupsAndWritesTheChosenOne() throws {
        let (view, model) = try form()
        let picker = try view.find(ViewType.Picker.self)
        XCTAssertEqual(try picker.labelView().text().string(), "Opens in:")
        let names = try picker.findAll(ViewType.Text.self).map { try $0.string() }.filter { $0 != "Opens in:" }
        XCTAssertEqual(names, ["Textured", "Solid", "Normal", "Wireframe", "Unshaded", "Anime", "Cel-Shaded", "Retro", "Voxel Art", "Hologram"])
        XCTAssertEqual(picker.findAll(ViewType.Divider.self).count, 2, "a line between the three groups")
        // Each name stands for the look the viewer knows by its own word.
        for look in ViewerSettings.lookGroups.flatMap({ $0 }) {
            XCTAssertEqual(try picker.find(text: look.name).tag() as? String, look.mode)
            try picker.select(value: look.mode)
            XCTAssertEqual(onDisk["defaultShading"] as? String, look.mode)
            XCTAssertEqual(model.string(.defaultShading).wrappedValue, look.mode)
        }
    }

    // MARK: Colours and light

    func testTheColourWellsShowAndWriteTheTwoColours() throws {
        let (view, _) = try form(##"{"backgroundColor":"#ff0000","solidColor":"#0000ff"}"##)
        let wells = view.findAll(ViewType.ColorPicker.self)
        XCTAssertEqual(try wells.map { try $0.labelView().text().string() }, ["Background:", "Solid view color:"])
        try wells[0].select(color: Color(.sRGB, red: 0, green: 1, blue: 0))
        XCTAssertEqual(onDisk["backgroundColor"] as? String, "#00ff00")
        XCTAssertEqual(onDisk["solidColor"] as? String, "#0000ff", "the other colour is left alone")
        try wells[1].select(color: Color(.sRGB, red: 16.0 / 255, green: 32.0 / 255, blue: 171.0 / 255))
        XCTAssertEqual(onDisk["solidColor"] as? String, "#1020ab")
        XCTAssertEqual(onDisk["backgroundColor"] as? String, "#00ff00")
    }

    /// A colour chosen in another form is written as "#rrggbb", which is all the file holds.
    func testAColourGivenAnotherWayIsWrittenAsHex() throws {
        let (view, _) = try form()
        try view.findAll(ViewType.ColorPicker.self)[0].select(color: Color(white: 1))
        XCTAssertEqual(onDisk["backgroundColor"] as? String, "#ffffff")
        try view.findAll(ViewType.ColorPicker.self)[1].select(color: Color(white: 0))
        XCTAssertEqual(onDisk["solidColor"] as? String, "#000000")
    }

    /// The slider runs as far as a stored value may go, a tenth of the usual light to three
    /// times it, so that no setting is shown beside a slider that cannot reach it. (ViewInspector reads and
    /// sets a slider by its position, from 0 at the left end to 1 at the right.)
    func testTheLightSliderWritesItsValueAndShowsItAsAPercentage() throws {
        let (view, _) = try form()
        let slider = try view.find(ViewType.Slider.self)
        let range = ViewerSettings.lightIntensityRange
        XCTAssertEqual(range, 0.1...3.0)
        XCTAssertEqual(try slider.value(), (1.0 - range.lowerBound) / (range.upperBound - range.lowerBound), accuracy: 1e-9)
        XCTAssertNoThrow(try view.find(text: "100%"))
        XCTAssertNoThrow(try view.find(text: "Brightness:"))
        try slider.setValue(0.5)
        XCTAssertEqual(try XCTUnwrap(onDisk["lightIntensity"] as? Double), 1.55, accuracy: 1e-9)
        XCTAssertNoThrow(try view.find(text: "155%"))
        try slider.setValue(0)
        XCTAssertEqual(try XCTUnwrap(onDisk["lightIntensity"] as? Double), 0.1, accuracy: 1e-9)
        XCTAssertNoThrow(try view.find(text: "10%"))
        try slider.setValue(1)
        XCTAssertEqual(try XCTUnwrap(onDisk["lightIntensity"] as? Double), 3.0, accuracy: 1e-9)
        XCTAssertNoThrow(try view.find(text: "300%"))
    }

    func testTheLightIsShownRoundedToAWholePercent() throws {
        XCTAssertNoThrow(try form(#"{"lightIntensity":0.256}"#).view.find(text: "26%"))
        XCTAssertNoThrow(try form(#"{"lightIntensity":1.234}"#).view.find(text: "123%"))
    }

    // MARK: The foot of the form

    func testRestoreDefaultsPutsEverythingBack() throws {
        let (view, model) = try form(##"{"showGrid":false,"defaultShading":"celShaded","lightIntensity":0.5,"solidColor":"#123456"}"##)
        XCTAssertNoThrow(try view.find(text: "50%"))
        try view.find(button: "Restore Defaults").tap()
        XCTAssertEqual(NSDictionary(dictionary: onDisk), NSDictionary(dictionary: ViewerSettings.defaults))
        XCTAssertTrue(model.bool(.showGrid).wrappedValue)
        XCTAssertNoThrow(try view.find(text: "100%"))
    }

    func testTheFootSaysWhenChangesApplyOrThatTheyWereNotSaved() throws {
        let (saved, _) = try form()
        XCTAssertNoThrow(try saved.find(text: "Changes apply the next time you open or preview a model."))
        XCTAssertThrowsError(try saved.find(text: "Could not save settings."))

        let nowhere = try put("blocker").appendingPathComponent("viewer-settings.json")
        let failed = try SettingsView(model: SettingsModel(file: nowhere)).inspect()
        XCTAssertNoThrow(try failed.find(text: "Could not save settings."))
        XCTAssertThrowsError(try failed.find(text: "Changes apply the next time you open or preview a model."))
        XCTAssertNoThrow(try failed.find(button: "Restore Defaults"), "the form is still there to use")
    }

    func testWithoutASettingsLocationTheFormGivesWayToAnExplanation() throws {
        let view = try SettingsView(model: SettingsModel(file: nil)).inspect()
        XCTAssertNoThrow(try view.find(text: "Settings are unavailable: the settings location could not be determined."))
        XCTAssertThrowsError(try view.find(ViewType.Form.self))
        XCTAssertThrowsError(try view.find(ViewType.Toggle.self))
        XCTAssertThrowsError(try view.find(ViewType.Button.self))
    }
}
