import AppKit
import Testing
import WebKit
@testable import Fast

/// The production composition, row factory and native dressing. No Browser,
/// extension controller, real page, clipboard or translation model is used.
@MainActor @Suite(.serialized)
struct SelectionTranslationMenuTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private func native(_ identifier: String, enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
        row.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + identifier)
        row.isEnabled = enabled
        return row
    }

    private func menu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    private func page() -> PageView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return PageView(frame: .zero, configuration: configuration)
    }

    @Test(arguments: ["SearchWeb", "LookUp", "Translate", "Copy", "Cut"])
    func selectedTextAndEditableSelectionDoNotAskForWholePageRows(identifier: String) {
        let row = native(identifier), menu = menu([row])
        var calls = 0
        PageView.appendPageTranslation(to: menu, selectedWords: nil) {
            calls += 1
            return [NSMenuItem(title: "Translate Page", action: nil, keyEquivalent: "")]
        }
        #expect(calls == 0 && menu.items.count == 1 && menu.items[0] === row)
    }

    @Test func selectedWordsInsideALinkScopeTheMenuWithoutASearchRow() {
        let menu = menu([native("OpenLink"), native("CopyLink")])
        let source = URL(string: "https://selection.fixture.invalid/article")!
        let read = PageView.currentMenuWords(("selected words", "https://selection.fixture.invalid/next", source, 99), source: source, now: 100)
        var calls = 0
        PageView.appendPageTranslation(to: menu, selectedWords: read?.words) { calls += 1; return [] }
        #expect(calls == 0 && menu.items.count == 2)
    }

    @Test(arguments: ["stale", "other-document", "empty", "none"])
    func aPageOrUnselectedLinkDoesNotInheritOldSelection(scope: String) {
        let source = URL(string: "https://selection.fixture.invalid/article")!
        let snapshot: PageView.MenuWords?
        switch scope {
        case "stale": snapshot = ("old words", nil, source, 96)
        case "other-document": snapshot = ("old words", nil, URL(string: "https://selection.fixture.invalid/previous"), 99)
        case "empty": snapshot = (" \n\t ", nil, source, 99)
        default: snapshot = nil
        }
        let read = PageView.currentMenuWords(snapshot, source: source, now: 100)
        let menu = menu([native("OpenLink"), native("CopyLink")])
        let row = PageMenuItem("Translate Page") {}
        var calls = 0
        PageView.appendPageTranslation(to: menu, selectedWords: read?.words) { calls += 1; return [row] }
        #expect(calls == 1 && menu.items.last === row)
    }

    @Test func caretOnlyFieldDoesNotBecomeASelectedTextMenu() {
        let menu = menu([native("Cut", enabled: false), native("Copy", enabled: false), native("Paste")])
        let row = PageMenuItem("Translate Page") {}
        PageView.appendPageTranslation(to: menu, selectedWords: nil) { [row] }
        #expect(menu.items.last === row)
    }

    @Test(arguments: [false, true])
    func bothSelectionTranslationRowsKeepTheirGlyphAndOriginalTargets(reverse: Bool) throws {
        let page = page()
        defer { page.stopLoading(); Tab.end(page) }
        let command = try #require(SelectionCommand.builtIn.first { $0.id == "translate" })
        let own = page.selectionMenuItem(command), native = native("Translate")
        let nativeTarget = NSObject(), action = NSSelectorFromString("nativeTranslate:")
        native.target = nativeTarget
        native.action = action
        let menu = menu(reverse ? [own, native] : [native, own])
        PageView.appendPageTranslation(to: menu, selectedWords: nil) {
            Issue.record("The selected text must not call the page translation provider")
            return []
        }
        PageView.dress(menu)
        #expect(native.image === MenuMark.image("yab.translate"))
        #expect(own.image === MenuMark.image("yab.translate"))
        #expect(native.target === nativeTarget && native.action == action)
        #expect(own.target === page && own.action == NSSelectorFromString("runSelectionCommand:"))
        #expect((own.representedObject as? String) == command.id)
        #expect(own.title == SelectionCommand.menuTitle(command.name))
    }

    @Test func theSelectionExceptionDoesNotDisableOtherIconDeduplication() {
        let first = native("CopyImage"), second = native("Copy")
        let menu = menu([first, second])
        PageView.dress(menu)
        #expect(first.image === MenuMark.image("yab.copyframe.image"))
        #expect(second.image === MenuMark.image("yab.copyframe.text"))
        // These two known rows have different marks; repeated exact marks
        // elsewhere retain the established empty-column variant.
        let another = native("CopyImage")
        menu.addItem(another)
        PageView.dress(menu)
        #expect(first.image === MenuMark.image("yab.copyframe.image"))
        #expect(another.image === MenuMark.image(nil))
    }

    @Test(arguments: ["Translate Page to Russian", "Stop Translating", "Show Original Page"])
    func ordinaryPageKeepsTheSameTranslationRowsSubmenuAndHandler(title: String) {
        var calls = 0
        let primary = PageMenuItem(title) { calls += 1 }
        primary.identifier = NSUserInterfaceItemIdentifier("YabTranslatePage")
        let to = NSMenuItem(title: "Translate To", action: nil, keyEquivalent: "")
        to.identifier = NSUserInterfaceItemIdentifier("YabTranslateTo")
        let languages = NSMenu()
        languages.addItem(PageMenuItem("Russian") {})
        to.submenu = languages
        let menu = menu([native("Reload")])
        PageView.appendPageTranslation(to: menu, selectedWords: nil) { [primary, to] }
        PageView.dress(menu)
        #expect(menu.items.suffix(2).elementsEqual([primary, to], by: { $0 === $1 }))
        #expect(to.submenu === languages && primary.image === MenuMark.image("yab.translate"))
        menu.performActionForItem(at: menu.index(of: primary))
        #expect(calls == 1)
    }

    @Test func ordinaryPageUsesTheExistingPageTranslationProvider() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, bench: true, configuration: configuration)
        defer { tab.close() }
        tab.setAddressOptimistically(URL(string: "https://selection.fixture.invalid/article")!)
        let translation = PageTranslation(), menu = menu([native("Reload")])
        PageView.appendPageTranslation(to: menu, selectedWords: nil) { translation.menuItems(for: tab) }
        let rows = Array(menu.items.suffix(2))
        #expect(rows.map { $0.identifier?.rawValue } == ["YabTranslatePage", "YabTranslateTo"])
        #expect(rows[0].title.hasPrefix("Translate Page to ") && rows[1].submenu != nil)
        #expect(translation.barTitle(for: tab) == "Translate Page" && translation.canTranslate(tab))
        #expect(tab.builtPage == nil, "Menu composition must not wake the tab or translate anything")
    }
}
