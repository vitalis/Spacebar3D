import ModelCore
import Foundation

/// Viewer settings shared between the host app (which edits them) and the Quick Look
/// extension (which reads them).
///
/// Both are sandboxed, so they need a location each is entitled to. The settings live in
/// one JSON file in the container of an App Group that both targets belong to (see the
/// entitlements files). The group is prefixed with the team identifier, so both targets
/// must carry that team's signature; an ad-hoc signed build cannot share settings.
enum ViewerSettings {
    enum Key: String, CaseIterable {
        case defaultShading
        case showGrid
        case autoRotate
        case autoplay
        case backgroundColor
        case lightIntensity
        case solidColor
        case repeatAnimations
    }

    /// Defaults; `testdata/settings-vectors.json` holds the same values and is checked against them.
    static let defaults: [String: Any] = [
        Key.defaultShading.rawValue: "original",
        Key.showGrid.rawValue: true,
        Key.autoRotate.rawValue: false,
        Key.autoplay.rawValue: true,
        Key.backgroundColor.rawValue: "#07110c",
        Key.lightIntensity.rawValue: 1.0,
        Key.solidColor.rawValue: "#b4b4b8",
        Key.repeatAnimations.rawValue: false,
    ]

    /// Looks offered as the default; the raw values of `DefaultLook` in ViewerUI.
    static let shadingModes = [
        "original", "wireframe", "clay", "normals", "unlit", "anime", "celShaded", "retro", "voxel", "hologram",
    ]

    /// The looks in the menu's order: the views, the wireframe, the styles. Each group is set
    /// off by a divider, and every name is one word of the same kind.
    static let lookGroups: [[(mode: String, name: String)]] = [
        [("original", L10n.text("Textured")), ("clay", L10n.text("Solid")), ("normals", L10n.text("Normal"))],
        [("wireframe", L10n.text("Wireframe"))],
        [("unlit", L10n.text("Unshaded")), ("anime", L10n.text("Anime")), ("celShaded", L10n.text("Cel-Shaded")), ("retro", L10n.text("Retro")), ("voxel", L10n.text("Voxel Art")), ("hologram", L10n.text("Hologram"))],
    ]

    /// Accepted light intensity.
    static let lightIntensityRange: ClosedRange<Double> = 0.1...3.0

    /// True for "#rrggbb" with hexadecimal digits, the only colour form the settings use.
    static func isHexColor(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        return bytes.count == 7 && bytes[0] == 0x23 && bytes.dropFirst().allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    /// Values written by earlier versions of the settings file.
    private static let legacyLooks = [
        "textured": "original", "smooth": "clay", "flat": "clay", "chrome": "original", "custom": "original",
    ]

    /// The background that earlier versions wrote into the settings file as their default.
    /// A file that still holds it was never given a background of the user's own choosing,
    /// so it follows the default to the present one.
    static let legacyBackground = "#1c1c1e"

    /// The App Group shared by the app and the extension. Must match
    /// `com.apple.security.application-groups` in both entitlements files.
    static let appGroup = "V3AQWQ8JMY.com.vitalis.Spacebar3D"

    /// Location of the shared settings file inside the App Group's container, or nil when
    /// the system does not provide the container.
    static let fileURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
        .appendingPathComponent("viewer-settings.json")

    /// Stored values merged over the defaults. Unknown keys and values of the wrong
    /// type or out of range are ignored, so a damaged file degrades to defaults.
    /// `url` is the settings file; tests pass their own.
    static func load(from url: URL? = fileURL) -> [String: Any] {
        guard let url,
              let data = try? Data(contentsOf: url),
              data.count < maxFileBytes,
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return defaults }
        return normalize(stored)
    }

    /// Largest settings file that is read; anything bigger is treated as damaged.
    static let maxFileBytes = 64 * 1024

    /// The stored values that have a known key, the right type and an accepted value
    /// (a known look, a "#rrggbb" colour, a light intensity clamped to its range),
    /// merged over the defaults.
    static func normalize(_ stored: [String: Any]) -> [String: Any] {
        var values = defaults
        for key in Key.allCases {
            let name = key.rawValue
            guard let value = stored[name] else { continue }
            switch defaults[name] {
            case is Bool:
                // JSON booleans only; NSNumber 0/1 would also bridge to Bool.
                if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    values[name] = number.boolValue
                }
            case is Double:
                // The only number is the light intensity.
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.doubleValue.isFinite {
                    values[name] = min(lightIntensityRange.upperBound, max(lightIntensityRange.lowerBound, number.doubleValue))
                }
            default:
                guard let string = value as? String else { continue }
                if key == .defaultShading {
                    let look = legacyLooks[string] ?? string
                    if shadingModes.contains(look) { values[name] = look }
                } else if isHexColor(string) {
                    // The two colours, as "#rrggbb".
                    let color = string.lowercased()
                    values[name] = key == .backgroundColor && color == legacyBackground ? defaults[name] : color
                }
            }
        }
        return values
    }

    /// Writes the given values. Returns false when the location is unavailable or the
    /// write fails.
    @discardableResult
    static func save(_ values: [String: Any], to url: URL? = fileURL) -> Bool {
        guard let url else { return false }
        // Only known keys with accepted values are written (defaults for the rest), which
        // also keeps anything JSON cannot hold away from JSONSerialization: it raises an
        // Objective-C exception for those, which `try` does not catch.
        let out = normalize(values)
        guard JSONSerialization.isValidJSONObject(out) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
