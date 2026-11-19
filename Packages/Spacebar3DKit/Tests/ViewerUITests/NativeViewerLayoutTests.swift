import AppKit
import XCTest
@testable import ViewerUI

@MainActor
final class NativeViewerLayoutTests: XCTestCase {
    func testStatisticsClearViewerControlsAfterResizing() throws {
        let viewer = try XCTUnwrap(NativeViewer())
        let container = viewer.view
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 810, height: 610),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }

        viewer.model.flags.showAnimationBar = true
        viewer.model.clipNames = [String(repeating: "Long animation ", count: 5), "Idle"]
        viewer.model.statistics = NativeViewerStatistics(topology: "Triangles", faces: 1_234_567, vertices: 987_654)
        viewer.model.hasTextured = true

        func overlay(_ name: String) throws -> NSView {
            try XCTUnwrap(container.subviews.first {
                String(reflecting: type(of: $0)).contains("MeasuredHostingView<ViewerUI.\(name)>")
            })
        }

        for size in [CGSize(width: 810, height: 610), CGSize(width: 600, height: 440), CGSize(width: 560, height: 340)] {
            window.setContentSize(size)
            container.frame.size = size
            container.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            container.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            container.layoutSubtreeIfNeeded()

            let stats = try overlay("StatisticsView")
            XCTAssertFalse(stats.isHidden, "statistics should remain visible at \(size)")
            for name in ["ViewsBar", "AnimationBar", "SideControls"] {
                let controls = try overlay(name)
                XCTAssertFalse(stats.frame.intersects(controls.frame), "statistics overlap \(name) at \(size)")
            }
            let side = try overlay("SideControls")
            XCTAssertFalse(side.frame.intersects(try overlay("ViewsBar").frame), "side controls overlap views at \(size)")
            XCTAssertFalse(side.frame.intersects(try overlay("AnimationBar").frame), "side controls overlap playback at \(size)")
        }

        viewer.model.clipNames = []
        container.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        container.layoutSubtreeIfNeeded()
        XCTAssertFalse(try overlay("StatisticsView").frame.intersects(overlay("ViewsBar").frame))
    }
}
