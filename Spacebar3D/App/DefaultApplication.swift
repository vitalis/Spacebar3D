import ModelCore
import AppKit
import UniformTypeIdentifiers
import SwiftUI
import ViewerUI

/// Changes Finder's opening app only when requested, independently of Quick Look.
@MainActor
final class DefaultApplication: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var message: String?

    private let extensions: [String]
    private let applicationURL: URL
    private let resolve: (String) -> [UTType]
    private let setDefault: (URL, UTType) async throws -> Void
    private let currentDefault: (UTType) -> URL?
    private let isOurApp: (URL) -> Bool

    init(
        extensions: [String]? = nil,
        applicationURL: URL = Bundle.main.bundleURL,
        resolve: @escaping (String) -> [UTType] = {
            UTType.types(tag: $0, tagClass: .filenameExtension, conformingTo: nil)
        },
        setDefault: @escaping (URL, UTType) async throws -> Void = {
            try await NSWorkspace.shared.setDefaultApplication(at: $0, toOpen: $1)
        },
        currentDefault: @escaping (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        isOurApp: @escaping (URL) -> Bool = { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier }
    ) {
        self.extensions = extensions ?? ModelViewerWindowController.fileExtensions
        self.applicationURL = applicationURL
        self.resolve = resolve
        self.setDefault = setDefault
        self.currentDefault = currentDefault
        self.isOurApp = isOurApp
    }

    func makeDefault() async {
        guard !isRunning else { return }
        isRunning = true
        message = nil
        defer { isRunning = false }

        var results: [String: Bool] = [:]
        var failed: [String] = []
        for ext in extensions {
            // Other installed apps may declare a second UTI for the same extension.
            // Set every concrete type, but never claim generic data or sidecar formats.
            let types = resolve(ext).filter { !$0.isDynamic && $0 != .data && $0 != .item }
            var succeeded = !types.isEmpty
            for type in types {
                if results[type.identifier] == nil {
                    do {
                        try await setDefault(applicationURL, type)
                        results[type.identifier] = currentDefault(type).map(isOurApp) ?? false
                    } catch {
                        results[type.identifier] = false
                    }
                }
                if results[type.identifier] != true { succeeded = false }
            }
            if !succeeded { failed.append(ext.uppercased()) }
        }
        message = failed.isEmpty
            ? L10n.text("Spacebar 3D is now the default app for all supported files.")
            : L10n.format("Could not set the default for: %@. Try again, or use Finder > Get Info > Open with > Change All.", String(describing: failed.joined(separator: ", ")))
    }
}

struct DefaultApplicationSettings: View {
    @StateObject private var model = DefaultApplication()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Open supported 3D files with Spacebar 3D when you double-click them in Finder."))
            Text(ModelViewerWindowController.fileExtensions.map { $0.uppercased() }.joined(separator: ", ") + ".")
                .font(GardenTypography.supporting)
                .foregroundStyle(NeonGarden.text2.color)
            Button {
                Task { await model.makeDefault() }
            } label: {
                Text(model.isRunning ? L10n.text("Setting Defaults…") : L10n.text("Make Default…"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(model.isRunning)
            if let message = model.message {
                Text(message).accessibilityIdentifier("defaultApplicationResult")
            }
            Text(L10n.text("This does not change Finder's Quick Look preview."))
                .font(GardenTypography.supporting)
                .foregroundStyle(NeonGarden.text2.color)
        }
        .font(GardenTypography.body)
        .fixedSize(horizontal: false, vertical: true)
    }
}
