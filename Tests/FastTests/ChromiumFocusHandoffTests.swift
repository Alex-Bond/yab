import AppKit
import Testing
@testable import Fast

/// A key-window notification and an external application's Cmd-V can arrive
/// in one run-loop turn. Focus must already be a barrier in the input queue.
@Suite(.serialized)
@MainActor
struct ChromiumFocusHandoffTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @Test func immediatePasteQueuesRestoredResponderFocusBeforeEditing() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            page.retire(call: false, pictureInPicture: false)
            page.removeFromSuperview(); window.close(); tab.close()
        }
        window.contentView = page
        #expect(window.makeFirstResponder(page))
        // Simulate the native responder already restored, with Chromium
        // still blurred and AppKit's deferred callback not yet delivered.
        page.adoptRemote("focus-handoff-test")
        let queuedBeforeFocus = page.queueTail
        page.remoteFocused = false
        page.paste(nil)
        #expect(page.remoteFocused == true, "Paste must reconcile focus in this same turn")
        #expect(page.queueTail != queuedBeforeFocus)
    }

    @Test func focusLossIsQueuedBeforeAnyFollowingInput() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        // No window means focus loss. A fake id lets us inspect scheduling
        // synchronously; retirement cancels the queue before any IPC runs.
        page.adoptRemote("focus-handoff-test")
        let queuedBeforeFocus = page.queueTail
        page.remoteFocused = true
        page.syncRemoteFocus(resigning: true)
        #expect(page.remoteFocused == false)
        #expect(page.queueTail != queuedBeforeFocus, "Focus must be queued now, not from a later Task behind the paste")
    }

    @Test func anUnchangedFocusDoesNotQueueWorkOrCreateAHelper() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.syncRemoteFocus()
        #expect(page.remoteID == nil && page.queueTail == nil)
        page.adoptRemote("focus-handoff-test")
        let queuedBeforeFocus = page.queueTail
        page.remoteFocused = false
        page.syncRemoteFocus()
        #expect(page.queueTail == queuedBeforeFocus)
    }
}
