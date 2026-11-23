import ModelCore
import SwiftUI
import ViewerUI

/// Holds the settings being edited and writes every change to the shared file.
final class SettingsModel: ObservableObject {
    /// One model for every window that shows the settings (the main window and Settings…),
    /// so they edit the same values instead of overwriting each other's.
    static let shared = SettingsModel()

    @Published private var values: [String: Any]
    /// False once a write has failed, so the UI can say so instead of silently losing edits.
    @Published private(set) var saveFailed = false

    let available: Bool
    /// The settings file: the shared one; tests pass their own.
    private let file: URL?

    init(file: URL? = ViewerSettings.fileURL) {
        self.file = file
        values = ViewerSettings.load(from: file)
        available = file != nil
        // Create the file on first launch, so a storage problem shows up straight away
        // rather than on the first edit.
        if let file, !FileManager.default.fileExists(atPath: file.path) {
            saveFailed = !ViewerSettings.save(values, to: file)
        }
    }

    private func set(_ key: ViewerSettings.Key, _ value: Any) {
        values[key.rawValue] = value
        saveFailed = !ViewerSettings.save(values, to: file)
    }

    func bool(_ key: ViewerSettings.Key) -> Binding<Bool> {
        Binding(get: { self.values[key.rawValue] as? Bool ?? false }, set: { self.set(key, $0) })
    }

    func string(_ key: ViewerSettings.Key) -> Binding<String> {
        Binding(get: { self.values[key.rawValue] as? String ?? "" }, set: { self.set(key, $0) })
    }

    func double(_ key: ViewerSettings.Key) -> Binding<Double> {
        Binding(get: { self.values[key.rawValue] as? Double ?? 0 }, set: { self.set(key, $0) })
    }

    func reset() {
        values = ViewerSettings.defaults
        saveFailed = !ViewerSettings.save(values, to: file)
    }
}

/// Settings for the 3D preview. Values are written to the shared settings file and
/// picked up by the Quick Look extension the next time a file is previewed.
struct SettingsView: View {
    @ObservedObject private var model: SettingsModel

    /// The app's windows share one model; tests pass their own.
    init(model: SettingsModel = .shared) { self.model = model }

    var body: some View {
        if !model.available {
            Text(L10n.text("Settings are unavailable: the settings location could not be determined."))
                .foregroundStyle(NeonGarden.text2.color)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            Form {
                Section {
                    GardenPicker(L10n.text("Opens in:"),
                                 selectedTitle: ViewerSettings.lookGroups.flatMap { $0 }.first { $0.mode == model.string(.defaultShading).wrappedValue }?.name ?? "",
                                 selection: model.string(.defaultShading)) {
                        ForEach(Array(ViewerSettings.lookGroups.enumerated()), id: \.offset) { index, group in
                            if index > 0 { Divider() }
                            ForEach(group, id: \.mode) { Text($0.name).font(GardenTypography.body).tag($0.mode) }
                        }
                    }
                    Toggle(L10n.text("Show floor grid"), isOn: model.bool(.showGrid))
                    Toggle(L10n.text("Auto-rotate the model"), isOn: model.bool(.autoRotate))
                    Toggle(L10n.text("Play animations automatically"), isOn: model.bool(.autoplay))
                    Toggle(L10n.text("Repeat animations"), isOn: model.bool(.repeatAnimations))
                } header: { Text(L10n.text("When a model opens")).font(GardenTypography.heading) }

                Section {
                    ColorPicker(L10n.text("Background:"), selection: hexBinding(model.string(.backgroundColor)), supportsOpacity: false)
                    ColorPicker(L10n.text("Solid view color:"), selection: hexBinding(model.string(.solidColor)), supportsOpacity: false)
                    LabeledContent(L10n.text("Brightness:")) {
                        Slider(value: model.double(.lightIntensity), in: ViewerSettings.lightIntensityRange) { EmptyView() }
                            minimumValueLabel: { Image(systemName: "sun.min").accessibilityHidden(true) }
                            maximumValueLabel: { Image(systemName: "sun.max").accessibilityHidden(true) }
                            .accessibilityLabel(L10n.text("Brightness"))
                        Text("\(Int((model.double(.lightIntensity).wrappedValue * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(NeonGarden.info.color)
                            .frame(width: 56, alignment: .trailing)
                    }
                } header: { Text(L10n.text("Appearance")).font(GardenTypography.heading) }

                VStack(alignment: .leading, spacing: 8) {
                    if model.saveFailed {
                        Text(L10n.text("Could not save settings."))
                            .font(GardenTypography.supporting)
                            .foregroundStyle(NeonGarden.danger.color)
                    } else {
                        Text(L10n.text("Changes apply the next time you open or preview a model."))
                            .font(GardenTypography.supporting)
                            .foregroundStyle(NeonGarden.text2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(L10n.text("Restore Defaults")) { model.reset() }
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    DefaultApplicationSettings()
                } header: { Text(L10n.text("Default app")).font(GardenTypography.heading) }
            }
            // The controls are the system's own, in the accent colour the user has chosen.
            .tint(nil)
            .formStyle(.grouped)
            .font(GardenTypography.body)
        }
    }

    /// Bridges a stored "#rrggbb" string to the Color a ColorPicker edits.
    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex.wrappedValue) ?? .gray },
            set: { hex.wrappedValue = $0.hexString ?? hex.wrappedValue }
        )
    }
}

private extension Color {
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
