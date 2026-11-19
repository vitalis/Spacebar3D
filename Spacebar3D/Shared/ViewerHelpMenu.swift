import ModelCore
import SwiftUI
import ViewerUI

struct ViewerHelpMenu: View {
    enum Page: CaseIterable, Identifiable {
        case help, privacy, acknowledgements
        var id: Self { self }
        var title: String {
            switch self {
            case .help: L10n.text("Spacebar 3D Help")
            case .privacy: L10n.text("Privacy Policy")
            case .acknowledgements: L10n.text("Acknowledgements")
            }
        }
    }

    let present: (AnyView?) -> Void
    @State private var showsMenu = false
    var body: some View {
        Button { showsMenu.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(GardenTypography.heading)
                .frame(minWidth: NeonGarden.stickerSize, minHeight: NeonGarden.stickerSize)
        }
        .gardenButton()
        .accessibilityLabel(L10n.text("Spacebar 3D Help"))
        .help(L10n.text("Spacebar 3D Help"))
        .popover(isPresented: $showsMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            HelpMenuRows { item in
                showsMenu = false
                present(AnyView(ViewerHelpDocument(page: item) { present(nil) }))
            }
        }
    }
}

private struct HelpMenuRows: View {
    typealias Page = ViewerHelpMenu.Page
    let select: (Page) -> Void
    @State private var hovered: Page?
    @FocusState private var focusedItem: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases) { item in
                Button {
                    select(item)
                } label: {
                    Text(item.title)
                        .font(GardenTypography.action)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(hovered == item ? NeonGarden.surface3.color : .clear,
                                    in: RoundedRectangle(cornerRadius: NeonGarden.controlRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: NeonGarden.controlRadius)
                                .strokeBorder(NeonGarden.mint.color, lineWidth: focusedItem == item ? 2 : 0)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($focusedItem, equals: item)
                .onHover { inside in hovered = inside ? item : nil }
            }
        }
        .onAppear { focusedItem = .help }
        .onMoveCommand { direction in
            guard direction == .up || direction == .down else { return }
            let pages = Page.allCases
            let index = focusedItem.flatMap { pages.firstIndex(of: $0) } ?? 0
            let step = direction == .down ? 1 : -1
            focusedItem = pages[(index + step + pages.count) % pages.count]
        }
        .fixedSize()
        .padding(8)
        .foregroundStyle(NeonGarden.text.color)
        .presentationBackground(NeonGarden.surface.color)
        .neonGarden()
    }
}

private struct ViewerHelpDocument: View {
    let page: ViewerHelpMenu.Page
    let close: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.52).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(page.title).font(GardenTypography.heading)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(L10n.text("Close"), action: close)
                        .buttonStyle(GardenActionButtonStyle())
                        .overlay {
                            RoundedRectangle(cornerRadius: NeonGarden.controlRadius)
                                .strokeBorder(NeonGarden.mint.color, lineWidth: closeFocused ? 2 : 0)
                        }
                        .focusEffectDisabled()
                        .keyboardShortcut(.cancelAction)
                        .focused($closeFocused)
                }
                .padding(16)
                Divider()
                switch page {
                case .help: HelpView(showsPrivacyLink: false)
                case .privacy: PrivacyPolicyView()
                case .acknowledgements: AcknowledgementsView()
                }
            }
            .frame(maxWidth: 640, maxHeight: 600)
            .background(NeonGarden.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: NeonGarden.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: NeonGarden.panelRadius)
                    .strokeBorder(NeonGarden.border(increased: contrast == .increased))
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(NeonGarden.text.color)
        .neonGarden()
        .onAppear { closeFocused = true }
    }
}
