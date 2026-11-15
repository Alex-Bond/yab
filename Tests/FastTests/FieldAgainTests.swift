import AppKit
import Foundation
import Testing
@testable import Fast

/// ⌘T again puts ⌘T's field away and ⌘L again ⌘L's, as Arc's Command Bar
/// does (feedback #165b), and a paste into the field adds no space and
/// comes trimmed (#164a). evals/field-keys has both with real keys.
struct FieldAgainTests {
    @MainActor private func window() -> (Browser, UUID, Tab) {
        let id = UUID()
        let browser = Browser(windowID: id)
        let page = browser.open(URL(string: "about:blank#page")!, foreground: true)
        return (browser, id, page)
    }

    @MainActor private func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    @MainActor @Test func newTabAgainPutsItsFieldAway() {
        let (browser, id, page) = window()
        defer { forget(id) }
        browser.pressNewTab()
        #expect(browser.fieldShowing && browser.asked == .tab)
        browser.typed = "abc"
        browser.pressNewTab()
        #expect(!browser.fieldShowing && browser.asked == nil)
        #expect(browser.typed.isEmpty)
        #expect(browser.active === page && browser.tabs.count == 1)
        browser.pressNewTab()
        #expect(browser.fieldShowing && browser.asked == .tab && browser.typed.isEmpty)
    }

    @MainActor @Test func openAddressAgainPutsItsFieldAway() {
        let (browser, id, page) = window()
        defer { forget(id) }
        browser.pressOpenAddress()
        #expect(browser.fieldShowing && browser.asked == nil && browser.untouched != nil)
        browser.typed = "ab"
        browser.pressOpenAddress()
        #expect(!browser.fieldShowing)
        #expect(browser.active === page)
    }

    @MainActor @Test func theOtherKeyTurnsTheFieldIntoItsOwn() {
        let (browser, id, _) = window()
        defer { forget(id) }
        browser.pressNewTab()
        browser.pressOpenAddress()
        #expect(browser.fieldShowing && browser.asked == nil && browser.untouched != nil)
        browser.pressNewTab()
        #expect(browser.fieldShowing && browser.asked == .tab && browser.typed.isEmpty)
    }

    /// Inside one of the field's places the keys are as they were.
    @MainActor @Test func inAPlaceNewTabStillAsksForANewTab() {
        let (browser, id, _) = window()
        defer { forget(id) }
        browser.pressOpenAddress()
        browser.query.place = .passwords
        browser.pressOpenAddress()
        #expect(browser.fieldShowing)
        browser.query.place = nil
        browser.dismiss()
        // Split View's field: ⌘T asks for a tab instead.
        browser.openFresh(.split)
        browser.pressNewTab()
        #expect(browser.fieldShowing && browser.asked == .tab)
    }

    /// A tabless window can put the field away and bring it back.
    @MainActor @Test func withNoTabTheFieldToggles() {
        let id = UUID()
        let browser = Browser(windowID: id)
        defer { forget(id) }
        browser.dismiss()
        #expect(!browser.fieldShowing)
        browser.pressNewTab()
        #expect(browser.fieldShowing)
        browser.pressNewTab()
        #expect(!browser.fieldShowing)
    }

    @MainActor @Test func pastedWordsAreTrimmedAsChromeTrimsThem() {
        #expect(AddressEditor.pasted("https://example.com/path\n") == "https://example.com/path")
        #expect(AddressEditor.pasted("https://example.com/path\r\n") == "https://example.com/path")
        #expect(AddressEditor.pasted("  best pizza  ") == "best pizza")
        #expect(AddressEditor.pasted("\tbest pizza\n") == "best pizza")
        #expect(AddressEditor.pasted("https://exa\n  mple.com/") == "https://example.com/")
        #expect(AddressEditor.pasted("best  pizza") == "best  pizza")
        #expect(AddressEditor.pasted("one\ttwo") == "one\ttwo")
        #expect(AddressEditor.pasted(" \n ") == "")
    }

    /// A word copied with AppKit's smart paste type, as a double click on a
    /// page chooses it, lands with no space beside the letters before it.
    @MainActor @Test func aSmartPasteAddsNoSpace() {
        let editor = AddressEditor.make()
        editor.string = "go"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let board = NSPasteboard(name: NSPasteboard.Name("yab-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let smart = NSPasteboard.PasteboardType("NeXT smart paste pasteboard type")
        board.declareTypes([.string, smart], owner: nil)
        board.setString("yabword", forType: .string)
        board.setData(Data(), forType: smart)
        #expect(editor.readSelection(from: board, type: .string))
        #expect(editor.string == "goyabword")
        #expect(!editor.smartInsertDeleteEnabled && editor.isFieldEditor && editor.allowsUndo)
    }
}
