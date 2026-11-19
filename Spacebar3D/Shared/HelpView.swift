import ModelCore
import SwiftUI
import ViewerUI

/// The window behind Help > Spacebar 3D Help: one short page, not a help book.
struct HelpView: View {
    static let windowID = "help"
    var showsPrivacyLink = true

    /// The page's sections, in order: a heading and its lines.
    static let sections: [(title: String, lines: [String])] = [
        (L10n.text("Supported formats"), [
            L10n.text("Open OBJ, STL, PLY, 3MF, USD, USDA, USDC, USDZ, 3DS, glTF, GLB, FBX, Blender, VRM and VRMA files with File > Open… or Finder's Open With > Spacebar 3D."),
        ]),
        (L10n.text("Default app"), [
            L10n.text("In Settings, choose Make Default… to open models with Spacebar 3D when you double-click them in Finder. This does not change Quick Look previews."),
        ]),
        (L10n.text("Controls on the canvas"), [
            L10n.text("The bar at the bottom chooses the view (Solid, Textured, Normal), the wireframe, the styles and the view settings."),
            L10n.text("At the top right, the gizmo looks along an axis when you click it. Below it are zoom to fit, the light, the floor grid and auto-rotate."),
            L10n.text("A model with animation has playback, position and repeat controls. A clip menu appears when the file has more than one animation."),
            L10n.text("The app's View and Playback menus provide viewing and playback commands."),
        ]),
        (L10n.text("Pointer"), [
            L10n.text("Drag to turn the model. Drag with Shift, Option or Command held, or with the right button, to move it."),
            L10n.text("Pinch, or scroll, to zoom."),
        ]),
        (L10n.text("Keys"), [
            L10n.text("In the app, Shift-arrow keys pan the model. You can also use View > Pan."),
            L10n.text("The arrow keys turn the model. In the app, Space plays or pauses animation. In Quick Look, Space closes the preview."),
            L10n.text("Command-1 to 4 choose the view and the wireframe. Command-0 zooms to fit. Command-plus and Command-minus zoom."),
            L10n.text("Option-Command-G shows the floor grid. Option-Command-R turns the model by itself."),
        ]),
        (L10n.text("Textures in other files"), [
            L10n.text("A model may reference separate data, material or texture files. Use the notice's Show Model…, Show Materials… or Show Textures… button to allow the model's folder. In the app, File > Show Textures… opens the same folder chooser. This grants read-only access."),
        ]),
        (L10n.text("Quick Look"), [
            L10n.text("To preview models in Finder, turn on Spacebar 3D in System Settings > General > Login Items & Extensions > Quick Look."),
            L10n.text("For OBJ, STL, PLY, USD and USDZ files, macOS may use its own preview. To view them in Spacebar 3D, choose File > Open… or Finder's Open With > Spacebar 3D."),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(GardenTypography.heading)
                        ForEach(section.lines, id: \.self) { line in
                            Text(line)
                                .foregroundStyle(NeonGarden.text2.color)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if showsPrivacyLink { PrivacyPolicyLink().buttonStyle(.link) }
            }
            .font(GardenTypography.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Help menu's items: the help page and where to ask for help, then, after a
/// separator, the licences.
struct HelpMenuItems: View {
    var body: some View {
        HelpMenuItem()
        SupportMenuItem()
        Divider()
        PrivacyPolicyLink()
        AcknowledgementsMenuItem()
    }
}

/// The Help menu's item; a view, because opening a window needs the scene's environment.
struct HelpMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.text("Spacebar 3D Help")) { openWindow(id: HelpView.windowID) }
    }
}

/// The Help menu's Support item: the project's issue tracker, in the browser.
struct SupportMenuItem: View {
    /// Where questions and problems are reported.
    static let url = URL(string: "https://github.com/vitalis/Spacebar3D/issues")!
    /// What choosing the item does: opens the page; tests pass their own.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        Button(L10n.text("Spacebar 3D Support")) { open(Self.url) }
    }
}
