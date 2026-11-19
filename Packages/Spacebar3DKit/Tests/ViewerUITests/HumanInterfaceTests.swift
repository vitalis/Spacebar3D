import AppKit
import RenderMetal
import SwiftUI
import ViewInspector
import XCTest
@testable import ViewerUI

/// What the Human Interface Guidelines audit of November 2026 asked of the canvas controls:
/// wording, reasons for what is dimmed, Increase Contrast, hit targets and how the controls
/// are announced.
@MainActor
final class HumanInterfaceTests: XCTestCase {
    private func model() -> NativeViewerModel {
        let model = NativeViewerModel()
        model.visibility = ControlsVisibility(size: CGSize(width: 900, height: 700))
        return model
    }

    // MARK: Tooltips (#3, #4)

    func testTooltipsUseShortControlNames() {
        let tips = [ViewerTips.wireframe, ViewerTips.viewSettings, ViewerTips.fit, ViewerTips.light, ViewerTips.grid, ViewerTips.autoRotate,
                    ViewerTips.play, ViewerTips.pause, ViewerTips.clip, ViewerTips.scrubber, ViewerTips.repeats] + StyleButton.all.map(\.tip)
        for tip in tips {
            XCTAssertLessThanOrEqual(tip.count, 24, tip)
            XCTAssertFalse(tip.hasSuffix("."), tip)
        }
        XCTAssertEqual(StyleButton.all.map(\.tip), ["Unshaded", "Anime", "Cel-Shaded", "Retro", "Voxel Art", "Hologram"])
        XCTAssertEqual(StyleButton.all[1].icon, "anime-eye")
    }

    func testAnimeAssetLoadsAsNativeSymbol() throws {
        let image = try XCTUnwrap(Bundle.module.image(forResource: "anime-eye"))
        XCTAssertNotNil(image.symbolConfiguration)
        let small = try XCTUnwrap(image.withSymbolConfiguration(.init(textStyle: .body, scale: .small)))
        let large = try XCTUnwrap(image.withSymbolConfiguration(.init(textStyle: .largeTitle, scale: .large)))
        XCTAssertGreaterThan(large.size.width, small.size.width)
        XCTAssertGreaterThan(small.size.height, 0)
    }

    func testAStyleThatNeedsTexturesSaysSoWhenItIsDimmed() {
        let unlit = StyleButton.all[0], voxel = StyleButton.all[4]
        XCTAssertEqual(ViewsBar.tooltip(for: unlit, hasTextured: false), "Needs a model with textures or colors")
        XCTAssertEqual(ViewsBar.tooltip(for: unlit, hasTextured: true), "Unshaded")
        XCTAssertEqual(ViewsBar.tooltip(for: voxel, hasTextured: false), voxel.tip, "it needs no textures")
    }

    func testTheViewSettingsSayWhyTheyAreDimmedOutsideTheTexturedView() throws {
        let model = model()
        model.hasTextured = true
        model.look.view = .solid
        XCTAssertNoThrow(try ViewSettingsPopover(model: model).inspect().find(text: "Material settings apply to the Textured view."))
        model.look.view = .textured
        XCTAssertThrowsError(try ViewSettingsPopover(model: model).inspect().find(text: "Material settings apply to the Textured view."))
    }

    func testTheViewSettingsSlidersHaveANameAndAFigure() throws {
        let model = model()
        model.look.view = .textured
        model.look.metallic = 0.25
        let panel = try ViewSettingsPopover(model: model).inspect()
        XCTAssertNoThrow(try panel.find(text: "Metallic"))
        XCTAssertNoThrow(try panel.find(text: "25%"))
        XCTAssertNoThrow(try panel.find(text: "Roughness"))
        XCTAssertNoThrow(try panel.find(text: "50%"))
        XCTAssertEqual(EnvironmentPanel.percentage(0.255), "26%")
    }

    // MARK: The light (#19)

    func testTheLightTurnsByItselfWhenACheckboxSaysSo() throws {
        let model = model()
        let toggle = try EnvironmentPanel(model: model).inspect().find(ViewType.Toggle.self)
        XCTAssertEqual(try toggle.labelView().text().string(), "Rotate the light automatically")
        XCTAssertEqual(EnvironmentPanel.rotateLightLabel, "Rotate the light automatically")
        try toggle.tap()
        XCTAssertTrue(model.rotatesLight)
    }

    // MARK: Names (#21)

    func testTheFitControlIsNamedZoomToFit() throws {
        let side = try SideControls(model: model()).inspect()
        XCTAssertEqual(try side.findAll(ViewType.Button.self).first?.accessibilityLabel().string(), "Zoom to fit")
    }

    // MARK: Increase Contrast (#7)

    func testIncreasedContrastStrengthensEveryStroke() {
        let usual = NeonGarden.strokes(increased: false), more = NeonGarden.strokes(increased: true)
        XCTAssertEqual(usual, NeonGarden.Strokes(restGlyph: 0.86, onEdge: 0.45, onEdgeWidth: 1, disabledEdge: 0.5, panelEdgeTop: 0.34,
                                                 panelEdgeBottom: 0.10, border: 0.22, gizmoFarRing: 0.9, gizmoBackAxis: 0.4, glassTint: 0.4))
        XCTAssertEqual(more, NeonGarden.Strokes(restGlyph: 1, onEdge: 1, onEdgeWidth: 1.5, disabledEdge: 1, panelEdgeTop: 0.5,
                                                panelEdgeBottom: 0.5, border: 0.5, gizmoFarRing: 1, gizmoBackAxis: 1, glassTint: 0.7))
        XCTAssertGreaterThan(more.restGlyph, usual.restGlyph)
        XCTAssertGreaterThan(more.onEdge, usual.onEdge)
        XCTAssertGreaterThan(more.onEdgeWidth, usual.onEdgeWidth)
        XCTAssertGreaterThan(more.disabledEdge, usual.disabledEdge)
        XCTAssertGreaterThan(more.panelEdgeBottom, usual.panelEdgeBottom)
        XCTAssertGreaterThan(more.border, usual.border)
        XCTAssertGreaterThan(more.gizmoBackAxis, usual.gizmoBackAxis)
        XCTAssertGreaterThan(more.glassTint, usual.glassTint)
    }

    func testTheStrokesTheDrawingsAreMadeFromFollowTheContrast() {
        XCTAssertEqual(NeonGarden.border, NeonGarden.border(increased: false))
        XCTAssertNotEqual(NeonGarden.border(increased: true), NeonGarden.border(increased: false))
        XCTAssertNotEqual(NeonGarden.glassTint(increased: true), NeonGarden.glassTint(increased: false))
    }

    // MARK: Gizmo (#12)

    func testEachGizmoEndIsAtLeastTwentyTwoPointsAcross() {
        let unit = GizmoView.size / 2 * 0.66
        XCTAssertGreaterThanOrEqual(GizmoView.hitRadius * unit * 2, 22)
    }

    func testWhereTwoGizmoEndsOverlapTheOneOnTopWins() {
        // Looking along Z: front and back share a point; front is nearer, so drawn on top.
        let handles = ViewGizmo.handles(GizmoBasis())
        XCTAssertEqual(ViewGizmo.hit(.zero, handles: handles, radius: GizmoView.hitRadius), .front)
        // 20 pt from the end of the right axis is inside the larger target and outside the old one.
        let unit = GizmoView.size / 2 * 0.66
        XCTAssertEqual(ViewGizmo.hit(CGPoint(x: 1 + 10 / unit, y: 0), handles: handles, radius: GizmoView.hitRadius), .right)
        XCTAssertNil(ViewGizmo.hit(CGPoint(x: 1 + 10 / unit, y: 0), handles: handles, radius: 0.28))
    }

    // MARK: Statistics (#10)

    func testTheStatisticsCardIsNotGlassButTheSurfaceOfThePalette() throws {
        XCTAssertEqual(FlatPanel<Capsule>.surfaceOpacity(reduceTransparency: false), 0.72)
        XCTAssertEqual(FlatPanel<Capsule>.surfaceOpacity(reduceTransparency: true), 1)
        let card = Pill(glass: false) { Color.clear.frame(width: 80, height: 30) }
        let picture = try XCTUnwrap(Render.hosted(card, size: CGSize(width: 160, height: 100), seconds: 0.6).picture)
        XCTAssertGreaterThan(picture.drawn, 0, "it has a ground of its own")
        let model = model()
        model.statistics = NativeViewerStatistics(topology: "Triangles", faces: 12, vertices: 8)
        XCTAssertNoThrow(try StatisticsView(model: model).inspect().find(text: "Faces"))
    }
}
