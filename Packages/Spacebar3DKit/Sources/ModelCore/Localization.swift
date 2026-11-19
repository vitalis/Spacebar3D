import Foundation

/// One catalog for the app, Quick Look extension and shared viewer. Always resolve in
/// the package bundle, including when macOS hosts the extension in another process.
public enum L10n {
    public static let bundle = Bundle.module

    public static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// UI values are string arguments, so translations may reorder placeholders without
    /// changing their types. File names and model-authored text are never lookup keys.
    public static func format(_ key: String, _ arguments: String...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
