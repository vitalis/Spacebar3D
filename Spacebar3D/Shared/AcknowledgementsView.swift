import ModelCore
import SwiftUI
import ViewerUI

/// The window behind the Help menu's Acknowledgements item.
struct AcknowledgementsView: View {
    static let windowID = "acknowledgements"

    let text: String

    init(text: String = Acknowledgements.text()) { self.text = text }

    var body: some View {
        ScrollView {
            Text(text)
                .font(GardenTypography.monospaced)
                .foregroundStyle(NeonGarden.text2.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The menu item; a view, because opening a window needs the scene's environment.
struct AcknowledgementsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.text("Acknowledgements")) { openWindow(id: AcknowledgementsView.windowID) }
    }
}
