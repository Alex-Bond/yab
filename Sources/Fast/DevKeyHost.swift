import AppKit
import SwiftUI

private final class DevKeyHostingView<Content: View>: NSHostingView<Content>, DevKeyTarget {
    private var presses: Any?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let browser = BrowserWindows.shared.browser(for: window), DevKeys.take(event, browser: browser) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    /// A press anywhere in the panel takes the keyboard into the card, as a
    /// click into Chrome's DevTools does: a row of the tree, a request, a
    /// file is no field, and without this the keyboard stayed on the page,
    /// ⌘F finding on the page instead of in Elements or Network.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let presses { NSEvent.removeMonitor(presses) }
        presses = nil
        guard window != nil else { return }
        DevKeyClaim.hosts.add(self)
        presses = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.pressed(event)
            return event
        }
    }

    private func pressed(_ event: NSEvent) {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
        let at = convert(event.locationInWindow, from: nil)
        guard bounds.contains(at) else { return }
        // Where, in the window: whose the keys are after it.
        DevKeyClaim.pressAt = event.locationInWindow
        guard !DevKeys.contains(window.firstResponder) else { DevKeyClaim.last = "already in the card"; return }
        let took = window.makeFirstResponder(self)
        if Store.testing { DevKeyClaim.last = "claimed \(took) at \(Int(at.x)),\(Int(at.y)) in \(Int(bounds.width))x\(Int(bounds.height))" }
    }
}

/// What the last press in a panel did with the keyboard, for the bench.
enum DevKeyClaim {
    @MainActor static var last = ""
    /// The last press in a panel, in the window's points: in Elements'
    /// tree, the keys are the tree's (DevKeys), as Chromium's focused tree.
    @MainActor static var pressAt: CGPoint?
    /// The panels' hosts, for the bench to find the one shown.
    @MainActor static let hosts = NSHashTable<NSView>.weakObjects()

    /// For the bench: the panel shown in a window, from its top left, as
    /// AppKit lays it out (the card's SwiftUI frame isn't told when AppKit
    /// moves the card's host, as a move from the side to the bottom does).
    @MainActor static func shownHost(in window: NSWindow?) -> NSView? {
        let shown = hosts.allObjects.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0 }
        return shown.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
    }
    @MainActor static func pane(in window: NSWindow?) -> [Double] {
        guard let window, let content = window.contentView else { return [] }
        guard let host = shownHost(in: window) else { return [] }
        let r = host.convert(host.bounds, to: nil)
        return [r.minX, content.bounds.height - r.maxY, r.width, r.height].map(Double.init)
    }
}

/// Tags the native card's responder ancestry, including SwiftUI text fields.
/// Commands stay in DevTools while a filter or property editor has focus.
struct DevKeyHost<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content
    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = DevKeyHostingView(rootView: content)
        host.sizingOptions = []
        return host
    }
    func updateNSView(_ host: NSHostingView<Content>, context: Context) { host.rootView = content }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<Content>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
