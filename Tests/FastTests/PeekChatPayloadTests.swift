import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PeekChatPayloadTests {
    @Test func askCommandUsesPeekWhenTheNormalPagePrefersTheInlineField() {
        let browser = Browser(windowID: UUID())
        let previous = browser.prefs.askOpens
        defer { browser.prefs.askOpens = previous; browser.letGo() }
        browser.prefs.askOpens = .line
        let source = Tab(bench: true)
        source.restore(url: URL(string: "https://source.example.test/")!, title: "Underlying page")
        let peek = Tab(bench: true)
        peek.restore(url: URL(string: "https://peek.example.test/")!, title: "Visible Peek")
        browser.lay([source])
        browser.activeID = source.id
        // A command built before Peek opened must use the current page.
        let command = PageActionCommand(browser: browser)
        browser.outside.append(peek)
        browser.peeking = peek
        command.ask()
        #expect(browser.chatAttach.current(chat: nil, browser: browser) == [.tab(peek.id)])
        #expect(browser.chatFresh)
        #expect(browser.active === source)
        #expect(TaskLine.shared.tab == nil)
    }

    @Test func peekAttachmentReachesTheActualAgentPrompt() {
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        let source = Tab(bench: true)
        source.restore(url: URL(string: "https://source.example.test/underneath")!, title: "Underlying page")
        let peek = Tab(bench: true)
        peek.restore(url: URL(string: "https://peek.example.test/visible")!, title: "Visible Peek")
        browser.lay([source])
        browser.activeID = source.id
        browser.outside.append(peek)
        browser.peeking = peek

        let items = ChatAttach().current(chat: nil, browser: browser)
        let tabs = ChatAttachment.tabs(items, in: browser)
        #expect(tabs.count == 1 && tabs.first === peek)
        let prompt = Agents.given(tabs.map(TaskContext.tab), browser: browser)
        #expect(prompt.contains("https://peek.example.test/visible"))
        #expect(prompt.contains("Visible Peek"))
        #expect(!prompt.contains("source.example.test"))
        #expect(Agents.given([.page(peek)], browser: browser).contains("https://peek.example.test/visible"))

        let followUp = ChatAttachment.said(tabs: ChatAttachment.tabs(items, in: browser), files: [])
        #expect(followUp.contains("https://peek.example.test/visible"))
        #expect(!followUp.contains("source.example.test"))
        #expect(browser.chatPage === peek)
        #expect(browser.active === source)

        // Explicitly adding the source continues to mean that source.
        #expect(ChatAttachment.tabs([.tab(source.id)], in: browser).first === source)
        browser.peeking = nil
        browser.outside.removeAll { $0 === peek }
        #expect(ChatAttachment.tabs(items, in: browser).isEmpty)
        #expect(browser.chatPage === source)
        peek.close()
    }

    @Test func explicitlyAttachedPrivatePeekIsNeverSent() {
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        let peek = Tab(shy: true, bench: true)
        peek.restore(url: URL(string: "https://private.example.test/")!, title: "Private Peek")
        browser.outside.append(peek)
        browser.peeking = peek
        #expect(ChatAttachment.tabs([.tab(peek.id)], in: browser).isEmpty)
        #expect(Agents.given([.tab(peek), .page(peek)], browser: browser).isEmpty)
    }
}
