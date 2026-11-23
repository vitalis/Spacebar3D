import ModelCore
import SwiftUI
import ViewerUI

struct PrivacyPolicyLink: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.text("Privacy Policy")) { openWindow(id: PrivacyPolicyView.windowID) }
    }
}

struct PrivacyPolicyView: View {
    static let windowID = "privacy-policy"
    private let lines: [String]

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "PRIVACY", withExtension: "md"),
           let policy = try? String(contentsOf: url, encoding: .utf8) {
            lines = policy.components(separatedBy: .newlines).filter { !$0.isEmpty }
        } else {
            lines = [L10n.format("%@ is missing from this copy of the app.", "PRIVACY.md")]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("# ") {
                        Text(String(line.dropFirst(2)))
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                    } else if line.hasPrefix("## ") {
                        Text(String(line.dropFirst(3)))
                            .font(GardenTypography.heading)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                    } else if line.hasPrefix("- ") {
                        HStack(alignment: .firstTextBaseline) {
                            Text("•").accessibilityHidden(true)
                            paragraph(String(line.dropFirst(2)))
                        }
                    } else {
                        paragraph(line)
                    }
                }
            }
            .font(GardenTypography.body)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: 580, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paragraph(_ markdown: String) -> Text {
        Text((try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnly))) ?? AttributedString(markdown))
    }
}
