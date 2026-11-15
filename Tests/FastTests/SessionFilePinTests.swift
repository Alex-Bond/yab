import AppKit
import Testing
@testable import Fast

/// A page on this Mac pinned, a start page of your own, comes back after a
/// relaunch and after its window closes, as a web page's pin does
/// (feedback #214).
@MainActor
@Suite(.serialized)
struct SessionFilePinTests {
    @Test func aPinnedFileComesBack() {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        let file = URL(fileURLWithPath: "/Users/someone/Start/index.html")
        let pin = Tab(), page = Tab()
        browser.prepare(pin)
        browser.prepare(page)
        pin.restore(url: file, title: "Start")
        pin.pin = "S"
        page.restore(url: URL(string: "https://example.com/")!, title: "Example")
        browser.lay([pin, page])
        browser.activeID = page.id
        browser.writeSession(now: true)
        let ids = [pin.id, page.id]
        for tab in [pin, page] { tab.close() }
        browser.lay([])
        let row = browser.loadRow(Space.firstID)
        defer { for tab in row.tabs { tab.close() } }
        #expect(row.tabs.map(\.id) == ids)
        #expect(row.tabs.first?.pending == file)
        #expect(row.tabs.first?.pin == "S")
    }

    @Test func onlyPagesAreWritten() {
        #expect(Session.writes(URL(fileURLWithPath: "/tmp/a.html")))
        #expect(Session.writes(URL(string: "https://example.com")!))
        #expect(!Session.writes(URL(string: "about:blank")!))
        #expect(!Session.writes(URL(string: "data:text/html,hi")!))
    }
}
