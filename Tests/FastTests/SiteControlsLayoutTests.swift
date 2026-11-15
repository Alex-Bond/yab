import AppKit
import SwiftUI
import Testing
@testable import Fast

/// Crashes #214 to #218 (0.40.1, row 1389): Site Controls' popover threw
/// from -[NSWindow _postWindowNeedsUpdateConstraints] a few seconds after
/// it opened, five times in four minutes on one Mac. The stall log before
/// them: ExtensionPanel.follow, called from the list's geometry action
/// inside NSHostingView.layout, set the popover's content size there, and
/// NSPopover ran the resize in a run loop of its own inside that pass.
@MainActor
@Suite(.serialized)
struct SiteControlsLayoutTests {
    /// A view that tells the panel a new height from inside its own layout
    /// pass, as the list's geometry action does, and notes what the popover
    /// measured before that pass was over.
    final class Asker: NSView {
        var panel: ExtensionPanel?
        var popover: NSPopover?
        var ask: CGFloat?
        var filter = ""
        var heightAtEndOfPass: CGFloat?
        override func layout() {
            super.layout()
            guard let ask, let panel, let popover else { return }
            self.ask = nil
            panel.follow(ask, filter: filter)
            heightAtEndOfPass = popover.contentSize.height
        }
    }

    @Test func theListsNewHeightReachesThePopoverAfterTheLayoutPass() async throws {
        let browser = Browser(windowID: UUID())
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let asker = Asker(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = asker
        let anchor = NSView(frame: NSRect(x: 300, y: 420, width: 24, height: 24))
        asker.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        let previous = Extensions.shared.browser
        Extensions.shared.browser = browser
        let panel = ExtensionPanel.shared
        defer {
            panel.close()
            Extensions.shared.browser = previous
            window.close()
        }

        panel.toggle(tab: tab, from: anchor)
        try await Task.sleep(for: .milliseconds(300))
        let popover = try #require(Mirror(reflecting: panel).children.first { $0.label == "popover" }?.value as? NSPopover,
                                   "toggle must make the popover")
        let before = popover.contentSize.height
        asker.panel = panel
        asker.popover = popover
        asker.ask = before + 80
        asker.filter = "x"
        asker.needsLayout = true
        asker.layoutSubtreeIfNeeded()
        let during = try #require(asker.heightAtEndOfPass, "the layout pass must have asked")
        // The main queue is served between awaits, not inside a test's own
        // run loop turns.
        try await Task.sleep(for: .milliseconds(500))
        let after = popover.contentSize.height
        print("SITE_CONTROLS_LAYOUT before \(before), at end of the asking pass \(during), after \(after)")
        #expect(abs(during - before) < 0.5, "the popover must not be resized inside the layout pass that asked")
        #expect(abs(after - (before + 80)) < 0.5, "the new height must still arrive, just after the pass")
    }
}
