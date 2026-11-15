import Foundation
import Testing
@testable import Fast

/// What may go with no words: anything added by hand, never the tab a new
/// chat comes with by itself.
@MainActor @Suite(.serialized)
struct ChatAttachCarriedTests {
    private func scene() -> (Browser, Tab, Tab) {
        let browser = Browser(windowID: UUID())
        let front = Tab(bench: true)
        front.restore(url: URL(string: "https://front.example.test/")!, title: "Front")
        let other = Tab(bench: true)
        other.restore(url: URL(string: "https://other.example.test/")!, title: "Other")
        browser.lay([front, other])
        browser.activeID = front.id
        return (browser, front, other)
    }

    @Test func theTabInFrontAloneIsNotEnough() {
        let (browser, front, _) = scene()
        defer { browser.letGo() }
        let attach = ChatAttach()
        #expect(attach.current(chat: nil, browser: browser) == [.tab(front.id)])
        #expect(!attach.carried(chat: nil, browser: browser))
    }

    @Test func aFileAddedByHandCanGoAlone() {
        let (browser, _, _) = scene()
        defer { browser.letGo() }
        let attach = ChatAttach()
        attach.add(.file(URL(fileURLWithPath: "/tmp/shot.png")), chat: nil, browser: browser)
        #expect(attach.carried(chat: nil, browser: browser))
    }

    @Test func anotherTabCanGoAlone() {
        let (browser, _, other) = scene()
        defer { browser.letGo() }
        let attach = ChatAttach()
        attach.toggle(other, chat: nil, browser: browser)
        #expect(attach.carried(chat: nil, browser: browser))
    }

    @Test func takingTheAddedOneOffLeavesNothingToSend() {
        let (browser, front, _) = scene()
        defer { browser.letGo() }
        let attach = ChatAttach()
        let quote = ChatAttachment.quote("Chosen words")
        attach.add(quote, chat: nil, browser: browser)
        attach.remove(quote, chat: nil, browser: browser)
        #expect(attach.current(chat: nil, browser: browser) == [.tab(front.id)])
        #expect(!attach.carried(chat: nil, browser: browser))
    }

    @Test func removingEverythingLeavesNothingToSend() {
        let (browser, front, _) = scene()
        defer { browser.letGo() }
        let attach = ChatAttach()
        attach.remove(.tab(front.id), chat: nil, browser: browser)
        #expect(!attach.carried(chat: nil, browser: browser))
    }
}
