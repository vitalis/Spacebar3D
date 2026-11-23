import XCTest

/// Runs the settings cases in `testdata/settings-vectors.json` against `ViewerSettings.normalize`.
/// The file is the written-down account of what a valid setting is.
final class SettingsSharedVectorsTests: XCTestCase {
    private struct Vectors {
        let defaults: [String: Any]
        let cases: [[String: Any]]
    }

    private func loadVectors() throws -> Vectors {
        // The file lives in the source tree, two levels up from this file.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdata/settings-vectors.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        return Vectors(
            defaults: try XCTUnwrap(root["defaults"] as? [String: Any]),
            cases: try XCTUnwrap(root["cases"] as? [[String: Any]])
        )
    }

    /// Same value and same JSON kind (a boolean is not the number 1).
    private func assertSame(_ actual: Any?, _ expected: Any?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual, let expected else {
            return XCTFail("\(message): missing value", file: file, line: line)
        }
        if let expectedString = expected as? String {
            XCTAssertEqual(actual as? String, expectedString, message, file: file, line: line)
            return
        }
        guard let a = actual as? NSNumber, let e = expected as? NSNumber else {
            return XCTFail("\(message): unexpected type \(type(of: actual))", file: file, line: line)
        }
        let aIsBool = CFGetTypeID(a) == CFBooleanGetTypeID()
        let eIsBool = CFGetTypeID(e) == CFBooleanGetTypeID()
        XCTAssertEqual(aIsBool, eIsBool, "\(message): boolean versus number", file: file, line: line)
        XCTAssertEqual(a.doubleValue, e.doubleValue, accuracy: 1e-12, message, file: file, line: line)
    }

    func testDefaultsMatchTheSharedFile() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(Set(ViewerSettings.defaults.keys), Set(vectors.defaults.keys))
        for (key, expected) in vectors.defaults {
            assertSame(ViewerSettings.defaults[key], expected, "default \(key)")
        }
    }

    func testEveryCase() throws {
        let vectors = try loadVectors()
        XCTAssertGreaterThan(vectors.cases.count, 100)
        for vector in vectors.cases {
            let name = try XCTUnwrap(vector["name"] as? String)
            let input = try XCTUnwrap(vector["input"] as? [String: Any], name)
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any], name)
            let result = ViewerSettings.normalize(input)
            XCTAssertEqual(Set(result.keys), Set(vectors.defaults.keys), name)
            for (key, fallback) in vectors.defaults {
                assertSame(result[key], expect[key] ?? fallback, "\(name) — \(key)")
            }
        }
    }
}
