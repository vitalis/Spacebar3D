import ModelCore
import XCTest

final class RelatedFilesTests: XCTestCase {
    /// The app declares, as related document types, exactly the extensions the reader asks
    /// the sandbox for; one without the other reads nothing.
    func testTheAppDeclaresTheRelatedExtensionsTheReaderUses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(project.components(separatedBy: "\n").first { $0.contains("CFBundleTypeExtensions:") })
        let listed = line.components(separatedBy: "[").last?.components(separatedBy: "]").first?
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        XCTAssertEqual(Set(listed), SidecarFolder.relatedExtensions)
        XCTAssertTrue(project.contains("NSIsRelatedItemType: true"))
        // Neither target needs more than the sandbox and what the user selects.
        for path in ["Spacebar3D/App/Spacebar3D.entitlements", "Spacebar3D/Extension/Spacebar3DExtension.entitlements"] {
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent(path)), format: nil) as? [String: Any])
            XCTAssertEqual(Set(plist.keys), ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-only", "com.apple.security.application-groups"], path)
        }
    }
}
