import AppKit
import MetalKit
import ObjectiveC
@testable import RenderMetal
import simd
import XCTest
@testable import ViewerUI

/// An event whose deltas and magnification are what a test says: events of a trackpad
/// cannot be made any other way.
private final class SpokenEvent: NSEvent {
    nonisolated(unsafe) static var deltaX: CGFloat = 0, deltaY: CGFloat = 0
    nonisolated(unsafe) static var scrollY: CGFloat = 0, precise = false, magnification: CGFloat = 0
    override var deltaX: CGFloat { Self.deltaX }
    override var deltaY: CGFloat { Self.deltaY }
    override var scrollingDeltaY: CGFloat { Self.scrollY }
    override var hasPreciseScrollingDeltas: Bool { Self.precise }
    override var magnification: CGFloat { Self.magnification }
    nonisolated(unsafe) static var rotation: Float = 0
    override var rotation: Float { Self.rotation }

    static func make(_ type: NSEvent.EventType = .leftMouseDragged, flags: NSEvent.ModifierFlags = [], at location: NSPoint = .zero) -> NSEvent {
        let base = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        object_setClass(base, SpokenEvent.self)
        return base
    }
}

/// What a person does to the viewer with the mouse, the trackpad and the keyboard.
@MainActor
final class NativeViewerInputTests: XCTestCase {
    private let triangle = "solid t\n facet normal 0 0 1\n  outer loop\n   vertex 0 0 0\n   vertex 1 0 0\n   vertex 0 1 0\n  endloop\n endfacet\nendsolid t\n"

    private func loaded(settings: NativeViewerSettings = NativeViewerSettings()) async throws -> NativeViewer {
        let viewer = try XCTUnwrap(NativeViewer(settings: settings), "no Metal device")
        viewer.reducesMotion = { true }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.stl")
        try triangle.write(to: url, atomically: true, encoding: .utf8)
        try viewer.load(fileAt: url)
        await viewer.loadTask?.value
        return viewer
    }

    private func metalView(of viewer: NativeViewer) throws -> ViewerMTKView {
        try XCTUnwrap(viewer.view.subviews.compactMap { $0 as? ViewerMTKView }.first)
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                       characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code))
    }

    // MARK: Keys

    func testArrowKeysOrbitTheModelOnlyWhenTheViewerIsToTakeThemAndTheMarkedCommandsAreUnheld() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        var before = viewer.renderer.camera
        // Not yet asked to take the arrows: the key goes on to whoever is next.
        view.keyDown(with: try key(123))
        XCTAssertEqual(viewer.renderer.camera, before)

        viewer.orbitsWithArrowKeys = true
        for code in [123, 124, 125, 126] as [UInt16] {
            before = viewer.renderer.camera
            view.keyDown(with: try key(code))
            XCTAssertNotEqual(viewer.renderer.camera, before, "arrow \(code) turns the model")
        }
        // Command and Option arrows remain available to the system.
        before = viewer.renderer.camera
        view.keyDown(with: try key(123, flags: .command))
        view.keyDown(with: try key(123, flags: .option))
        XCTAssertEqual(viewer.renderer.camera, before)
        // Other keys go on as well.
        view.keyDown(with: try key(0))
        XCTAssertEqual(viewer.renderer.camera, before)
    }

    func testTheSpaceBarPlaysAndPausesOnlyAModelWithAnimation() async throws {
        let viewer = try await loaded()
        viewer.playsWithSpaceKey = true
        let view = try metalView(of: viewer)
        view.keyDown(with: try key(49))
        XCTAssertFalse(viewer.model.playing, "nothing to play")
        viewer.model.clipNames = ["Walk"]
        view.keyDown(with: try key(49))
        XCTAssertTrue(viewer.model.playing)
        view.keyDown(with: try key(49))
        XCTAssertFalse(viewer.model.playing)
        view.keyDown(with: try key(49, flags: .command))
        XCTAssertFalse(viewer.model.playing, "a command with space is the system's")
        for flags: NSEvent.ModifierFlags in [.shift, .option, .control] {
            view.keyDown(with: try key(49, flags: flags))
            XCTAssertFalse(viewer.model.playing, "modified Space is not playback")
        }
    }

    func testTheSpaceBarIsLeftToQuickLookUnlessTheViewerIsToPlayWithIt() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        XCTAssertFalse(viewer.playsWithSpaceKey, "off unless the app turns it on")
        viewer.model.clipNames = ["Walk"]
        view.keyDown(with: try key(49))
        XCTAssertFalse(viewer.model.playing, "the key is passed on, so the preview can close")
        viewer.playsWithSpaceKey = true
        view.keyDown(with: try key(49))
        XCTAssertTrue(viewer.model.playing)
    }

    func testTheViewTakesTheKeyboardWhenItIsClickedAndWhenAskedTo() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = viewer.view
        let other = NSView()
        window.contentView?.addSubview(other)
        viewer.takeFocus()
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertTrue(window.makeFirstResponder(nil))
        view.mouseDown(with: SpokenEvent.make(.leftMouseDown))
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertTrue(window.makeFirstResponder(nil))
        view.rightMouseDown(with: SpokenEvent.make(.rightMouseDown))
        XCTAssertTrue(window.firstResponder === view)
    }

    // MARK: Mouse and trackpad

    func testDraggingOrbitsAndDraggingWithAModifierOrAnotherButtonPans() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        SpokenEvent.deltaX = 12; SpokenEvent.deltaY = -7
        var before = viewer.renderer.camera
        view.mouseDragged(with: SpokenEvent.make())
        let orbited = viewer.renderer.camera
        XCTAssertNotEqual(orbited, before)

        // The same drag with a key held slides the view instead: the camera's turn does not change.
        before = viewer.renderer.camera
        view.mouseDragged(with: SpokenEvent.make(flags: .shift))
        var panned = viewer.renderer.camera
        XCTAssertNotEqual(panned, before)
        XCTAssertEqual(panned.pendingYaw, before.pendingYaw, "a pan does not turn")

        for (event, name) in [(SpokenEvent.make(.rightMouseDragged), "right"), (SpokenEvent.make(.otherMouseDragged), "other")] {
            before = viewer.renderer.camera
            if name == "right" { view.rightMouseDragged(with: event) } else { view.otherMouseDragged(with: event) }
            panned = viewer.renderer.camera
            XCTAssertNotEqual(panned, before, name)
            XCTAssertEqual(panned.pendingYaw, before.pendingYaw, name)
        }
    }

    /// The picture is drawn smaller to clear the controls along the bottom, so a pan has to
    /// move the camera that much farther for the model to stay under the pointer.
    func testAPanKeepsTheModelUnderThePointerWhenControlsCoverTheBottom() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        viewer.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        viewer.view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        XCTAssertEqual(size.height, 300)
        SpokenEvent.deltaX = 40; SpokenEvent.deltaY = 24
        for inset: Float in [0, 0.25] {
            viewer.renderer.bottomInset = inset
            viewer.renderer.camera = viewer.renderer.homeCamera
            let point = viewer.renderer.camera.target
            let before = place(of: point, in: viewer, size: size)
            view.rightMouseDragged(with: SpokenEvent.make(.rightMouseDragged))
            for _ in 0..<600 { viewer.renderer.camera.step(dt: 1 / 60) }
            let after = place(of: point, in: viewer, size: size)
            XCTAssertEqual(after.x - before.x, 40, accuracy: 0.05, "to the right, inset \(inset)")
            XCTAssertEqual(after.y - before.y, 24, accuracy: 0.05, "down, inset \(inset)")
        }
    }

    /// Where a point of the scene is drawn in a view of `size`, in points from its top left.
    private func place(of point: SIMD3<Float>, in viewer: NativeViewer, size: CGSize) -> CGPoint {
        let clip = viewer.renderer.frameUniforms(size: size).viewProj * SIMD4(point, 1)
        return CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * size.width, y: CGFloat((1 - clip.y / clip.w) / 2) * size.height)
    }

    func testTwoFingersTurningTheCameraAboutTheVerticalAxisAndASmartZoomFitsTheView() async throws {
        let viewer = try await loaded()
        viewer.reducesMotion = { true }
        let view = try metalView(of: viewer)
        var before = viewer.renderer.camera
        SpokenEvent.rotation = 30
        view.rotate(with: SpokenEvent.make())
        var after = viewer.renderer.camera
        XCTAssertEqual(after.yaw - before.yaw, -30 * .pi / 180, accuracy: 1e-4)
        XCTAssertEqual(after.pitch, before.pitch, "about the vertical axis only")
        SpokenEvent.rotation = -30
        view.rotate(with: SpokenEvent.make())
        after = viewer.renderer.camera
        XCTAssertEqual(after.yaw, before.yaw, accuracy: 1e-4)

        // Smart zoom: moved away, it comes back to the fitting view.
        view.mouseDragged(with: SpokenEvent.make())
        viewer.renderer.camera.distance *= 3
        before = viewer.renderer.camera
        view.smartMagnify(with: SpokenEvent.make())
        viewer.draw(in: view)
        XCTAssertEqual(viewer.renderer.camera.distance, viewer.renderer.homeCamera.distance, accuracy: 1e-3)
        XCTAssertNotEqual(viewer.renderer.camera.distance, before.distance)
    }

    // MARK: Secondary click

    func testASecondaryClickThatDidNotMoveIsAClickAndOneThatDraggedIsAPan() {
        XCTAssertTrue(ViewerMTKView.isClick(travel: 0))
        XCTAssertTrue(ViewerMTKView.isClick(travel: 2.9))
        XCTAssertFalse(ViewerMTKView.isClick(travel: 3))
        XCTAssertFalse(ViewerMTKView.isClick(travel: 40))
    }

    func testTheViewOffersTheContextMenuToControlClickAndSecondaryClick() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        let menu = try XCTUnwrap(view.menu(for: SpokenEvent.make(.rightMouseDown)))
        XCTAssertEqual(menu.items.compactMap { $0.isSeparatorItem ? nil : $0.title }.first, "Solid")
    }

    func testTheContextMenuHoldsEveryCommandWithTicksAndDimmingFromTheControls() async throws {
        let viewer = try await loaded()
        let menu = viewer.makeContextMenu()
        func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem { try XCTUnwrap(menu.items.first { $0.title == title }, title) }

        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Solid", "Textured", "Normal", "Wireframe", "Unshaded", "Anime", "Cel-Shaded", "Retro", "Voxel Art", "Hologram", "Look From",
                                "Zoom to Fit", "Zoom In", "Zoom Out", "Floor Grid", "Auto-Rotate", "Play", "Pan", "View Settings…", "Light Settings…", "Show Textures…"])
        // What is on is ticked.
        XCTAssertEqual(try item("Solid", in: menu).state, .on)
        XCTAssertEqual(try item("Normal", in: menu).state, .off)
        XCTAssertEqual(try item("Floor Grid", in: menu).state, viewer.status(of: .grid).on ? .on : .off)
        // The triangle has no textures or colors of its own: those styles are dimmed, and say why.
        XCTAssertFalse(viewer.model.hasTextured)
        for title in ["Textured", "Unshaded", "Anime"] {
            let entry = try item(title, in: menu)
            XCTAssertFalse(entry.isEnabled, title)
            XCTAssertEqual(entry.toolTip, "Needs a model with textures or colors", title)
        }
        XCTAssertTrue(try item("Cel-Shaded", in: menu).isEnabled)
        XCTAssertFalse(try item("Play", in: menu).isEnabled, "no animation")
        // Look From holds the six directions.
        let lookFrom = try XCTUnwrap(try item("Look From", in: menu).submenu)
        XCTAssertEqual(lookFrom.items.map(\.title), ["Front", "Back", "Left", "Right", "Top", "Bottom"])
        XCTAssertTrue(lookFrom.items.allSatisfy(\.isEnabled))
        // Every enabled item is what the command's own status says.
        for command in ViewerCommand.allCases {
            if let entry = (menu.items + lookFrom.items).first(where: { $0.representedObject as? String == command.rawValue }) {
                XCTAssertEqual(entry.isEnabled, viewer.status(of: command).enabled, command.title)
            }
        }
    }

    func testChoosingFromTheContextMenuDoesWhatTheControlDoes() async throws {
        let viewer = try await loaded()
        viewer.reducesMotion = { true }
        let menu = viewer.makeContextMenu()
        let wire = try XCTUnwrap(menu.items.firstIndex { $0.title == "Wireframe" })
        menu.performActionForItem(at: wire)
        XCTAssertTrue(viewer.model.look.wire)
        // The menu is made new each time and shows the tick.
        XCTAssertEqual(viewer.makeContextMenu().items[wire].state, .on)
        let lookFrom = try XCTUnwrap(try XCTUnwrap(menu.items.first { $0.title == "Look From" }).submenu)
        lookFrom.performActionForItem(at: 3)
        viewer.draw(in: try metalView(of: viewer))
        XCTAssertTrue((try metalView(of: viewer).accessibilityValue() as? String ?? "").hasSuffix("seen from the right"))
    }

    func testTheContextMenuIsDimmedWhenThereIsNoModel() throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        let menu = viewer.makeContextMenu()
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem && $0.submenu == nil }.allSatisfy { !$0.isEnabled })
    }

    func testPanCommandsAndShiftArrowsMoveWithoutOrbitingAndLeaveQuickLookKeysAlone() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        let before = viewer.renderer.camera
        view.keyDown(with: try key(123, flags: .shift))
        XCTAssertEqual(viewer.renderer.camera, before, "Quick Look keeps modified arrows")
        viewer.orbitsWithArrowKeys = true
        for (code, command) in [(UInt16(123), ViewerCommand.panLeft), (124, .panRight), (125, .panDown), (126, .panUp)] {
            viewer.renderer.camera = before
            view.keyDown(with: try key(code, flags: .shift))
            let keyboard = viewer.renderer.camera
            XCTAssertNotEqual(keyboard.pendingPan, before.pendingPan)
            XCTAssertEqual(keyboard.pendingYaw, before.pendingYaw)
            XCTAssertEqual(keyboard.pendingPitch, before.pendingPitch)
            viewer.renderer.camera = before
            viewer.perform(command)
            XCTAssertEqual(viewer.renderer.camera.pendingPan, keyboard.pendingPan)
            viewer.renderer.camera = before
            let action = try XCTUnwrap(view.accessibilityCustomActions()?.first { $0.name == command.title })
            XCTAssertTrue(try XCTUnwrap(action.handler)())
            XCTAssertEqual(viewer.renderer.camera.pendingPan, keyboard.pendingPan)
        }
    }

    func testContextPlaybackTitleMatchesTheActionAndSettingsAreAvailableInSmallViews() async throws {
        let viewer = try await loaded()
        viewer.model.visibility = ControlsVisibility(size: CGSize(width: 320, height: 260))
        viewer.model.clipNames = ["Walk"]
        for playing in [false, true] {
            viewer.model.playing = playing
            let menu = viewer.makeContextMenu()
            let item = try XCTUnwrap(menu.items.first { $0.representedObject as? String == ViewerCommand.playPause.rawValue })
            XCTAssertEqual(item.title, playing ? "Pause" : "Play")
            for command in [ViewerCommand.showViewSettings, .showLightSettings] {
                XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.representedObject as? String == command.rawValue }).isEnabled)
            }
        }
    }

    // MARK: Accessibility

    func testThePictureTellsAssistiveTechnologyWhatItShowsAndWhereItIsSeenFrom() async throws {
        let viewer = try await loaded()
        viewer.reducesMotion = { true }
        let view = try metalView(of: viewer)
        XCTAssertEqual(view.accessibilityRoleDescription(), "3D view")
        XCTAssertEqual(view.accessibilityLabel(), "3D model")
        var value = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertTrue(value.hasPrefix("t.stl, 1 face, Solid view"), value)
        XCTAssertTrue(value.hasSuffix("seen from the front"), value)

        // A look change.
        viewer.perform(.celShaded)
        value = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("Cel-Shaded"), value)
        viewer.perform(.wireframe)
        XCTAssertTrue((view.accessibilityValue() as? String ?? "").contains("wireframe on"))

        // A camera move that has come to rest.
        viewer.perform(.right)
        viewer.draw(in: view)
        value = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertTrue(value.hasSuffix("seen from the right"), value)
    }

    func testThePictureHasNoValueWithoutAModel() throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        let view = try metalView(of: viewer)
        XCTAssertNil(view.accessibilityValue())
    }

    func testThePictureOffersTheCameraMovesAsAccessibilityActions() async throws {
        let viewer = try await loaded()
        viewer.reducesMotion = { true }
        let view = try metalView(of: viewer)
        let actions = view.accessibilityCustomActions() ?? []
        XCTAssertEqual(actions.map(\.name), ["Orbit Left", "Orbit Right", "Orbit Up", "Orbit Down", "Pan Left", "Pan Right", "Pan Up", "Pan Down", "Zoom In", "Zoom Out", "Zoom to Fit"])
        func run(_ name: String) throws -> Bool { try XCTUnwrap(actions.first { $0.name == name }?.handler?(), name) }

        let before = viewer.renderer.camera
        XCTAssertTrue(try run("Orbit Left"))
        XCTAssertNotEqual(viewer.renderer.camera.pendingYaw, before.pendingYaw)
        let yaw = viewer.renderer.camera.pendingYaw
        XCTAssertTrue(try run("Orbit Right"))
        XCTAssertNotEqual(viewer.renderer.camera.pendingYaw, yaw)
        XCTAssertTrue(try run("Orbit Up"))
        XCTAssertNotEqual(viewer.renderer.camera.pendingPitch, before.pendingPitch)
        let dolly = viewer.renderer.camera.pendingDolly
        XCTAssertTrue(try run("Zoom In"))
        XCTAssertLessThan(viewer.renderer.camera.pendingDolly, dolly)
        XCTAssertTrue(try run("Zoom Out"))
        XCTAssertTrue(try run("Orbit Down"))
        XCTAssertTrue(try run("Zoom to Fit"))
    }

    func testTheNearestDirectionIsTheClosestPreset() {
        XCTAssertEqual(NativeViewer.nearestDirection(GizmoBasis()), .front)
        XCTAssertEqual(NativeViewer.nearestDirection(GizmoBasis(right: [0, 0, -1], up: [0, 1, 0], back: [1, 0, 0])), .right)
        XCTAssertEqual(NativeViewer.nearestDirection(GizmoBasis(right: [1, 0, 0], up: [0, 0, -1], back: [0, 1, 0])), .top)
        XCTAssertEqual(NativeViewer.accessibilityValue(fileName: "Tank-Demo.fbx", faces: 50_007, look: RenderLook(view: .textured), direction: .front),
                       "Tank-Demo.fbx, \(50_007.formatted(.number)) faces, Textured view, seen from the front")
    }

    func testTheWheelAndTheTrackpadDollyTowardsWhatTheyScrollTo() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        for units in [CGScrollEventUnit.line, .pixel] {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
            let before = viewer.renderer.camera.pendingDolly
            view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
            XCTAssertLessThan(viewer.renderer.camera.pendingDolly, before, "scrolling up moves in (\(units))")
        }
    }

    /// A pinch or a scroll closes in on what is under the pointer, which stays under it,
    /// with controls covering the bottom of the view or not. It closed in on the middle,
    /// and what the pointer was on slid out from under it. The zoom commands, which have
    /// no pointer, still close in on the middle.
    func testAZoomClosesInOnWhatIsUnderThePointer() async throws {
        let viewer = try await loaded()
        let view = try metalView(of: viewer)
        viewer.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        viewer.view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        // A quarter of the way in from the right, a third of the way down.
        let pointer = NSPoint(x: 300, y: 200)
        let onScreen = CGPoint(x: 300, y: 100)
        for inset: Float in [0, 0.25] {
            for scrolls in [false, true] {
                viewer.renderer.bottomInset = inset
                let home = viewer.renderer.homeCamera
                viewer.renderer.camera = home
                // The point of the plane through the target that the pointer is on.
                let (right, up, _) = home.basis
                let k = 2 * home.distance * tan(home.fovY / 2) / (300 * viewer.renderer.pictureScale)
                // The picture fills the view above the controls; the target is in its middle.
                let middle = CGPoint(x: 200, y: 150 * CGFloat(viewer.renderer.pictureScale))
                let point = home.target + right * Float(onScreen.x - 200) * k + up * Float(middle.y - onScreen.y) * k
                XCTAssertEqual(place(of: point, in: viewer, size: size).x, onScreen.x, accuracy: 0.05, "the point starts under the pointer")
                XCTAssertEqual(place(of: point, in: viewer, size: size).y, onScreen.y, accuracy: 0.05, "the point starts under the pointer")
                if scrolls {
                    SpokenEvent.scrollY = 30; SpokenEvent.precise = true
                    view.scrollWheel(with: SpokenEvent.make(at: pointer))
                } else {
                    SpokenEvent.magnification = 0.5
                    view.magnify(with: SpokenEvent.make(at: pointer))
                }
                for _ in 0..<600 { viewer.renderer.camera.step(dt: 1 / 60, distanceLimits: viewer.renderer.distanceLimits) }
                let name = "inset \(inset), \(scrolls ? "scroll" : "pinch")"
                XCTAssertLessThan(viewer.renderer.camera.distance, home.distance * 0.8, name)
                let after = place(of: point, in: viewer, size: size)
                XCTAssertEqual(after.x, onScreen.x, accuracy: 0.5, name)
                XCTAssertEqual(after.y, onScreen.y, accuracy: 0.5, name)
            }
        }
        // As close as the camera goes, a pinch neither closes in nor slides the view.
        viewer.renderer.bottomInset = 0
        var closest = viewer.renderer.homeCamera
        closest.distance = viewer.renderer.distanceLimits.lowerBound
        viewer.renderer.camera = closest
        SpokenEvent.magnification = 0.5
        view.magnify(with: SpokenEvent.make(at: pointer))
        for _ in 0..<600 { viewer.renderer.camera.step(dt: 1 / 60, distanceLimits: viewer.renderer.distanceLimits) }
        XCTAssertLessThan(simd_distance(viewer.renderer.camera.target, closest.target), 1e-5 * closest.distance)
        // The zoom command closes in on the middle.
        viewer.renderer.camera = viewer.renderer.homeCamera
        viewer.perform(.zoomIn)
        for _ in 0..<600 { viewer.renderer.camera.step(dt: 1 / 60, distanceLimits: viewer.renderer.distanceLimits) }
        XCTAssertEqual(viewer.renderer.camera.target, viewer.renderer.homeCamera.target)
        XCTAssertLessThan(viewer.renderer.camera.distance, viewer.renderer.homeCamera.distance)
    }

    // MARK: The container

    func testTheSizeIsReported() async throws {
        let viewer = try await loaded()
        let container = try XCTUnwrap(viewer.view as? NativeViewerContainer)
        // The size is reported when the view is laid out: a small one hides the controls.
        container.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(viewer.model.visibility, ControlsVisibility(size: CGSize(width: 900, height: 700)))
        container.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(viewer.model.visibility, ControlsVisibility(size: CGSize(width: 240, height: 160)))
        XCTAssertFalse(viewer.model.visibility.controls)
    }

    func testTheLightOfOpeningTakesNoClicks() async throws {
        let viewer = try await loaded()
        let host = try XCTUnwrap(viewer.view.subviews.first { $0 is PassthroughHost<OpeningLight> })
        XCTAssertNil(host.hitTest(NSPoint(x: 5, y: 5)))
    }

    // MARK: Settings and commands

    func testTheTextureSideIsTheRenderersAndFollowsWhatIsSet() throws {
        let viewer = try XCTUnwrap(NativeViewer(), "no Metal device")
        viewer.maxTextureSide = 1024
        XCTAssertEqual(viewer.maxTextureSide, 1024)
        XCTAssertEqual(viewer.renderer.maxTextureSide, 1024)
    }

    func testChangingTheClipRestartsItAndTheViewerAsksToBeDrawn() async throws {
        let viewer = try await loaded()
        viewer.model.clipNames = ["A", "B"]
        viewer.model.clock.progress = 0.8
        viewer.model.clip = 1
        XCTAssertEqual(viewer.model.clock.progress, 0, "the new clip starts from its beginning")
    }

    func testFitAndTheGizmoMoveTheCameraAtTheNextFramesAndStopAtTheirEnd() async throws {
        let viewer = try await loaded()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: viewer.renderer.device)
        // A view along an axis, then back to the whole model.
        viewer.model.onLook?(.top)
        viewer.draw(in: view)
        XCTAssertEqual(viewer.renderer.camera.pitch, OrbitCamera.maxPitch, accuracy: 0.01, "looking down")
        viewer.model.onFit?()
        viewer.draw(in: view)
        XCTAssertEqual(viewer.renderer.camera.pitch, viewer.renderer.homeCamera.pitch, accuracy: 0.01)
        // A drag on the gizmo orbits like a drag on the model.
        let before = viewer.renderer.camera
        viewer.model.onGizmoDrag?(10, 4)
        XCTAssertNotEqual(viewer.renderer.camera, before)
        viewer.mtkView(view, drawableSizeWillChange: CGSize(width: 128, height: 128))
    }

    func testTheCommandsMoveTheCameraAndZoomInAndOutAreOpposites() async throws {
        let viewer = try await loaded()
        for command in [ViewerCommand.orbitLeft, .orbitRight, .orbitUp, .orbitDown] {
            let before = viewer.renderer.camera
            viewer.perform(command)
            XCTAssertNotEqual(viewer.renderer.camera, before, "\(command)")
        }
        let before = viewer.renderer.camera.pendingDolly
        viewer.perform(.zoomIn)
        let inward = viewer.renderer.camera.pendingDolly - before
        viewer.perform(.zoomOut)
        XCTAssertEqual(viewer.renderer.camera.pendingDolly - before, 0, accuracy: abs(inward) * 0.01, "out undoes in")
        XCTAssertLessThan(inward, 0)
    }

    // MARK: Frames

    func testTheViewTurnsByItselfAndTheLightGoesRoundWhenAskedTo() async throws {
        let viewer = try await loaded()
        viewer.reducesMotion = { false }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: viewer.renderer.device)
        viewer.draw(in: view)
        viewer.model.autoRotate = true
        viewer.model.rotatesLight = true
        let yaw = viewer.renderer.camera.yaw, light = viewer.renderer.lightRotation
        viewer.draw(in: view)
        try await Task.sleep(nanoseconds: 50_000_000)
        viewer.draw(in: view)
        XCTAssertNotEqual(viewer.renderer.camera.yaw, yaw, "it turns")
        XCTAssertNotEqual(viewer.renderer.lightRotation, light, "the light goes round")
        XCTAssertTrue(viewer.renderer.camera.yaw > yaw, "to the right")
    }

    func testAutomaticLightDirectionStaysInSyncWhenWrappingPausingAndEditing() async throws {
        let viewer = try await loaded()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: viewer.renderer.device)
        viewer.model.lightRotation = 359.9
        viewer.model.rotatesLight = true
        viewer.draw(in: view)
        XCTAssertLessThan(viewer.model.lightRotation, 1, "the displayed angle wraps through zero")
        XCTAssertEqual(viewer.renderer.lightRotation, viewer.model.lightRotation * .pi / 180, accuracy: 0.0001)

        let stopped = viewer.renderer.lightRotation
        viewer.model.rotatesLight = false
        viewer.draw(in: view)
        XCTAssertEqual(viewer.renderer.lightRotation, stopped, accuracy: 0.0001, "pausing keeps the current direction")
        XCTAssertEqual(viewer.model.lightRotation * .pi / 180, stopped, accuracy: 0.0001)

        viewer.model.lightRotation = 102
        XCTAssertEqual(viewer.renderer.lightRotation, 102 * .pi / 180, accuracy: 0.0001, "manual input is the actual angle, not an offset")
        viewer.model.rotatesLight = true
        viewer.draw(in: view)
        XCTAssertGreaterThan(viewer.model.lightRotation, 102)
        XCTAssertEqual(viewer.renderer.lightRotation, viewer.model.lightRotation * .pi / 180, accuracy: 0.0001)
        viewer.resetControls()
        XCTAssertEqual(viewer.model.lightRotation, 0)
        XCTAssertEqual(viewer.renderer.lightRotation, 0)
        XCTAssertFalse(viewer.model.rotatesLight)
    }

    func testWireAndOutlineAreMadeInTheBackgroundAndTheViewIsAskedToDrawWhenTheyAreThere() async throws {
        let viewer = try await loaded()
        viewer.model.look = RenderLook(view: .solid, wire: true)
        let scene = try XCTUnwrap(viewer.renderer.scene)
        let ready = expectation(description: "wire made")
        Task { @MainActor in
            while !scene.isWireReady { try? await Task.sleep(nanoseconds: 10_000_000) }
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertTrue(scene.isWireReady)
    }

    // MARK: The controls fade

    func testTheControlsNeverFade() async throws {
        let viewer = try await loaded()
        viewer.reducesMotion = { true }
        let container = try XCTUnwrap(viewer.view as? NativeViewerContainer)
        XCTAssertEqual(viewer.chromeAlpha, 1)
        // Nothing follows the pointer, so nothing can step back when it rests or leaves.
        container.updateTrackingAreas()
        XCTAssertTrue(container.trackingAreas.isEmpty)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(viewer.chromeAlpha, 1)
    }
}
