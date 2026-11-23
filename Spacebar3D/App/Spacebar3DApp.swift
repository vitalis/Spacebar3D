import ModelCore
import SwiftUI
import ViewerUI

/// The host app.
/// A Quick Look extension must be shipped inside an app; this one explains the setup
/// and hosts the preview settings (also reachable via the Settings… menu item). It can
/// also open model files in its own viewer window (File > Open…, or "Open With" in Finder).
@main
struct Spacebar3DApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Spacebar 3D") { MainWindow() }
        // Opened files go to the app delegate's viewer windows; without this SwiftUI
        // would also open another copy of this window for every file.
        .handlesExternalEvents(matching: [])
        // The window holds what it has to say and no more.
        .windowResizability(.contentSize)
        .commands {
            // This app has no documents to create; File > New becomes File > Open….
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("Open…")) { ModelViewerWindowController.runOpenPanel() }
                    .keyboardShortcut("o")
            }
            // One built-in page of help, not a help book; then, apart, the licences of the app
            // and of the code linked into it.
            CommandGroup(replacing: .help) { HelpMenuItems() }
            // Everything the controls on the canvas do, in the menu bar and on the keys.
            ViewerCommands(focus: .shared)
        }

        Window(L10n.text("Privacy Policy"), id: PrivacyPolicyView.windowID) {
            PrivacyPolicyView().frame(minWidth: 360, minHeight: 300).gardenWindow()
        }
        .defaultSize(width: 640, height: 620)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Window(L10n.text("Acknowledgements"), id: AcknowledgementsView.windowID) {
            AcknowledgementsView().frame(minWidth: 560, minHeight: 420).gardenWindow()
        }
        .defaultSize(width: 640, height: 600)
        // Not a window to find open again at the next launch.
        .restorationBehavior(.disabled)
        // Nor one to open by itself: launched with a file to show, the app has no window of
        // its first kind to open, and would otherwise open this one.
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Window(L10n.text("Spacebar 3D Help"), id: HelpView.windowID) {
            HelpView().frame(minWidth: 460, minHeight: 360).gardenWindow()
        }
        .defaultSize(width: 560, height: 600)
        // The same as Acknowledgements: not found open again at the next launch, and not
        // opened by itself when the app is launched with a file to show.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .frame(width: 560, height: 640)
                .gardenWindow()
        }
    }
}

/// The app's own window: what the app is and how to get a preview, on a page of squared
/// paper. The settings are one button away, in the Settings window.
struct MainWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            ContentView()
            SettingsLink { Text(L10n.text("Settings…")) }
                .font(GardenTypography.body)
                .padding(.bottom, 20)
        }
        .frame(width: 560)
        // A page of squared paper.
        .background(GraphPaper())
        .gardenWindow()
    }
}

struct ContentView: View {
    /// What the buttons do: show the open panel, and System Settings; tests pass their own.
    var openModel: () -> Void = { ModelViewerWindowController.runOpenPanel() }
    var openExtensionSettings: () -> Void = { NSWorkspace.shared.open(ContentView.extensionSettingsURL) }

    /// System Settings > General > Login Items & Extensions. The pane's identifier is the one
    /// System Settings itself declares for it (with "com.apple.ExtensionsPreferences" as an
    /// alias). A link straight to the Quick Look list is not documented, so this opens the page.
    static let extensionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                // Leave room for the artwork's glow without an oversized title block.
                NeonMark()
                    .frame(width: 104, height: 104)
                    .frame(height: 156)

                Text("Spacebar 3D")
                    .font(GardenTypography.title)

                Text(L10n.text("Select a supported 3D file in Finder and press Space."))
                    .font(GardenTypography.body)
                    .foregroundStyle(NeonGarden.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(L10n.text("Open a Model…")) { openModel() }
                .controlSize(.large)

            Divider()

            VStack(spacing: 10) {
                Text(L10n.text("Enable Spacebar 3D in System Settings > General > Login Items & Extensions > Quick Look."))
                    .foregroundStyle(NeonGarden.text2.color)
                Button(L10n.text("Open System Settings")) { openExtensionSettings() }
            }
            .font(GardenTypography.body)
            .fixedSize(horizontal: false, vertical: true)

            Text(L10n.text("OBJ, STL, PLY, USD and USDZ may use macOS's own preview. Use Open a Model… to view them here."))
                .font(GardenTypography.supporting)
                .foregroundStyle(NeonGarden.text2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(GardenTypography.body)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

extension View {
    /// A window of the app in the viewer's look: the palette's darkest green behind
    /// everything, dark whatever the system's appearance, mint for what is on.
    func gardenWindow() -> some View {
        scrollContentBackground(.hidden)
            .background(NeonGarden.background.color)
            .containerBackground(NeonGarden.background.color, for: .window)
            .neonGarden()
            .buttonStyle(GardenActionButtonStyle())
            .preferredColorScheme(.dark)
    }
}
