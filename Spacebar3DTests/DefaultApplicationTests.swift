import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class DefaultApplicationTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/Spacebar 3D.app")

    func testEverySupportedExtensionAndItsAliasesAreSetOnlyOnce() async {
        var requested: [String] = []
        var changed: [String] = []
        let model = DefaultApplication(
            applicationURL: app,
            resolve: { ext in
                requested.append(ext)
                return [.usdz, .usd, .usdz]
            },
            setDefault: { url, type in
                XCTAssertEqual(url, self.app)
                changed.append(type.identifier)
            },
            currentDefault: { _ in self.app },
            isOurApp: { $0 == self.app }
        )
        XCTAssertTrue(changed.isEmpty, "No association changes on initialization")
        await model.makeDefault()
        XCTAssertEqual(requested, ModelViewerWindowController.fileExtensions)
        XCTAssertEqual(changed, [UTType.usdz.identifier, UTType.usd.identifier])
        XCTAssertEqual(model.message, "Spacebar 3D is now the default app for all supported files.")
        XCTAssertFalse(model.isRunning)
    }

    func testFailuresDoNotStopOtherFormatsAndAnUnchangedDefaultIsNotSuccess() async {
        var changed: [String] = []
        let model = DefaultApplication(
            extensions: ["obj", "stl", "usd", "usdz"], applicationURL: app,
            resolve: { ext in [UTType(filenameExtension: ext)!] },
            setDefault: { _, type in
                changed.append(type.identifier)
                if type == UTType(filenameExtension: "obj") { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
            },
            currentDefault: { type in type == .usd || type == .usdz ? self.app : nil },
            isOurApp: { $0 == self.app }
        )
        await model.makeDefault()
        XCTAssertEqual(changed.count, 4)
        XCTAssertEqual(model.message, "Could not set the default for: OBJ, STL. Try again, or use Finder > Get Info > Open with > Change All.")
        XCTAssertFalse(model.isRunning)
    }

    func testUnknownOrGenericTypesAreReportedWithoutChangingTheirHandlers() async {
        var changed = false
        let model = DefaultApplication(
            extensions: ["unknown"], applicationURL: app,
            resolve: { _ in [.data, .item, UTType(filenameExtension: "spacebar-test-unknown")!] },
            setDefault: { _, _ in changed = true },
            currentDefault: { _ in self.app },
            isOurApp: { $0 == self.app }
        )
        await model.makeDefault()
        XCTAssertFalse(changed)
        XCTAssertTrue(model.message?.contains("UNKNOWN") == true)
    }

    func testSecondRequestWhileRunningDoesNotStartAnotherBatch() async {
        var resume: CheckedContinuation<Void, Never>?
        let started = expectation(description: "setting default")
        var calls = 0
        let model = DefaultApplication(
            extensions: ["usd"], applicationURL: app,
            resolve: { _ in [.usd] },
            setDefault: { _, _ in
                calls += 1
                await withCheckedContinuation { continuation in
                    resume = continuation
                    started.fulfill()
                }
            },
            currentDefault: { _ in self.app },
            isOurApp: { $0 == self.app }
        )
        let first = Task { await model.makeDefault() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isRunning)
        await model.makeDefault()
        XCTAssertEqual(calls, 1)
        resume?.resume()
        await first.value
        XCTAssertFalse(model.isRunning)
    }
}
