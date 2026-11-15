import AppKit
import ObjectiveC

/// Bounds synchronous reentry of the same wheel event into NSView's inherited
/// forwarding. Crash #157 exhausted the stack in repeated scrollWheel /
/// forwardMethod calls; its initiating view and exact route remain unknown.
@MainActor
enum ScrollWheelGuard {
    private struct Entry: Hashable {
        let receiver: ObjectIdentifier
        let event: ObjectIdentifier
    }
    private final class State { var active: Set<Entry> = [] }
    private static let key = "dev.yab.scroll-wheel-guard"

    static func install() { _ = installed }

    private static let installed: Void = {
        let selector = #selector(NSResponder.scrollWheel(with:))
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        typealias Scroll = @convention(c) (NSView, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Scroll.self)
        let guarded: @convention(block) (NSView, NSEvent) -> Void = { view, event in
            let dictionary = Thread.current.threadDictionary
            let state: State
            if let kept = dictionary[key] as? State {
                state = kept
            } else {
                state = State()
                dictionary[key] = state
            }
            let entry = Entry(receiver: ObjectIdentifier(view), event: ObjectIdentifier(event))
            guard state.active.insert(entry).inserted else { return }
            defer { state.active.remove(entry) }
            original(view, selector, event)
        }
        class_replaceMethod(NSView.self, selector, imp_implementationWithBlock(guarded), method_getTypeEncoding(method))
    }()
}
