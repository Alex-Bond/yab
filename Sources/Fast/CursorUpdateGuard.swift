import AppKit
import ObjectiveC

/// macOS 15 crash reports repeat NSView.cursorUpdate/forwardMethod until the
/// stack guard faults. Guard the inherited implementation too: protecting
/// only our overrides misses SwiftUI's private views and plain NSViews.
@MainActor
enum CursorUpdateGuard {
    enum Boundary: Hashable { case appKit, viewOverride }

    private struct Entry: Hashable {
        let receiver: ObjectIdentifier
        let boundary: Boundary
    }

    private final class State {
        var active: Set<Entry> = []
    }

    private static let key = "dev.yab.cursor-update-guard"

    /// Each receiver forwards at most once while its call is on this thread's
    /// stack. Different receivers may still forward normally, including through
    /// multiple plain containers to a parent that supplies the cursor. The
    /// separate boundaries allow an override to call super on the same view.
    @discardableResult
    static func run(_ receiver: NSView, boundary: Boundary = .viewOverride, _ body: () -> Void) -> Bool {
        let dictionary = Thread.current.threadDictionary
        let state: State
        if let kept = dictionary[key] as? State {
            state = kept
        } else {
            state = State()
            dictionary[key] = state
        }
        let entry = Entry(receiver: ObjectIdentifier(receiver), boundary: boundary)
        // Also cap a route that keeps creating different forwarding views.
        guard state.active.count < 64, state.active.insert(entry).inserted else { return false }
        defer { state.active.remove(entry) }
        body()
        return true
    }

    /// Install once, before any browser window is created. Keep AppKit's
    /// original implementation and ABI; only recursive reentry is suppressed.
    static func install() { _ = installed }

    private static let installed: Void = {
        let selector = #selector(NSResponder.cursorUpdate(with:))
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        typealias Update = @convention(c) (NSView, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Update.self)
        let guarded: @convention(block) (NSView, NSEvent) -> Void = { view, event in
            run(view, boundary: .appKit) { original(view, selector, event) }
        }
        class_replaceMethod(NSView.self, selector, imp_implementationWithBlock(guarded), method_getTypeEncoding(method))
    }()
}
