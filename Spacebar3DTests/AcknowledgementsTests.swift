import XCTest

final class AcknowledgementsTests: TempDirTestCase {
    /// The source tree, two levels up from this file.
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testTheNoticesAreTheProjectsLicenceThenTheThirdParties() throws {
        let text = Acknowledgements.text(in: repository)
        let own = try XCTUnwrap(text.range(of: "Apache License"))
        let others = try XCTUnwrap(text.range(of: "# Third-Party Licenses"))
        let credits = try XCTUnwrap(text.range(of: "# Credits"))
        XCTAssertLessThan(own.lowerBound, credits.lowerBound)
        XCTAssertLessThan(credits.lowerBound, others.lowerBound)
        XCTAssertTrue(text.contains("Copyright (c) 2026 sawa-zen"))
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"))
        XCTAssertFalse(text.contains("is missing"))
        // Every library linked into the app, with the words its licence asks to be kept.
        for words in ["Copyright (c) Meta Platforms, Inc. and affiliates", "Copyright (c) 2006-2026, assimp team",
                      "Angus Johnson", "Nemanja Trifunovic", "Poly2Tri Contributors", "Arseny Kapoulkine", "Kim Kulling", "Gilles Vollant",
                      "Redistributions in binary form must reproduce the above copyright notice"] {
            XCTAssertTrue(text.contains(words), words)
        }
    }

    func testTheVendoredDecodersOwnLicenceIsTheOneShown() throws {
        let vendored = try String(contentsOf: repository.appendingPathComponent("Packages/Spacebar3DKit/Sources/CZstd/LICENSE"), encoding: .utf8)
        XCTAssertTrue(Acknowledgements.text(in: repository).contains(vendored.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testAMissingFileIsSaidToBeMissing() throws {
        try put("LICENSE", bytes: Data("own terms\n".utf8))
        XCTAssertEqual(Acknowledgements.text(in: modelDir), "own terms\n\n\nCREDITS.md is missing from this copy of the app.\n\n\nTHIRD_PARTY_LICENSES.md is missing from this copy of the app.")
        XCTAssertTrue(Acknowledgements.text(in: nil).contains("LICENSE is missing"))
    }

    func testAllNoticesAreBundledWithTheApp() throws {
        let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
        for name in Acknowledgements.fileNames {
            XCTAssertTrue(project.contains("      - path: \(name)\n        buildPhase: resources"), name)
        }
    }

    /// One name for the app wherever it is named: the menu bar's is the display name.
    func testTheAppHasOneName() throws {
        let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
        let app = try XCTUnwrap(project.components(separatedBy: "Quick Look preview extension").first)
        XCTAssertTrue(app.contains("        CFBundleDisplayName: Spacebar 3D\n"))
        XCTAssertTrue(app.contains("        CFBundleName: Spacebar 3D\n"))
        // What the Mac App Store requires of the app's Info.plist.
        XCTAssertTrue(app.contains("        LSApplicationCategoryType: public.app-category.graphics-design\n"))
        XCTAssertTrue(app.contains("        NSHumanReadableCopyright: "))
        XCTAssertTrue(app.contains("        ITSAppUsesNonExemptEncryption: false\n"))
    }
}
