import Foundation
import MetalKit
import ModelCore
import RenderMetal
import XCTest
@testable import ViewerUI

final class NativeViewerSettingsTests: XCTestCase {
    func testEveryDefaultLookMapsToAView() {
        let expected: [DefaultLook: RenderLook] = [
            .original: RenderLook(view: .textured),
            .wireframe: RenderLook(view: .textured, wire: true),
            .clay: RenderLook(view: .solid),
            .normals: RenderLook(view: .normal),
            .unlit: RenderLook(view: .textured, style: .unlit),
            .retro: RenderLook(view: .textured, style: .retro),
            .voxel: RenderLook(view: .textured, style: .voxel),
            .celShaded: RenderLook(view: .textured, style: .celShaded),
            .anime: RenderLook(view: .textured, style: .anime),
            .hologram: RenderLook(view: .textured, style: .hologram),
        ]
        XCTAssertEqual(Set(expected.keys), Set(DefaultLook.allCases))
        for look in DefaultLook.allCases {
            XCTAssertEqual(NativeViewerSettings(defaultLook: look).initialState().look, expected[look], "\(look)")
        }
    }

    func testHologramIsAStyleOfItsOwnAndHasAButton() {
        XCTAssertEqual(DefaultLook.hologram.look.style, .hologram)
        XCTAssertEqual(StyleButton.all.last?.style, .hologram)
        XCTAssertEqual(StyleButton.all.last?.needsTexture, false)
        // It restyles any model, so it stays on where there is no Textured view.
        XCTAssertEqual(DefaultLook.hologram.look.constrained(textured: false), RenderLook(view: .solid, style: .hologram))
        XCTAssertEqual(RenderLook().toggling(style: .hologram, textured: true).toggling(style: .hologram, textured: true), RenderLook())
        XCTAssertFalse(RenderLook(style: .hologram).needsOutline)
    }

    func testViewRules() {
        XCTAssertEqual(RenderLook(view: .textured, style: .anime).selecting(view: .normal), RenderLook(view: .normal))
        XCTAssertEqual(RenderLook(view: .textured, style: .celShaded).selecting(view: .normal), RenderLook(view: .normal, style: .celShaded))
        XCTAssertEqual(RenderLook(view: .textured, style: .unlit).selecting(view: .solid), RenderLook(view: .solid, style: .unlit))
    }

    func testWireRules() {
        XCTAssertEqual(RenderLook(view: .solid).togglingWire(), RenderLook(view: .solid, wire: true))
        XCTAssertEqual(RenderLook(view: .solid, wire: true).togglingWire(), RenderLook(view: .solid))
        XCTAssertEqual(RenderLook(view: .normal, style: .celShaded).togglingWire(), RenderLook(view: .textured, wire: true))
    }

    func testStyleRules() {
        // A model with an appearance of its own: any style turned on goes to Textured.
        for style in [RenderLook.Style.unlit, .anime, .celShaded, .retro, .voxel, .hologram] {
            for view in [RenderLook.View.solid, .textured, .normal] {
                XCTAssertEqual(RenderLook(view: view, wire: true).toggling(style: style, textured: true), RenderLook(view: .textured, style: style))
            }
            // Turning it off again leaves the view where it is.
            XCTAssertEqual(RenderLook(view: .solid, style: style).toggling(style: style, textured: true), RenderLook(view: .solid))
        }
        // One without: the view stays, except that Unlit and Cartoon do not show Normal.
        XCTAssertEqual(RenderLook(view: .solid, wire: true).toggling(style: .celShaded, textured: false), RenderLook(view: .solid, style: .celShaded))
        XCTAssertEqual(RenderLook(view: .normal).toggling(style: .unlit, textured: false), RenderLook(view: .textured, style: .unlit))
        XCTAssertEqual(RenderLook(view: .normal).toggling(style: .celShaded, textured: false), RenderLook(view: .normal, style: .celShaded))
        XCTAssertEqual(RenderLook(style: .celShaded).toggling(style: .celShaded, textured: true), RenderLook())
        XCTAssertEqual(RenderLook(view: .solid, style: .anime).toggling(style: .unlit, textured: true), RenderLook(style: .unlit))
    }

    func testConstrainedWithoutTexturedAppearance() {
        XCTAssertEqual(RenderLook(view: .textured, style: .anime).constrained(textured: false), RenderLook(view: .solid))
        XCTAssertEqual(RenderLook(view: .textured, style: .celShaded).constrained(textured: false), RenderLook(view: .solid, style: .celShaded))
        XCTAssertEqual(RenderLook(view: .normal).constrained(textured: false), RenderLook(view: .normal))
        XCTAssertEqual(RenderLook(view: .textured, style: .anime).constrained(textured: true), RenderLook(view: .textured, style: .anime))
    }

    func testDefaultsMatchTheSettingsFile() {
        let s = NativeViewerSettings().initialState()
        XCTAssertEqual(s.lightIntensity, 1)
        XCTAssertTrue(s.showGrid)
        XCTAssertFalse(s.autoRotate)
        XCTAssertEqual(s.backgroundColor, SIMD3<Float>(0x07, 0x11, 0x0c) / 255)
        XCTAssertEqual(s.solidColor, SIMD3<Float>(0xb4, 0xb4, 0xb8) / 255)
        XCTAssertTrue(s.showViewsBar && s.showFitButton && s.showLightButton && s.showGridButton
                      && s.showRotateButton && s.showGizmo && s.showStats)
    }

    func testValuesAreCarriedAndClamped() {
        let s = NativeViewerSettings(backgroundColor: "#ffffff", solidColor: "#000000", lightIntensity: 9,
                                     showGrid: false, autoRotate: true, showShadingButton: false, showGizmo: false, showStats: false)
        let state = s.initialState()
        XCTAssertEqual(state.backgroundColor, SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(state.solidColor, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(state.lightIntensity, 3)
        XCTAssertFalse(state.showGrid); XCTAssertTrue(state.autoRotate)
        XCTAssertFalse(state.showViewsBar); XCTAssertFalse(state.showGizmo); XCTAssertFalse(state.showStats)
        XCTAssertEqual(NativeViewerSettings(lightIntensity: 0).initialState().lightIntensity, 0.1)
        XCTAssertEqual(NativeViewerSettings(lightIntensity: .nan).initialState().lightIntensity, 1)
    }

    func testBadColoursFallBackToDefaults() {
        for bad in ["", "red", "#12345", "#gggggg", "123456", "#1234567"] {
            XCTAssertNil(NativeViewerSettings.parseHex(bad), bad)
            XCTAssertEqual(NativeViewerSettings(backgroundColor: bad).initialState().backgroundColor,
                           NativeViewerSettings().initialState().backgroundColor)
        }
    }

    func testStatisticsComeFromTheAuthoredTopology() {
        var t = SourceTopology(vertices: 4)
        t.addFace(corners: 4)
        let s = NativeViewerStatistics(t)
        XCTAssertEqual(s, NativeViewerStatistics(topology: "Quad", faces: 1, vertices: 4))
    }

    func testControlsHideInSmallPreviews() {
        XCTAssertEqual(ControlsVisibility(size: CGSize(width: 800, height: 600)), ControlsVisibility(controls: true, stats: true))
        XCTAssertEqual(ControlsVisibility(size: CGSize(width: 500, height: 400)), ControlsVisibility(controls: true, stats: false))
        XCTAssertEqual(ControlsVisibility(size: CGSize(width: 479, height: 600)), ControlsVisibility(controls: false, stats: false))
        XCTAssertEqual(ControlsVisibility(size: CGSize(width: 800, height: 339)), ControlsVisibility(controls: false, stats: false))
    }
}

final class ViewGizmoTests: XCTestCase {
    func testFrontViewPutsZNearestAndCentred() {
        let handles = ViewGizmo.handles(GizmoBasis())
        XCTAssertEqual(handles.count, 6)
        let nearest = handles.last!
        XCTAssertEqual(nearest.preset, .front)
        XCTAssertEqual(nearest.point.x, 0, accuracy: 1e-6); XCTAssertEqual(nearest.point.y, 0, accuracy: 1e-6)
        let right = handles.first { $0.preset == .right }!
        XCTAssertEqual(right.point.x, 1, accuracy: 1e-6)
        let top = handles.first { $0.preset == .top }!
        XCTAssertEqual(top.point.y, -1, accuracy: 1e-6)      // y points down on screen
    }

    func testHitPicksTheNearestHandleOrNothing() {
        let handles = ViewGizmo.handles(GizmoBasis())
        XCTAssertEqual(ViewGizmo.hit(.zero, handles: handles, radius: 0.28), .front)   // front over back
        XCTAssertEqual(ViewGizmo.hit(CGPoint(x: 0.95, y: 0), handles: handles, radius: 0.28), .right)
        XCTAssertEqual(ViewGizmo.hit(CGPoint(x: -1, y: 0.05), handles: handles, radius: 0.28), .left)
        XCTAssertNil(ViewGizmo.hit(CGPoint(x: 0.6, y: 0.6), handles: handles, radius: 0.28))
    }

    func testPresetsAreAllReachable() {
        XCTAssertEqual(Set(ViewGizmo.handles(GizmoBasis()).map(\.preset)), Set(ViewPreset.allCases))
    }
}

@MainActor
final class NativeViewerLoadTests: XCTestCase {
    private func temp(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadsAnSTLAndReportsStatistics() async throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        let tetra: [[[Float]]] = [[[0, 0, 0], [2, 0, 0], [0, 4, 0]], [[0, 0, 0], [0, 4, 0], [0, 0, 3]],
                                  [[0, 0, 0], [0, 0, 3], [2, 0, 0]], [[2, 0, 0], [0, 0, 3], [0, 4, 0]]]
        var text = "solid t\n"
        for t in tetra {
            text += " facet normal 0 0 0\n  outer loop\n"
            for v in t { text += "   vertex \(v[0]) \(v[1]) \(v[2])\n" }
            text += "  endloop\n endfacet\n"
        }
        text += "endsolid t\n"
        let url = try temp("t.stl", text)
        try viewer.load(fileAt: url)
        await viewer.loadTask?.value
        XCTAssertNil(viewer.model.message)
        XCTAssertEqual(viewer.model.statistics?.faces, 4)
        XCTAssertEqual(viewer.model.statistics?.topology, "Triangle")
        XCTAssertNotNil(viewer.renderer.scene)
    }

    /// The camera comes in on a model that has just been read, from farther off and to one
    /// side; with Reduce Motion it is where it will rest from the first frame.
    func testTheCameraArrivesOnAModelUnlessMotionIsReduced() async throws {
        let solid = "solid t\n facet normal 0 0 1\n  outer loop\n   vertex 0 0 0\n   vertex 1 0 0\n   vertex 0 1 0\n  endloop\n endfacet\nendsolid t\n"
        for calm in [false, true] {
            let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
            viewer.reducesMotion = { calm }
            try viewer.load(fileAt: try temp("arrive.stl", solid))
            await viewer.loadTask?.value
            let home = viewer.renderer.homeCamera, now = viewer.renderer.camera
            if calm {
                XCTAssertEqual(now.yaw, home.yaw)
                XCTAssertEqual(now.distance, home.distance)
            } else {
                XCTAssertEqual(now.yaw, home.yaw + NativeViewer.openingYaw, accuracy: 1e-5)
                XCTAssertEqual(now.distance, home.distance * NativeViewer.openingDistance, accuracy: home.distance * 1e-5)
                XCTAssertEqual(now.pitch, home.pitch, "it comes round, not down")
            }
        }
    }

    /// While a file is read the controls wait and the mark turns; with the model they come forward.
    func testTheControlsWaitWhileAFileIsRead() async throws {
        let solid = "solid t\n facet normal 0 0 1\n  outer loop\n   vertex 0 0 0\n   vertex 1 0 0\n   vertex 0 1 0\n  endloop\n endfacet\nendsolid t\n"
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        XCTAssertFalse(viewer.model.loading)
        try viewer.load(fileAt: try temp("wait.stl", solid))
        XCTAssertTrue(viewer.model.loading)
        XCTAssertEqual(viewer.chromeAlpha, 0)
        await viewer.loadTask?.value
        XCTAssertFalse(viewer.model.loading)
        XCTAssertEqual(viewer.chromeAlpha, 1)
        // A file that cannot be shown brings them forward too, with its message.
        try viewer.load(fileAt: try temp("wait.dae", "<?xml version=\"1.0\"?><COLLADA version=\"1.4.1\"></COLLADA>"))
        XCTAssertEqual(viewer.chromeAlpha, 0)
        await viewer.loadTask?.value
        XCTAssertFalse(viewer.model.loading)
        XCTAssertEqual(viewer.chromeAlpha, 1)
    }

    func testUnreadableFileThrows() throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        XCTAssertThrowsError(try viewer.load(fileAt: URL(fileURLWithPath: "/nonexistent/none.stl")))
    }

    func testUnsupportedFormatIsShownAsText() async throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        // A COLLADA file: no longer shown.
        try viewer.load(fileAt: try temp("t.dae", "<?xml version=\"1.0\"?><COLLADA version=\"1.4.1\"></COLLADA>"))
        await viewer.loadTask?.value
        XCTAssertTrue(viewer.model.message?.contains("COLLADA files are not supported") == true)
        XCTAssertNil(viewer.model.statistics)
    }

    private let skinned = """
    #usda 1.0
    (
        upAxis = "Y"
        startTimeCode = 0
        endTimeCode = 24
        timeCodesPerSecond = 24
        defaultPrim = "root"
    )

    def SkelRoot "root"
    {
        def Skeleton "skel" (
            prepend apiSchemas = ["SkelBindingAPI"]
        )
        {
            uniform token[] joints = ["a", "a/b"]
            uniform matrix4d[] bindTransforms = [( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) ), ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 1, 0, 1) )]
            uniform matrix4d[] restTransforms = [( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) ), ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 1, 0, 1) )]
            rel skel:animationSource = </root/skel/anim>

            def SkelAnimation "anim"
            {
                uniform token[] joints = ["a", "a/b"]
                float3[] translations = [(0, 0, 0), (0, 1, 0)]
                quatf[] rotations.timeSamples = {
                    0: [(1, 0, 0, 0), (1, 0, 0, 0)],
                    24: [(1, 0, 0, 0), (0.70710678, 0, 0, 0.70710678)],
                }
                half3[] scales = [(1, 1, 1), (1, 1, 1)]
            }
        }

        def Mesh "mesh" (
            prepend apiSchemas = ["SkelBindingAPI"]
        )
        {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 2, 0)]
            int[] primvars:skel:jointIndices = [0, 0, 1] (
                elementSize = 1
                interpolation = "vertex"
            )
            float[] primvars:skel:jointWeights = [1, 1, 1] (
                elementSize = 1
                interpolation = "vertex"
            )
            rel skel:skeleton = </root/skel>
        }
    }
    """

    func testAClipPlaysOnceAndStopsOnItsLastMomentUnlessItIsToRepeat() async throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        try viewer.load(fileAt: try temp("once.usda", skinned))
        await viewer.loadTask?.value
        XCTAssertFalse(viewer.model.repeats, "once, unless asked")
        // The setting is where the switch starts, for every file.
        let round = try XCTUnwrap(NativeViewer(settings: NativeViewerSettings(repeatAnimations: true)))
        try round.load(fileAt: try temp("round.usda", skinned))
        await round.loadTask?.value
        XCTAssertTrue(round.model.repeats)
        round.model.repeats = false
        try round.load(fileAt: try temp("round2.usda", skinned))
        await round.loadTask?.value
        XCTAssertTrue(round.model.repeats)
        let view = MTKView(frame: .init(x: 0, y: 0, width: 64, height: 64), device: viewer.renderer.device)
        // Just before the end, then played on: the next frame is past it.
        viewer.model.onSeek?(0.9999)
        viewer.model.playing = true
        viewer.draw(in: view)
        XCTAssertFalse(viewer.model.playing, "it has stopped")
        XCTAssertEqual(viewer.model.clock.progress, 1, accuracy: 1e-6, "on its last moment")
        // Played again from there, it starts over.
        viewer.model.playing = true
        viewer.draw(in: view)
        XCTAssertTrue(viewer.model.playing)
        XCTAssertLessThan(viewer.model.clock.progress, 0.9)

        // Told to repeat, it goes round.
        viewer.model.repeats = true
        viewer.model.onSeek?(0.9999)
        viewer.model.playing = true
        viewer.draw(in: view)
        XCTAssertTrue(viewer.model.playing)
        try await Task.sleep(nanoseconds: 50_000_000)
        viewer.draw(in: view)
        XCTAssertLessThan(viewer.model.clock.progress, 0.9)
    }

    func testAnAnimatedModelGetsTheAnimationBarAndPlays() async throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        try viewer.load(fileAt: try temp("skinned.usda", skinned))
        await viewer.loadTask?.value
        XCTAssertNil(viewer.model.message)
        XCTAssertEqual(viewer.model.clipNames, ["anim"])
        XCTAssertEqual(viewer.model.onlyClipName, "anim", "the file's name for its one clip")
        XCTAssertTrue(viewer.model.playing, "plays on opening by default")
        // Choosing a position pauses there.
        viewer.model.onSeek?(0.5)
        XCTAssertFalse(viewer.model.playing)
        XCTAssertEqual(viewer.model.clock.progress, 0.5, accuracy: 1e-6)
        viewer.model.onSeek?(7)
        XCTAssertEqual(viewer.model.clock.progress, 1, accuracy: 1e-6)

        // With autoplay off it opens paused; a model without animation has no bar.
        let quiet = try XCTUnwrap(NativeViewer(settings: NativeViewerSettings(autoplay: false)))
        try quiet.load(fileAt: try temp("skinned2.usda", skinned))
        await quiet.loadTask?.value
        XCTAssertEqual(quiet.model.clipNames, ["anim"])
        XCTAssertFalse(quiet.model.playing)
        try quiet.load(fileAt: try temp("t2.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"))
        await quiet.loadTask?.value
        XCTAssertEqual(quiet.model.clipNames, [])
        XCTAssertNil(quiet.model.onlyClipName)
        XCTAssertFalse(quiet.model.playing)
    }

    func testNeutralGLTFMaterialEffectsRemainSelectable() async throws {
        let vertices: [Float] = [-1,-1,0, 1,-1,0, 0,1,0]
        let data = vertices.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        for effect in ["\"alphaMode\":\"BLEND\",\"pbrMetallicRoughness\":{\"baseColorFactor\":[1,1,1,0]}", "\"emissiveFactor\":[1,0,0]"] {
            let text = """
            {"asset":{"version":"2.0"},"buffers":[{"uri":"data:application/octet-stream;base64,\(data)","byteLength":36}],
            "bufferViews":[{"buffer":0,"byteLength":36}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
            "nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],"materials":[{\(effect)}]}
            """
            let viewer = try XCTUnwrap(NativeViewer(settings: NativeViewerSettings(defaultLook: .original)))
            viewer.reducesMotion = { true }
            try viewer.load(fileAt: try temp("effect.gltf", text))
            await viewer.loadTask?.value
            XCTAssertNil(viewer.model.message)
            XCTAssertTrue(viewer.model.hasTextured)
            XCTAssertEqual(viewer.model.look.view, .textured)
            viewer.model.look = RenderLook(view: .solid)
            viewer.model.look = RenderLook(view: .textured)
            XCTAssertEqual(viewer.model.look.view, .textured)
        }
    }

    func testPortraitResizeAndFitPreserveModelContainment() async throws {
        let viewer = try XCTUnwrap(NativeViewer())
        viewer.reducesMotion = { true }
        try viewer.load(fileAt: try temp("fit.obj", "v -1 -1 0\nv 1 -1 0\nv 0 1 0\nf 1 2 3\n"))
        await viewer.loadTask?.value
        let canvas = try XCTUnwrap(viewer.view.subviews.compactMap { $0 as? MTKView }.first)
        canvas.autoResizeDrawable = false
        canvas.drawableSize = CGSize(width: 100, height: 200)
        viewer.mtkView(canvas, drawableSizeWillChange: canvas.drawableSize)
        XCTAssertEqual(viewer.renderer.camera, viewer.renderer.homeCamera)
        var chosen = viewer.renderer.camera
        chosen.distance *= 0.5; chosen.target.x += 1
        viewer.renderer.camera = chosen
        canvas.drawableSize = CGSize(width: 120, height: 300)
        viewer.mtkView(canvas, drawableSizeWillChange: canvas.drawableSize)
        XCTAssertEqual(viewer.renderer.camera, chosen)
        viewer.model.onFit?()
        viewer.draw(in: canvas)
        let camera = viewer.renderer.camera
        XCTAssertEqual(camera, viewer.renderer.homeCamera)
        let matrix = camera.projectionMatrix(aspect: 0.4) * camera.viewMatrix
        for x: Float in [-1,1] { for y: Float in [-1,1] {
            let p = matrix * SIMD4(x,y,0,1)
            XCTAssertLessThan(abs(p.x / p.w), 1); XCTAssertLessThan(abs(p.y / p.w), 1)
        } }
    }

    func testOBJAndPLYLoad() async throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        try viewer.load(fileAt: try temp("t.obj", "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n"))
        await viewer.loadTask?.value
        XCTAssertNil(viewer.model.message)
        XCTAssertEqual(viewer.model.statistics, NativeViewerStatistics(topology: "Quad", faces: 1, vertices: 4))
        XCTAssertFalse(viewer.model.hasTextured)

        // Vertex colours give the model a Textured view.
        let ply = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0 255 0 0\n1 0 0 0 255 0\n0 1 0 0 0 255\n3 0 1 2\n"
        try viewer.load(fileAt: try temp("t.ply", ply))
        await viewer.loadTask?.value
        XCTAssertNil(viewer.model.message)
        XCTAssertEqual(viewer.model.statistics, NativeViewerStatistics(topology: "Triangle", faces: 1, vertices: 3))
        XCTAssertTrue(viewer.model.hasTextured)

        // A point cloud: no faces.
        try viewer.load(fileAt: try temp("points.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\n"))
        await viewer.loadTask?.value
        XCTAssertNil(viewer.model.message)
        XCTAssertEqual(viewer.model.statistics, NativeViewerStatistics(topology: "–", faces: 0, vertices: 3))
    }

    func testPlainSTLOpensInSolidAndPreparesTheOutlineForCartoon() async throws {
        let viewer = try XCTUnwrap(NativeViewer(settings: NativeViewerSettings(defaultLook: .anime)), "no Metal device")
        var text = "solid t\n"
        for t in [[[0, 0, 0], [2, 0, 0], [0, 4, 0]], [[0, 0, 0], [0, 4, 0], [0, 0, 3]],
                  [[0, 0, 0], [0, 0, 3], [2, 0, 0]], [[2, 0, 0], [0, 0, 3], [0, 4, 0]]] {
            text += " facet normal 0 0 0\n  outer loop\n"
            for v in t { text += "   vertex \(v[0]) \(v[1]) \(v[2])\n" }
            text += "  endloop\n endfacet\n"
        }
        text += "endsolid t\n"
        try viewer.load(fileAt: try temp("t.stl", text))
        await viewer.loadTask?.value
        XCTAssertFalse(viewer.model.hasTextured)
        XCTAssertEqual(viewer.model.look, RenderLook(view: .solid))
        // Cel-Shaded needs the outline; choosing it prepares it.
        viewer.model.look = viewer.model.look.toggling(style: .celShaded, textured: viewer.model.hasTextured)
        let scene = try XCTUnwrap(viewer.renderer.scene)
        let deadline = Date().addingTimeInterval(5)
        while !scene.isOutlineReady && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(scene.isOutlineReady)
    }

    func testHologramAsTheDefaultLookArrivesFromTheFirstFrameAndRestsWhenMotionIsReduced() async throws {
        let viewer = try XCTUnwrap(NativeViewer(settings: NativeViewerSettings(defaultLook: .hologram)), "no Metal device")
        var calm = false
        viewer.reducesMotion = { calm }
        var stl = "solid t\n"
        for t in [[[0, 0, 0], [2, 0, 0], [0, 4, 0]], [[0, 0, 0], [0, 4, 0], [0, 0, 3]],
                  [[0, 0, 0], [0, 0, 3], [2, 0, 0]], [[2, 0, 0], [0, 0, 3], [0, 4, 0]]] {
            stl += " facet normal 0 0 0\n  outer loop\n"
            for v in t { stl += "   vertex \(v[0]) \(v[1]) \(v[2])\n" }
            stl += "  endloop\n endfacet\n"
        }
        stl += "endsolid t\n"
        try viewer.load(fileAt: try temp("h.stl", stl))
        await viewer.loadTask?.value
        // A model without images keeps the style and drops only the textured view.
        XCTAssertEqual(viewer.model.look, RenderLook(view: .solid, style: .hologram))
        XCTAssertEqual(viewer.renderer.look.style, .hologram)

        // The arrival starts with the first frame, however long loading took.
        let view = MTKView(frame: .init(x: 0, y: 0, width: 64, height: 64), device: viewer.renderer.device)
        viewer.draw(in: view)
        XCTAssertFalse(viewer.renderer.hologramStill)
        XCTAssertLessThan(viewer.renderer.hologramSeconds, 0.05)
        try await Task.sleep(nanoseconds: 120_000_000)
        viewer.draw(in: view)
        XCTAssertGreaterThan(viewer.renderer.hologramSeconds, 0.1)
        XCTAssertLessThan(viewer.renderer.hologramSeconds, 2)

        // Another model is built up anew.
        try viewer.load(fileAt: try temp("h2.stl", stl))
        await viewer.loadTask?.value
        viewer.draw(in: view)
        XCTAssertLessThan(viewer.renderer.hologramSeconds, 0.05)

        // With motion reduced the shell is shown whole and at rest: two frames are one picture.
        calm = true
        viewer.draw(in: view)
        XCTAssertTrue(viewer.renderer.hologramStill)
        let a = try viewer.renderer.renderOffscreen(width: 96, height: 96)
        try await Task.sleep(nanoseconds: 60_000_000)
        viewer.draw(in: view)
        let b = try viewer.renderer.renderOffscreen(width: 96, height: 96)
        XCTAssertTrue(a.bytes == b.bytes)
        var g = 0, r = 0
        for i in stride(from: 0, to: a.bytes.count, by: 4) { g += Int(a.bytes[i + 1]); r += Int(a.bytes[i + 2]) }
        XCTAssertGreaterThan(g, r, "the shell is there, mint")
    }

    /// A strip skinned to a bone that sticks out sideways and swings (as hair does), in a
    /// cartoon material whose image slides.
    private var swinging: ModelScene {
        var part = ModelScene.MeshPart()
        part.positions = [SIMD3(0, -0.1, 0), SIMD3(1, -0.1, 0), SIMD3(1, 0.1, 0), SIMD3(0, 0.1, 0)]
        part.normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        part.uv0 = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        part.triangleIndices = [0, 1, 2, 0, 2, 3]
        part.material = 0
        part.skin = ModelScene.Skin(skeleton: 0, joints: [SIMD4<UInt16>](repeating: SIMD4(1, 0, 0, 0), count: 4), weights: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 4))
        var material = ModelScene.Material()
        material.baseColorTexture = 0
        material.doubleSided = true
        var toon = ModelScene.Toon()
        toon.uvScroll = SIMD2(0.5, 0)
        material.toon = toon
        var scene = ModelScene()
        scene.materials = [material]
        scene.textures = [.pixels(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 255, 0, 255])]
        scene.meshes = [ModelScene.Mesh(parts: [part])]
        scene.nodes = [ModelScene.Node(mesh: 0)]
        scene.skeletons = [ModelScene.Skeleton(joints: [.init(name: "root", parent: nil), .init(name: "strand", parent: 0)], node: nil)]
        scene.springs = ModelScene.SpringSystem(skeleton: 0, colliders: [], joints: [.init(joint: 1, tail: SIMD3(1, 0, 0), stiffness: 0, gravityPower: 1, drag: 0.4, colliders: [])])
        return scene
    }

    func testWithMotionReducedSwingingPartsHangAtRestAndSlidingImagesStayPut() async throws {
        /// How wide and how tall the strip is on screen after two frames a moment apart,
        /// whether those two frames are one picture, and the image's clock.
        func show(calm: Bool) async throws -> (width: Int, height: Int, same: Bool, seconds: Double) {
            let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
            viewer.reducesMotion = { calm }
            viewer.model.showGrid = false
            viewer.renderer.backgroundAlpha = 0
            viewer.renderer.show(try viewer.renderer.makeScene(swinging))
            viewer.model.hasTextured = true
            viewer.model.look = RenderLook(view: .textured)
            XCTAssertTrue(viewer.renderer.showsMovingTextures)
            XCTAssertTrue(try XCTUnwrap(viewer.renderer.scene).hasSprings)
            let view = MTKView(frame: .init(x: 0, y: 0, width: 64, height: 64), device: viewer.renderer.device)
            viewer.draw(in: view)
            let first = try viewer.renderer.renderOffscreen(width: 96, height: 96)
            try await Task.sleep(nanoseconds: 80_000_000)
            viewer.draw(in: view)
            let second = try viewer.renderer.renderOffscreen(width: 96, height: 96)
            var top = 96, bottom = -1, left = 96, right = -1
            for y in 0..<96 { for x in 0..<96 where second.pixel(x, y).a > 0 { top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x) } }
            return (right - left, bottom - top, first.bytes == second.bytes, viewer.renderer.materialSeconds)
        }
        // As it is: the strand has only begun to fall, the picture changes, the image's clock runs.
        let lively = try await show(calm: false)
        XCTAssertGreaterThan(lively.width, lively.height, "still more sideways than down")
        XCTAssertFalse(lively.same)
        XCTAssertGreaterThan(lively.seconds, 0.05)
        // With motion reduced: hanging straight down from the first frame, and nothing moves.
        let calm = try await show(calm: true)
        XCTAssertGreaterThan(calm.height, calm.width * 2, "hanging down")
        XCTAssertTrue(calm.same)
        XCTAssertEqual(calm.seconds, 0)
    }

    func testWithMotionReducedTheModelDoesNotStartTurningByItself() throws {
        var settings = NativeViewerSettings()
        settings.autoRotate = true
        let viewer = try XCTUnwrap(NativeViewer(settings: settings), "no Metal device")
        viewer.reducesMotion = { false }
        viewer.resetControls()
        XCTAssertTrue(viewer.model.autoRotate, "the user's setting")
        viewer.reducesMotion = { true }
        viewer.resetControls()
        XCTAssertFalse(viewer.model.autoRotate)
        // Its button still turns it on.
        viewer.model.autoRotate = true
        XCTAssertTrue(viewer.model.autoRotate)
        XCTAssertEqual(viewer.view.subviews.compactMap { $0 as? MTKView }.first?.accessibilityLabel(), "3D model")
    }

    func testAStyleAsTheDefaultLookOpensInTheTexturedViewOnAModelWithItsOwnColours() async throws {
        for (look, style) in [(DefaultLook.unlit, RenderLook.Style.unlit), (.anime, .anime), (.celShaded, .celShaded), (.hologram, .hologram)] {
            let viewer = try XCTUnwrap(NativeViewer(settings: NativeViewerSettings(defaultLook: look)), "no Metal device")
            // A triangle with vertex colours: an appearance of its own.
            let ply = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0 255 0 0\n1 0 0 0 255 0\n0 1 0 0 0 255\n3 0 1 2\n"
            try viewer.load(fileAt: try temp("c-\(look.rawValue).ply", ply))
            await viewer.loadTask?.value
            XCTAssertTrue(viewer.model.hasTextured, look.rawValue)
            XCTAssertEqual(viewer.model.look, RenderLook(view: .textured, style: style), look.rawValue)
            // And it comes back to that when Quick Look shows the preview again.
            viewer.model.look = RenderLook(view: .normal)
            viewer.resetControls()
            XCTAssertEqual(viewer.model.look, RenderLook(view: .textured, style: style), look.rawValue)
        }
    }

    func testFilesBesideAModelAreReadAndWhatIsMissingIsSaid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("m.obj")
        try Data("mtllib m.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl red\nf 1 2 3\n".utf8).write(to: model)

        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        try viewer.load(fileAt: model)
        await viewer.loadTask?.value
        XCTAssertEqual(viewer.model.notice?.title, "Materials not shown")
        XCTAssertNil(viewer.model.notice?.action, "nothing to offer without a place to keep grants")
        XCTAssertFalse(viewer.model.hasTextured)

        viewer.folderGrants = FolderGrants(role: .app, scopedStore: folder.appendingPathComponent("own.plist"), sharedStore: folder.appendingPathComponent("shared.plist"))
        try viewer.load(fileAt: model)
        await viewer.loadTask?.value
        XCTAssertEqual(viewer.model.notice?.action, "Show Materials…")

        // With the library there, its colour is shown and nothing is said.
        try Data("newmtl red\nKd 1 0 0\n".utf8).write(to: folder.appendingPathComponent("m.mtl"))
        try viewer.load(fileAt: model)
        await viewer.loadTask?.value
        XCTAssertNil(viewer.model.notice)
        XCTAssertTrue(viewer.model.hasTextured)
    }

    func testAModelWhoseDataIsBesideItOffersTheFolderAndLoadsOnceItIsThere() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p3d-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("m.gltf")
        try Data("""
        {"asset": {"version": "2.0"}, "nodes": [{"mesh": 0}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
         "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
         "bufferViews": [{"buffer": 0, "byteLength": 36}], "buffers": [{"uri": "m.bin", "byteLength": 36}]}
        """.utf8).write(to: model)

        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        viewer.folderGrants = FolderGrants(role: .app, scopedStore: folder.appendingPathComponent("own.plist"), sharedStore: folder.appendingPathComponent("shared.plist"))
        try viewer.load(fileAt: model)
        await viewer.loadTask?.value
        XCTAssertTrue(viewer.model.message?.contains("m.bin") == true)
        XCTAssertEqual(viewer.model.notice?.title, "Model not shown")
        XCTAssertEqual(viewer.model.notice?.action, "Show Model…")

        let triangle: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        try triangle.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: folder.appendingPathComponent("m.bin"))
        try viewer.load(fileAt: model)
        await viewer.loadTask?.value
        XCTAssertNil(viewer.model.message)
        XCTAssertNil(viewer.model.notice)
        XCTAssertEqual(viewer.model.statistics?.faces, 1)
    }

    func testResetRestoresTheInitialState() throws {
        let viewer = try XCTUnwrap(NativeViewer(settings: NativeViewerSettings(defaultLook: .clay, lightIntensity: 2)), "no Metal device")
        viewer.model.look.view = .normal
        viewer.model.showGrid = false
        viewer.model.lightIntensity = 0.5
        viewer.resetControls()
        XCTAssertEqual(viewer.model.look.view, .solid)
        XCTAssertTrue(viewer.model.showGrid)
        XCTAssertEqual(viewer.renderer.lightIntensity, 2)
        XCTAssertEqual(viewer.renderer.look.view, .solid)
    }
}
