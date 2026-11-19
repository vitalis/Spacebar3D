import SwiftUI
import ViewerUI
import XCTest

/// The keys of the menu commands: which key does what, and that no two commands share one.
final class ViewerShortcutsTests: XCTestCase {
    private func keys(_ command: ViewerCommand) -> String? {
        guard let shortcut = ViewerShortcuts.shortcut(for: command) else { return nil }
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "ctrl+" }
        if shortcut.modifiers.contains(.option) { text += "opt+" }
        if shortcut.modifiers.contains(.shift) { text += "shift+" }
        if shortcut.modifiers.contains(.command) { text += "cmd+" }
        return text + String(shortcut.key.character)
    }

    func testEveryCommandHasTheKeyTheMenuShows() {
        let expected: [ViewerCommand: String] = [
            // The first three views and the wireframe, on the digits in the menu's order.
            .solid: "cmd+1", .textured: "cmd+2", .normal: "cmd+3", .wireframe: "cmd+4",
            // The standard keys for zooming.
            .fit: "cmd+0", .zoomIn: "cmd++", .zoomOut: "cmd+-",
            .grid: "opt+cmd+g", .autoRotate: "opt+cmd+r",
        ]
        // The rest are in the menus only; the viewer takes the arrows itself.
        for command in ViewerCommand.allCases where expected[command] == nil {
            XCTAssertNil(ViewerShortcuts.shortcut(for: command), command.rawValue)
        }
        for (command, key) in expected { XCTAssertEqual(keys(command), key, command.rawValue) }
        XCTAssertNil(ViewerShortcuts.shortcut(for: .playPause), "Space must reach the focused control")
    }

    /// Few keys, and Option only with letters (the Human Interface Guidelines).
    func testOnlyTheMostUsedCommandsHaveKeysAndOptionGoesWithLettersOnly() {
        let withKeys = ViewerCommand.allCases.filter { ViewerShortcuts.shortcut(for: $0) != nil }
        XCTAssertEqual(withKeys.count, 9)
        for command in withKeys {
            guard let shortcut = ViewerShortcuts.shortcut(for: command), shortcut.modifiers.contains(.option) else { continue }
            XCTAssertTrue(shortcut.key.character.isLetter, command.rawValue)
        }
        for command in [ViewerCommand.unlit, .anime, .celShaded, .retro, .voxel, .hologram, .front, .back, .left, .right, .top, .bottom] {
            XCTAssertNil(ViewerShortcuts.shortcut(for: command), command.rawValue)
        }
    }

    func testNoTwoCommandsShareAKey() {
        let used = ViewerCommand.allCases.compactMap(keys)
        XCTAssertEqual(Set(used).count, used.count, "\(used)")
    }

    /// Every key is held with Command, so none is taken from a text field or a slider, and
    /// none is one the app or the system already uses.
    func testTheKeysLeaveTheAppsAndTheSystemsOwnAlone() {
        let taken = ["cmd+o", "cmd+q", "cmd+w", "cmd+h", "cmd+m", "cmd+,", "opt+cmd+h", "opt+cmd+w", "opt+cmd+d", "opt+cmd+m"]
        for command in ViewerCommand.allCases {
            guard let shortcut = ViewerShortcuts.shortcut(for: command), let keys = keys(command) else { continue }
            XCTAssertTrue(shortcut.modifiers.contains(.command), command.rawValue)
            XCTAssertFalse(taken.contains(keys), "\(command.rawValue) takes \(keys)")
        }
    }

    /// The menus show each command once: in a group, under Look From, Orbit or Mood, as a
    /// shading or a panel, in the Playback menu, or in the File menu.
    func testTheMenuOffersEveryCommandOnce() {
        let shown = ViewerCommands.groups.flatMap { $0 } + ViewerCommands.directions + ViewerCommands.turns
            + ViewerCommands.pans + ViewerCommands.shadings + ViewerCommands.moods + ViewerCommands.panels + [.playPause, .repeatClip, .showTextures]
        XCTAssertEqual(shown.count, Set(shown).count)
        XCTAssertEqual(Set(shown), Set(ViewerCommand.allCases))
    }

    /// The groups are the looks bar's: the views, the wireframe, the styles; then what is
    /// switched on and off; then the zoom. The digits run through the first views.
    func testTheMenusGroupsAndTheirDigits() {
        XCTAssertEqual(ViewerCommands.groups, [
            [.solid, .textured, .normal], [.wireframe], [.unlit, .anime, .celShaded, .retro, .voxel, .hologram],
            [.grid, .autoRotate], [.fit, .zoomIn, .zoomOut],
        ])
        let views = ViewerCommands.groups.prefix(2).flatMap { $0 }
        XCTAssertEqual(views.map(keys), (1...4).map { "cmd+\($0)" })
        XCTAssertEqual(ViewerCommands.turns, [.orbitLeft, .orbitRight, .orbitUp, .orbitDown])
        XCTAssertEqual(ViewerCommands.moods.map(\.title), ["Glasshouse", "Dawn", "Noon", "Golden Hour", "Overcast", "Moonlit", "Neon"], "the light panel's moods, in its order")
    }
}
