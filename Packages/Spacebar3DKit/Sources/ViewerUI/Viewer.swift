import AppKit

/// What the app and the Quick Look extension show a model with. They hold a `Viewer` and
/// do not know which renderer is behind it.
@MainActor
public protocol Viewer: AnyObject {
    /// The view to put in a window or in the Quick Look panel.
    var view: NSView { get }
    /// Reads the file and starts showing it. Throws when the file cannot be read at all;
    /// problems inside the file are reported in the view.
    func load(fileAt url: URL) throws
    /// Puts the controls back to the user's defaults. Quick Look keeps a preview alive and
    /// shows it again for the same file, where it should not remember the last visit.
    func resetControls()
    /// Gives the viewer keyboard focus, so its shortcuts work.
    func takeFocus()
    /// Does what a menu asks; a command that cannot be chosen just now does nothing.
    func perform(_ command: ViewerCommand)
    /// How a command stands just now, for a menu to show.
    func status(of command: ViewerCommand) -> ViewerCommandStatus
    /// Whether arrows turn and Shift-arrows pan the model while it has the keyboard. Off in Quick Look,
    /// where the arrows go to the next file.
    var orbitsWithArrowKeys: Bool { get set }
    var playsWithSpaceKey: Bool { get set }
    /// The model's animations by name (empty when it has none), the one chosen, and a way to choose.
    var clipNames: [String] { get }
    var currentClip: Int { get }
    func selectClip(_ index: Int)
    /// Called when the answer of `status(of:)` may have changed.
    var onCommandStateChange: (() -> Void)? { get set }
}
