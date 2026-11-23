import Foundation
import XCTest
@testable import ModelCore

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "zh-Hans", "es", "fr", "de", "ja", "pt-BR", "ko", "it", "ru"]

    private func table(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    func testEveryLanguageShipsAllKeysAndPreservesFormatArguments() throws {
        let english = try table("en")
        XCTAssertGreaterThanOrEqual(english.count, 245)
        for language in languages {
            let translated = try table(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in translated {
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, "\(language): \(key)")
            }
        }
    }

    func testLanguageBundlesResolveActualTranslationsAndKeepFileNamesLiteral() throws {
        let expected = ["en": "Open…", "zh-Hans": "打开…", "es": "Abrir…", "fr": "Ouvrir…", "de": "Öffnen…", "ja": "開く…", "pt-BR": "Abrir…", "ko": "열기…", "it": "Apri…", "ru": "Открыть…"]
        let name = "模型 100% %@.glb"
        for language in languages {
            let path = try XCTUnwrap(L10n.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Open…", value: nil, table: nil), expected[language])
            let template = bundle.localizedString(forKey: "“%@” could not be opened.", value: nil, table: nil)
            let result = String(format: template, locale: Locale(identifier: language), name)
            XCTAssertTrue(result.contains(name), language)
        }
        XCTAssertEqual(L10n.text("An unknown localization key"), "An unknown localization key")
    }
}
