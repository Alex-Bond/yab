import AppKit
import Foundation
import Testing
@testable import Fast

struct OmniboxAddressTests {
    @MainActor @Test func arrowsShowAddressesForRecentAndFrequentPages() {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.query.offers = [
            Suggestion(key: "Analytics · Money · Admin | Acme", title: "acme.example", url: URL(string: "https://acme.example/admin/analytics/revenue"), kind: .open),
            Suggestion(key: "Yab: yet another browser.", title: "localhost", url: URL(string: "http://localhost:4317/measure?mode=fast#results"), kind: .visited),
            Suggestion(key: "New document", title: "notion.new", url: URL(string: "https://notion.new"), kind: .quickAction("document"))
        ]
        browser.query.lead = nil

        browser.walk(1)
        #expect(browser.completed == "acme.example/admin/analytics/revenue")
        browser.walk(1)
        #expect(browser.completed == "localhost:4317/measure?mode=fast#results")
        browser.walk(1)
        #expect(browser.completed.isEmpty)
        browser.walk(-1)
        #expect(browser.completed == "localhost:4317/measure?mode=fast#results")
        browser.walk(-1)
        // ↑ on the first row comes round to the last, and ↓ there back to
        // the first.
        browser.walk(-1)
        #expect(browser.query.picked == 2)
        #expect(browser.completed.isEmpty)
        browser.walk(1)
        #expect(browser.query.picked == 0)
        #expect(browser.completed == "acme.example/admin/analytics/revenue")
    }

    /// The list made again for the same words, as history, suggestions or a
    /// reading of them come in late, keeps the row the arrows walked to;
    /// other words start with nothing chosen.
    @MainActor @Test func theSameWordsAnsweredAgainKeepTheRowWalkedTo() throws {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.typed = "stat"
        try #require(browser.offers.count >= 2)
        browser.walk(1)
        let row = try #require(browser.query.picked)
        let walked = browser.offers[row].id

        browser.typed = browser.typed
        #expect(browser.query.picked.map { browser.offers[$0].id } == walked)
        browser.guessAgain()
        #expect(browser.query.picked.map { browser.offers[$0].id } == walked)

        browser.typed = "stats"
        #expect(browser.query.picked == nil)
    }

    /// Words typed: the first row is the one Return takes, and ↑ on it goes
    /// to the foot of the list rather than nowhere; ↓ on the foot comes
    /// back to it, the field saying what was typed again.
    @MainActor @Test func arrowsGoRoundTheListUnderTypedWords() {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.query.typed = "analytics"
        browser.query.offers = [
            Suggestion(key: "analytics", title: "Search", url: URL(string: "https://example.test/?q=analytics"), kind: .search),
            Suggestion(key: "Analytics · Money · Admin | Acme", title: "acme.example", url: URL(string: "https://acme.example/admin/analytics/revenue"), kind: .open),
            Suggestion(key: "Yab: yet another browser.", title: "localhost", url: URL(string: "http://localhost:4317/measure?mode=fast#results"), kind: .visited)
        ]
        browser.query.lead = 0
        #expect(browser.query.current == 0)

        browser.walk(-1)
        #expect(browser.query.current == 2)
        #expect(browser.completed == "localhost:4317/measure?mode=fast#results")
        browser.walk(-1)
        #expect(browser.query.current == 1)
        browser.walk(-1)
        #expect(browser.query.current == 0)
        browser.walk(-1)
        #expect(browser.query.current == 2)
        browser.walk(1)
        #expect(browser.query.picked == nil)
        #expect(browser.query.current == 0)
        #expect(browser.completed == "analytics")
        browser.walk(1)
        #expect(browser.query.current == 1)
    }

    @MainActor @Test func selectingAPagePreservesTypedSearchAndHoverDoesNotReplaceIt() {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.query.typed = "analytics"
        browser.query.offers = [
            Suggestion(key: "Analytics · Money · Admin | Acme", title: "acme.example", url: URL(string: "https://acme.example/admin/analytics/revenue"), kind: .open),
            Suggestion(key: "analytics", title: "Search", url: URL(string: "https://example.test/?q=analytics"), kind: .search)
        ]
        browser.query.lead = nil
        browser.query.pointed = 0
        #expect(browser.completed == "analytics")
        browser.query.pointed = nil
        browser.walk(1)
        #expect(browser.completed == "acme.example/admin/analytics/revenue")
        #expect(browser.typed == "analytics")
        browser.walk(1)
        #expect(browser.completed == "analytics")
        browser.walk(-1)
        browser.walk(-1)
        #expect(browser.completed == "analytics")
    }

    /// ⌥⌫ over the address the field is finishing takes the offered ending
    /// off and keeps it off, as ⌫ does, so the next one reaches the words
    /// typed. It used to take the ending off only for the field to put it
    /// straight back (feedback #83).
    @MainActor @Test func wordDeletesTakeTheOfferedEndingOff() {
        _ = NSApplication.shared
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let page = "https://github.com/team2027/queue/pull/139/changes"
        browser.history = History([Visit(url: page, key: Address.pretty(URL(string: page)!).lowercased(),
                                         title: "Pull request", count: 5, last: Date(), typed: 5)])
        let typed = "github.com/team2027/queue/pull/"
        let field = NSTextField(), coordinator = AddressField.Coordinator(browser: browser)
        let changed = Notification(name: NSControl.textDidChangeNotification, object: field)

        // A letter typed: the field finishes the address.
        field.stringValue = typed
        coordinator.controlTextDidChange(changed)
        #expect(field.stringValue == typed + "139/changes")

        for command in [#selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:))] {
            field.stringValue = typed + "139/changes"
            #expect(!coordinator.control(field, textView: NSTextView(), doCommandBy: command))
            field.stringValue = typed
            coordinator.controlTextDidChange(changed)
            #expect(field.stringValue == typed, "\(command)")
            #expect(browser.completed == typed, "\(command)")
        }
    }
}
