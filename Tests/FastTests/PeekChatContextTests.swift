import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PeekChatContextTests {
    private func scene(privatePeek: Bool = false, blankPeek: Bool = false) -> (Browser, Tab, Tab) {
        let browser = Browser(windowID: UUID())
        let source = Tab(bench: true)
        source.restore(url: URL(string: "https://source.example.test/underneath")!, title: "Underlying page")
        let peek = Tab(shy: privatePeek, bench: true)
        if !blankPeek {
            peek.restore(url: URL(string: "https://peek.example.test/visible")!, title: "Visible Peek")
        }
        browser.lay([source])
        browser.activeID = source.id
        browser.outside.append(peek)
        browser.peekFrom = source.id
        browser.peeking = peek
        return (browser, source, peek)
    }

    @Test func newChatUsesVisiblePeekInsteadOfUnderlyingPage() {
        let (browser, source, peek) = scene()
        defer { browser.letGo() }
        let attached = ChatAttach().current(chat: nil, browser: browser)
        #expect(attached == [.tab(peek.id)], "A new chat must receive the visible Peek page")
        #expect(browser.active === source)
    }

    @Test func closingPeekRestoresUnderlyingPageContext() {
        let (browser, source, _) = scene()
        defer { browser.letGo() }
        browser.peeking = nil
        browser.peekFrom = nil
        #expect(ChatAttach().current(chat: nil, browser: browser) == [.tab(source.id)])
    }

    @Test func explicitlyChosenContextSurvivesPeekChanges() {
        let (browser, source, _) = scene()
        defer { browser.letGo() }
        let attach = ChatAttach()
        attach.set([.tab(source.id), .quote("Chosen words")])
        #expect(attach.current(chat: nil, browser: browser) == [.tab(source.id), .quote("Chosen words")])
        browser.peeking = nil
        #expect(attach.current(chat: nil, browser: browser) == [.tab(source.id), .quote("Chosen words")])
    }

    @Test func privatePeekDoesNotFallBackToUnderlyingPage() {
        let (browser, _, _) = scene(privatePeek: true)
        defer { browser.letGo() }
        #expect(ChatAttach().current(chat: nil, browser: browser).isEmpty,
                "A private Peek must not attach the unrelated page underneath")
    }

    @Test func blankPeekDoesNotFallBackToUnderlyingPage() {
        let (browser, _, _) = scene(blankPeek: true)
        defer { browser.letGo() }
        #expect(ChatAttach().current(chat: nil, browser: browser).isEmpty,
                "An empty Peek must not attach the unrelated page underneath")
    }

    @Test func removingDefaultPeekContextDoesNotRevealUnderlyingPage() {
        let (browser, _, peek) = scene()
        defer { browser.letGo() }
        let attach = ChatAttach()
        attach.remove(.tab(peek.id), chat: nil, browser: browser)
        #expect(attach.current(chat: nil, browser: browser).isEmpty,
                "Removing the Peek attachment must leave the message without a page")
    }
}
