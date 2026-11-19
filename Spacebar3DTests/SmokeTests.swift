import XCTest
import ViewerUI

@MainActor
final class SmokeTests: XCTestCase {
    func testTheFactoryMakesAViewerWithTheUsersSettings() throws {
        let viewer = try ViewerFactory.makeViewer(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        XCTAssertEqual(viewer.view.frame.size, NSSize(width: 320, height: 240))
        XCTAssertTrue(viewer is NativeViewer)
        XCTAssertEqual(ViewerFactory.Failure.noGraphics.errorDescription, "This Mac's graphics cannot show 3D models.")
    }
}
