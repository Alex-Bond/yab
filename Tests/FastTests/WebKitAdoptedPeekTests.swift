import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct WebKitAdoptedPeekTests {
    @Test(arguments: [PageAction.Kind.linkActivated, .other])
    func creationKeepsTheRelatedDocumentOutsideTheRow(kind: PageAction.Kind) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let source = Tab(shy: true, factory: .webKitOnly)
        source.restore(url: URL(string: "https://source.test/feed")!, title: "Source")
        source.pin = "S"
        browser.prepare(source); browser.lay([source]); browser.activeID = source.id
        let page = try #require(source.page as? PageView)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PeekView(); window.contentView = view
        view.browser = browser; browser.peekView = view
        defer {
            browser.hidePeek(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            window.close(); window.contentView = nil
        }
        let id = UUID()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let context = WebKitPopup(configuration)
        page.navigationEvents.popups[id] = context
        defer { page.navigationEvents.popups[id] = nil }
        let action = PageAction(request: URLRequest(url: URL(string: "https://t.co/article")!), kind: kind,
            targetIsMainFrame: nil, source: nil, modifierFlags: [], buttonNumber: 0,
            shouldPerformDownload: false, userInitiated: true)
        var answer: Tab.ID?
        browser.page(page, open: PagePopup(id: id, action: action, width: nil, height: nil,
                                          toolbarsVisible: nil, menuForeground: nil)) { answer = $0 }
        let child = try #require(context.tab)
        #expect(answer == child.id, "WebKit must receive its related document, not a cancel/reopen")
        #expect(browser.tabs.count == 1 && browser.tabs.first === source)
        #expect(browser.outside.contains { $0 === child })
        #expect(browser.peeking === child && source.peek === child)
        #expect(browser.activeID == source.id)
    }
}
