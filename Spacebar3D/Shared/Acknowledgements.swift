import ModelCore
import Foundation

/// The licence notices the app carries with it: its own, and those of the third-party
/// code linked into it. Their terms ask for the notice wherever the binary goes, so the
/// notice files are bundled as resources and shown from the app's menu.
enum Acknowledgements {
    /// The files, in the order shown: the project's licence, credits, then third-party terms.
    static let fileNames = ["LICENSE", "CREDITS.md", "THIRD_PARTY_LICENSES.md"]

    /// The notices as one text, from the files in `folder` (the app's resources). A file
    /// that is missing is said to be missing, so the gap is seen and not passed over.
    static func text(in folder: URL? = Bundle.main.resourceURL) -> String {
        fileNames.map { name in
            guard let folder, let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
                return L10n.format("%@ is missing from this copy of the app.", String(describing: name))
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n\n")
    }
}
