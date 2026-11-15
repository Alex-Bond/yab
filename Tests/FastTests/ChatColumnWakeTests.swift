import AppKit
import Testing
@testable import Fast

/// #705/#710: discarding a departure animation must never reveal a
/// column whose model is closed and whose controls no longer take clicks.
@MainActor
@Suite(.serialized)
struct ChatColumnWakeTests {
    private func column() -> ChatColumnView {
        let browser = Browser(windowID: UUID())
        return ChatColumnView(browser: browser, corner: 12, width: 360)
    }

    @Test func aClosedColumnStaysHiddenWhenItsAnimationsAreLost() throws {
        let view = column()
        let layer = try #require(view.subviews.first?.layer)
        view.slide(shown: true)
        #expect(layer.opacity == 1)
        view.slide(shown: false)
        // The render server may discard animations across sleep/reattachment.
        layer.removeAllAnimations()
        #expect(layer.opacity == 0)
        #expect(view.hitTest(.zero) == nil)
    }

    @Test func closingAgainRepairsAStaleNativeModelAndReopeningStillWorks() throws {
        let view = column()
        let layer = try #require(view.subviews.first?.layer)
        view.slide(shown: false)
        layer.opacity = 1
        view.slide(shown: false)
        #expect(layer.opacity == 0)
        view.slide(shown: true)
        layer.removeAllAnimations()
        #expect(layer.opacity == 1)
    }

    @Test func closeReconcilesTheDrawnHostEvenWhenTheBrowserModelIsAlreadyClosed() throws {
        for shortcut in [false, true] {
            let browser = Browser(windowID: UUID())
            let view = ChatColumnView(browser: browser, corner: 12, width: 360)
            let layer = try #require(view.subviews.first?.layer)
            view.slide(shown: true)
            #expect(!browser.chatOpen && layer.opacity == 1)
            if shortcut { browser.hideChat() } else { browser.moveChat(open: false) }
            layer.removeAllAnimations()
            #expect(layer.opacity == 0)
            #expect(!browser.chatOpen && !browser.chatMoving)
        }
    }
}
