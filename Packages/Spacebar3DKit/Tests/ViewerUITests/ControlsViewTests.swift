import RenderMetal
import SwiftUI
import ViewInspector
import XCTest
@testable import ViewerUI

/// The controls as SwiftUI builds them, read in the test process: what is on screen for a
/// given state, and what a press does to the state.
@MainActor
final class ControlsViewTests: XCTestCase {
    private func model(size: CGSize = CGSize(width: 900, height: 700)) -> NativeViewerModel {
        let model = NativeViewerModel()
        model.visibility = ControlsVisibility(size: size)
        return model
    }

    // MARK: The notice about files that were not read

    func testTheNoticeOffersTheFolderAndAsksForIt() throws {
        let model = model()
        var asked = 0
        model.onGrant = { asked += 1 }
        XCTAssertThrowsError(try NoticeView(model: model).inspect().find(ViewType.Text.self), "nothing missing, nothing said")

        model.notice = MissingFilesNotice(missing: ["look.mtl"], granted: false, canGrant: true)
        let view = try NoticeView(model: model).inspect()
        XCTAssertNoThrow(try view.find(text: "Materials not shown"))
        try view.find(button: "Show Materials…").tap()
        XCTAssertEqual(asked, 1)
    }

    func testWhereTheFolderCannotBeAskedForTheNoticeHasNoButton() throws {
        let model = model()
        model.notice = MissingFilesNotice(missing: ["wood.png"], granted: false, canGrant: false)
        let view = try NoticeView(model: model).inspect()
        XCTAssertNoThrow(try view.find(text: "Textures not shown"))
        XCTAssertThrowsError(try view.find(ViewType.Button.self))
    }

    func testTheNoticeStaysOutOfSmallPreviewsAndStandsBesideALoadError() throws {
        let small = model(size: CGSize(width: 300, height: 200))
        small.notice = MissingFilesNotice(missing: ["wood.png"], granted: false, canGrant: true)
        XCTAssertThrowsError(try NoticeView(model: small).inspect().find(ViewType.Text.self))

        let failed = model()
        // A model whose own data is beside it fails to load, and the folder is still offered.
        failed.notice = MissingFilesNotice(missing: ["model.buffer"], granted: false, canGrant: true, failed: true)
        failed.message = "This file could not be shown."
        XCTAssertNoThrow(try NoticeView(model: failed).inspect().find(text: "Model not shown"))
        XCTAssertNoThrow(try NoticeView(model: failed).inspect().find(button: "Show Model…"))
        XCTAssertNoThrow(try MessageView(model: failed).inspect().find(text: "This file could not be shown."))
    }

    // MARK: The bottom bar

    func testTheBarOffersTexturedOnlyForAModelWithAnAppearanceOfItsOwn() throws {
        let model = model()
        model.hasTextured = true
        XCTAssertNoThrow(try ViewsBar(model: model).inspect().find(text: "Textured"))
        model.hasTextured = false
        let plain = try ViewsBar(model: model).inspect()
        XCTAssertTrue(try plain.find(text: "Textured").isDisabled())
        XCTAssertNoThrow(try plain.find(text: "Solid"))
        XCTAssertNoThrow(try plain.find(text: "Normal"))
    }

    func testTheStyleButtonsToggleTheirStyleAndTheOnesNeedingTexturesAreOffWithoutThem() throws {
        let model = model()
        model.hasTextured = false
        var changes = 0
        model.onChange = { changes += 1 }
        let toggles = try ViewsBar(model: model).inspect().findAll(ViewType.Toggle.self)
        // ViewThatFits has wide and compact candidates, each with wireframe and four styles.
        XCTAssertEqual(toggles.count, 2 * (1 + StyleButton.all.count))
        for offset in [0, 1 + StyleButton.all.count] {
            XCTAssertEqual(try toggles.dropFirst(offset + 1).prefix(StyleButton.all.count).map { $0.isDisabled() }, StyleButton.all.map(\.needsTexture))
        }

        let hologram = try XCTUnwrap(toggles.last)
        XCTAssertFalse(try hologram.isOn())
        try hologram.tap()
        XCTAssertEqual(model.look.style, .hologram)
        XCTAssertGreaterThan(changes, 0, "the viewer is told")
        try ViewsBar(model: model).inspect().findAll(ViewType.Toggle.self).last?.tap()
        XCTAssertEqual(model.look.style, .none)

        // The wireframe leaves a style for the textured view with the wire on.
        model.hasTextured = true
        model.look = RenderLook(view: .solid, style: .celShaded)
        try ViewsBar(model: model).inspect().findAll(ViewType.Toggle.self).first?.tap()
        XCTAssertEqual(model.look, RenderLook(view: .textured, wire: true))

        // With textures, every style button moves the view to Textured.
        for index in 1...StyleButton.all.count {
            model.look = RenderLook(view: .solid)
            try ViewsBar(model: model).inspect().findAll(ViewType.Toggle.self)[index].tap()
            XCTAssertEqual(model.look, RenderLook(view: .textured, style: StyleButton.all[index - 1].style))
        }
    }

    /// A button that shows only a symbol is read out by its name, not by the symbol's.
    func testEveryControlWithOnlyASymbolHasANameOfItsOwn() throws {
        let model = model()
        model.hasTextured = true
        let bar = try ViewsBar(model: model).inspect()
        XCTAssertEqual(try bar.findAll(ViewType.Toggle.self).map { try $0.accessibilityLabel().string() },
                       Array(repeating: ["Wireframe", "Unshaded style", "Anime style", "Cel-Shaded", "Retro", "Voxel Art", "Hologram style"], count: 2).flatMap { $0 })
        XCTAssertEqual(try bar.find(ViewType.Button.self).accessibilityLabel().string(), "View settings")
        let side = try SideControls(model: model).inspect()
        XCTAssertEqual(try side.findAll(ViewType.Button.self).map { try $0.accessibilityLabel().string() }, ["Zoom to fit", "Light"])
        XCTAssertEqual(try side.findAll(ViewType.Toggle.self).map { try $0.accessibilityLabel().string() }, ["Floor grid", "Auto-rotate"])
        XCTAssertEqual(try GizmoView(model: model, gizmo: model.gizmo).inspect().find(ViewType.Canvas.self).accessibilityLabel().string(), "View direction")
        let settings = try ViewSettingsPopover(model: model).inspect()
        XCTAssertEqual(try settings.findAll(ViewType.Slider.self).map { try $0.accessibilityLabel().string() }, ["Metallic", "Roughness"])
    }

    func testTheBarsFollowTheSettingsAndTheSizeOfThePreview() throws {
        let small = model(size: CGSize(width: 300, height: 200))
        XCTAssertThrowsError(try ViewsBar(model: small).inspect().find(ViewType.Toggle.self))
        XCTAssertThrowsError(try SideControls(model: small).inspect().find(ViewType.Button.self))

        let hidden = model()
        hidden.flags = NativeViewerState(NativeViewerSettings(showFitButton: false, showLightButton: false, showGridButton: false, showRotateButton: false, showGizmo: false))
        XCTAssertThrowsError(try SideControls(model: hidden).inspect().find(ViewType.Button.self))
        XCTAssertThrowsError(try SideControls(model: hidden).inspect().find(ViewType.Toggle.self))
    }

    // MARK: The side controls

    func testFitGridAndAutoRotate() throws {
        let model = model()
        var fits = 0
        model.onFit = { fits += 1 }
        let side = try SideControls(model: model).inspect()
        try side.find(ViewType.Button.self).tap()
        XCTAssertEqual(fits, 1)
        let toggles = side.findAll(ViewType.Toggle.self)
        XCTAssertEqual(toggles.count, 2)
        XCTAssertTrue(model.showGrid)
        try toggles[0].tap()
        XCTAssertFalse(model.showGrid)
        XCTAssertFalse(model.autoRotate)
        try toggles[1].tap()
        XCTAssertTrue(model.autoRotate)
    }

    // MARK: Animation and statistics

    func testTheAnimationBarAppearsWithClipsAndPlaysAndPauses() throws {
        let model = model()
        XCTAssertThrowsError(try AnimationBar(model: model).inspect().find(ViewType.Button.self), "no animation, no bar")
        model.clipNames = ["walk"]
        let bar = try AnimationBar(model: model).inspect()
        XCTAssertThrowsError(try bar.find(ViewType.Picker.self), "one clip needs no picker")
        XCTAssertThrowsError(try bar.find(text: "walk"), "a name the viewer made up is not shown")
        // The file's own name for its one clip is shown, as words.
        model.onlyClipName = "mixamo.com"
        XCTAssertNoThrow(try AnimationBar(model: model).inspect().find(text: "mixamo.com"))
        XCTAssertThrowsError(try AnimationBar(model: model).inspect().find(ViewType.Picker.self))
        model.onlyClipName = nil
        try bar.find(ViewType.Button.self).tap()
        XCTAssertTrue(model.playing)
        try AnimationBar(model: model).inspect().find(ViewType.Button.self).tap()
        XCTAssertFalse(model.playing)

        // Repeat is a switch beside the scrubber, off to begin with.
        XCTAssertFalse(model.repeats)
        try AnimationBar(model: model).inspect().find(ViewType.Toggle.self).tap()
        XCTAssertTrue(model.repeats)
        try AnimationBar(model: model).inspect().find(ViewType.Toggle.self).tap()
        XCTAssertFalse(model.repeats)

        model.clipNames = ["walk", "run"]
        XCTAssertNoThrow(try AnimationBar(model: model).inspect().find(ViewType.Picker.self))
        XCTAssertNoThrow(try AnimationBar(model: model).inspect().find(text: "run"))
    }

    func testStatisticsShowTheModelsCounts() throws {
        let model = model()
        XCTAssertThrowsError(try StatisticsView(model: model).inspect().find(text: "Topology"))
        model.statistics = NativeViewerStatistics(topology: "Quad", faces: 6, vertices: 8)
        let view = try StatisticsView(model: model).inspect()
        XCTAssertNoThrow(try view.find(text: "Quad"))
        XCTAssertNoThrow(try view.find(text: "Topology"))
        // Too narrow for the statistics, wide enough for the controls.
        let narrow = self.model(size: CGSize(width: 500, height: 400))
        narrow.statistics = model.statistics
        XCTAssertThrowsError(try StatisticsView(model: narrow).inspect().find(text: "Quad"))
    }
}
