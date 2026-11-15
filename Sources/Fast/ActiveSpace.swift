import AppKit

extension NSWindow {
    /// A window of our own beside the browser's (Settings, a detached
    /// inspector, a question from another Mac) opens on the Space the
    /// person is on, over Yab in full screen too, as a system
    /// settings window should. Without it macOS takes them to the desktop to show it
    /// (feedback #202).
    func opensOnActiveSpace() {
        collectionBehavior.formUnion([.fullScreenAuxiliary, .moveToActiveSpace])
    }
}
