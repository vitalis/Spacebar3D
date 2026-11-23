import RenderMetal
import XCTest
@testable import ViewerUI

/// The menus' commands follow the same rules as the controls on the canvas.
@MainActor
final class ViewerCommandTests: XCTestCase {
    private func shown(textured: Bool = true) -> NativeViewerModel {
        let model = NativeViewerModel()
        model.hasTextured = textured
        model.statistics = NativeViewerStatistics(topology: "Quad", faces: 6, vertices: 8)
        return model
    }

    func testNothingCanBeChosenUntilAModelIsShown() {
        let model = NativeViewerModel()
        for command in ViewerCommand.allCases { XCTAssertFalse(model.status(of: command).enabled, command.rawValue) }
        XCTAssertTrue(model.perform(.celShaded), "and choosing one does nothing")
        XCTAssertEqual(model.look.style, .none)
    }

    func testViewsAndStylesTickAndFollowTheBarsRules() {
        let model = shown()
        XCTAssertTrue(model.perform(.solid))
        XCTAssertTrue(model.status(of: .solid).on)
        XCTAssertFalse(model.status(of: .textured).on)
        // Any style on a model with textures goes with the Textured view.
        XCTAssertTrue(model.perform(.anime))
        XCTAssertTrue(model.status(of: .anime).on)
        XCTAssertTrue(model.status(of: .textured).on)
        // Chosen again, a style goes off.
        XCTAssertTrue(model.perform(.anime))
        XCTAssertFalse(model.status(of: .anime).on)
        XCTAssertTrue(model.perform(.wireframe))
        XCTAssertTrue(model.status(of: .wireframe).on)
    }

    func testAModelWithoutTexturesHasNoTexturedViewAndNoStylesThatNeedThem() {
        let model = shown(textured: false)
        for command in [ViewerCommand.textured, .unlit, .anime] { XCTAssertFalse(model.status(of: command).enabled, command.rawValue) }
        for command in [ViewerCommand.solid, .normal, .hologram, .wireframe] { XCTAssertTrue(model.status(of: command).enabled, command.rawValue) }
        let before = model.look
        XCTAssertTrue(model.perform(.unlit))
        XCTAssertEqual(model.look, before)
    }

    func testGridRotateFitAndDirectionsReachTheViewer() {
        let model = shown()
        var fits = 0, looks: [ViewPreset] = []
        model.onFit = { fits += 1 }
        model.onLook = { looks.append($0) }
        let grid = model.showGrid
        XCTAssertTrue(model.perform(.grid))
        XCTAssertEqual(model.showGrid, !grid)
        XCTAssertEqual(model.status(of: .grid).on, !grid)
        XCTAssertTrue(model.perform(.autoRotate))
        XCTAssertTrue(model.status(of: .autoRotate).on)
        XCTAssertTrue(model.perform(.fit))
        XCTAssertEqual(fits, 1)
        for command in [ViewerCommand.front, .back, .left, .right, .top, .bottom] { XCTAssertTrue(model.perform(command)) }
        XCTAssertEqual(looks, [.front, .back, .left, .right, .top, .bottom])
        // Turning and zooming are the camera's, which the viewer holds.
        for command in [ViewerCommand.orbitLeft, .orbitRight, .orbitUp, .orbitDown, .zoomIn, .zoomOut] {
            XCTAssertFalse(model.perform(command), command.rawValue)
        }
    }

    func testPlayingNeedsAnAnimation() {
        let model = shown()
        XCTAssertFalse(model.status(of: .playPause).enabled)
        model.clipNames = ["walk"]
        XCTAssertTrue(model.status(of: .playPause).enabled)
        let playing = model.playing
        XCTAssertTrue(model.perform(.playPause))
        XCTAssertEqual(model.playing, !playing)
    }

    func testEveryCommandHasItsOwnTitleInTitleCapitals() {
        let titles = ViewerCommand.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for title in titles { XCTAssertTrue(title.first?.isUppercase == true, title) }
        XCTAssertEqual(ViewerCommand.allCases.filter(\.isState).count, 22)
    }

    func testShadingsMoodsAndRepeatFollowTheControls() {
        let model = shown()
        XCTAssertTrue(model.status(of: .smoothShading).on)
        XCTAssertTrue(model.perform(.flatShading))
        XCTAssertTrue(model.look.flat)
        XCTAssertTrue(model.status(of: .flatShading).on)
        XCTAssertFalse(model.status(of: .smoothShading).on)
        XCTAssertTrue(model.perform(.smoothShading))
        XCTAssertFalse(model.look.flat)
        XCTAssertTrue(model.perform(.moodNeon))
        XCTAssertEqual(model.surrounding, .neon)
        XCTAssertTrue(model.status(of: .moodNeon).on)
        XCTAssertFalse(model.status(of: .moodGlasshouse).on)
        for (command, mood) in ViewerCommand.moods { XCTAssertEqual(command.title, mood.title) }
        // Repeat needs an animation.
        XCTAssertFalse(model.status(of: .repeatClip).enabled)
        model.clipNames = ["walk"]
        XCTAssertTrue(model.perform(.repeatClip))
        XCTAssertTrue(model.repeats)
        XCTAssertTrue(model.status(of: .repeatClip).on)
    }

    func testPlayingIsReportedSoThatTheMenuCanSayPause() {
        let model = shown()
        model.clipNames = ["walk"]
        XCTAssertFalse(model.status(of: .playPause).on)
        XCTAssertTrue(model.perform(.playPause))
        XCTAssertTrue(model.status(of: .playPause).on)
    }

    func testSettingsRemainAvailableWhenCanvasControlsAreHidden() {
        let model = shown()
        model.flags.showLightButton = false
        model.flags.showViewsBar = false
        for size in [CGSize(width: 900, height: 680), CGSize(width: 479, height: 400), CGSize(width: 320, height: 260)] {
            model.visibility = ControlsVisibility(size: size)
            model.showsViewSettings = false
            model.showsLightSettings = false
            XCTAssertTrue(model.status(of: .showViewSettings).enabled)
            XCTAssertTrue(model.status(of: .showLightSettings).enabled)
            XCTAssertTrue(model.perform(.showViewSettings))
            XCTAssertTrue(model.perform(.showLightSettings))
            XCTAssertTrue(model.showsViewSettings)
            XCTAssertTrue(model.showsLightSettings)
        }
    }

    func testShowTexturesIsOfferedOnlyWhileTheNoticeOffersTheFolder() {
        let model = NativeViewerModel()
        XCTAssertFalse(model.status(of: .showTextures).enabled)
        // Also for a model that could not be shown at all.
        model.notice = MissingFilesNotice(missing: ["a.png"], granted: false, canGrant: true)
        XCTAssertTrue(model.status(of: .showTextures).enabled)
        var asked = 0
        model.onGrant = { asked += 1 }
        XCTAssertTrue(model.perform(.showTextures))
        XCTAssertEqual(asked, 1)
        model.notice = MissingFilesNotice(missing: ["a.png"], granted: true, canGrant: true)
        XCTAssertFalse(model.status(of: .showTextures).enabled)
        model.notice = nil
        XCTAssertFalse(model.status(of: .showTextures).enabled)
    }

    func testTheViewerChoosesAClipAndKeepsItsOwnSpaceKeySetting() throws {
        let viewer = try XCTUnwrap(NativeViewer())
        XCTAssertFalse(viewer.playsWithSpaceKey)
        viewer.model.clipNames = ["walk", "run"]
        viewer.selectClip(1)
        XCTAssertEqual(viewer.currentClip, 1)
        XCTAssertEqual(viewer.clipNames, ["walk", "run"])
        viewer.selectClip(5)
        XCTAssertEqual(viewer.currentClip, 1, "no such clip")
    }

    func testTheViewerAnswersForItsModelAndTurnsItsCamera() throws {
        let viewer = try XCTUnwrap(NativeViewer())
        XCTAssertFalse(viewer.status(of: .solid).enabled)
        var changes = 0
        viewer.onCommandStateChange = { changes += 1 }
        viewer.model.statistics = NativeViewerStatistics(topology: "Quad", faces: 6, vertices: 8)
        viewer.perform(.solid)
        XCTAssertTrue(viewer.status(of: .solid).on)
        XCTAssertGreaterThan(changes, 0, "a menu is told to look again")
        viewer.perform(.orbitLeft)
        viewer.perform(.zoomIn)
    }
}
