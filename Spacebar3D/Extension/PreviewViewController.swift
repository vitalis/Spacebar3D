import Cocoa
import Quartz
import ViewerUI

/// View controller that previews 3D models in Quick Look.
///
/// It only hosts the `Viewer` that `ViewerFactory` makes.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var viewer: Viewer?

    override func loadView() {
        // A viewer is made per file, so the controller's own view is just its container.
        view = NSView()
    }

    /// Quick Look may keep this view alive and show it again for the same file, so the
    /// viewer is told when the preview goes away and puts its controls back to the defaults.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        viewer?.resetControls()
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        let viewer: Viewer
        do {
            viewer = try ViewerFactory.makeViewer(frame: view.bounds)
            try viewer.load(fileAt: url)
        } catch {
            handler(error)
            return
        }
        self.viewer?.view.removeFromSuperview()
        viewer.view.frame = view.bounds
        viewer.view.autoresizingMask = [.width, .height]
        view.addSubview(viewer.view)
        self.viewer = viewer

        // The view is ready to display, so tell Quick Look we're done. The model itself
        // appears asynchronously once the viewer has loaded it.
        handler(nil)
    }
}
