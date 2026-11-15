import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumHoverTests {
    @Test func statusWordsNameALinkOnlyAsAnAbsoluteAddress() {
        #expect(ChromiumPage.hoverLink("https://example.test/a?b=1")?.absoluteString == "https://example.test/a?b=1")
        #expect(ChromiumPage.hoverLink("mailto:person@example.test")?.absoluteString == "mailto:person@example.test")
        #expect(ChromiumPage.hoverLink("") == nil)
        #expect(ChromiumPage.hoverLink("   ") == nil)
        #expect(ChromiumPage.hoverLink("Loading the next page") == nil)
        #expect(ChromiumPage.hoverLink("/relative/path") == nil)
    }

    @Test func onlyThePointersOwnMovesInsideThePageShowALink() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let status = LinkStatus.shared
        status.forget(tab.id)
        // Laid out under a pointer at rest: no move inside yet, no pill.
        status.pointerMoved()
        page.hoverStatus("https://example.test/first")
        #expect(status.pointed == nil)
        // The pointer moves inside: the link shows.
        page.hoverMoved(); status.pointerMoved()
        page.hoverStatus("https://example.test/first")
        #expect(status.pointed?.url.absoluteString == "https://example.test/first")
        #expect(status.pointed?.tab == tab.id)
        // A scroll carries another link under the resting pointer: it goes.
        status.scrolled()
        page.hoverStatus("https://example.test/second")
        #expect(status.pointed == nil)
        // Moving again shows the new one, and empty words take it down.
        status.pointerMoved()
        page.hoverStatus("https://example.test/second")
        #expect(status.pointed?.url.absoluteString == "https://example.test/second")
        status.pointerMoved()
        page.hoverStatus("")
        #expect(status.pointed == nil)
        // Leaving the page forgets the link, and late words are ignored.
        status.pointerMoved()
        page.hoverStatus("https://example.test/third")
        page.hoverLeft()
        #expect(status.pointed == nil)
        status.pointerMoved()
        page.hoverStatus("https://example.test/late")
        #expect(status.pointed == nil)
    }

    @Test func anEmptyDelayedStatusDoesNotSpendTheMoveBeforeItsLinkArrives() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let status = LinkStatus.shared
        status.forget(tab.id)
        page.hoverMoved(); status.pointerMoved()
        page.hoverStatus("")
        page.hoverStatus("")
        page.hoverStatus("https://example.test/first")
        #expect(status.pointed?.url.absoluteString == "https://example.test/first")
        // No more real moves: a link laid out under the pointer stays hidden.
        page.hoverStatus("https://example.test/second")
        #expect(status.pointed == nil)
        page.hoverMoved(); status.pointerMoved()
        page.hoverScrolled()
        page.hoverStatus("https://example.test/third")
        #expect(status.pointed == nil)
        page.hoverMoved(); status.pointerMoved()
        page.hoverStatus("https://example.test/third")
        #expect(status.pointed?.url.absoluteString == "https://example.test/third")
        page.hoverMoved(); status.pointerMoved()
        page.hoverStatus("")
        page.hoverMovedAt -= 1
        page.hoverStatus("https://example.test/late-layout")
        #expect(status.pointed == nil)
    }
}
