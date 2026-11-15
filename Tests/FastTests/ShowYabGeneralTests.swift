import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ShowYabGeneralTests {
    private let queries = ["show yab", "show", "bring", "global shortcut", "hotkey"]

    @Test func bothSearchesFindTheGeneralRow() throws {
        let item = try #require(SettingsItem.all.first { $0.id == "show-yab" })
        #expect(item.page == .general)
        #expect(item.anchor(Preferences()) == "show-yab")
        for words in queries {
            #expect(SettingsResult.search(words).rows.contains(.item(item)), "Settings: \(words)")
            #expect(SettingsPage.general.score(words) != nil, "Field: \(words)")
            #expect(SettingsPage.general.fieldItem(words) == item, "Destination: \(words)")
            #expect(SettingsPage.general.fieldItem(words + " settings") == item)
        }
        #expect(SettingsResult.search("show yab").best == .item(item))
        #expect(SettingsPage.general.score("s") == nil)
        #expect(SettingsPage.general.fieldItem("general") == nil)
        #expect(SettingsPage.general.fieldItem("downloads") == nil)
        #expect(SettingsPage.general.fieldItem("show yab tutorial online") == nil)
        #expect(SettingsPage.shortcuts.fieldItem("show yab") == nil)
    }

    @Test func composedFieldKeepsTheSettingAndOpensItsRow() throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let commands = FieldUnder.shared.commands
        let suggest = browser.prefs.searchSuggest, requests = browser.prefs.fieldRequests
        let page = Store.settings.object(forKey: "settings.page")
        let row = Store.settings.object(forKey: "settings.row")
        FieldUnder.shared.commands = true
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        defer {
            browser.tuning = false
            browser.dismiss(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            FieldUnder.shared.commands = commands
            browser.prefs.searchSuggest = suggest; browser.prefs.fieldRequests = requests
            Store.settings.set(page, forKey: "settings.page")
            Store.settings.set(row, forKey: "settings.row")
        }
        for words in queries {
            let url = URL(string: "https://\(words.replacingOccurrences(of: " ", with: "-")).example.test/help")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url), title: words,
                                             count: 100, last: Date(), typed: 100)])
            browser.openFresh()
            browser.replaceTyped(words)
            let offer = try #require(browser.offers.first { $0.kind == .setting(.general) }, "\(words)")
            #expect(offer.settingAnchor == "show-yab")
            #expect(offer.id == "set:general")
            #expect(!browser.offers.contains { if case .command = $0.kind { return $0.key == "Show Yab" }; return false })
            let web = [Suggestion(key: words + " mac", title: "", url: nil, kind: .suggested)]
            let merged = SearchSuggestions.merge(web, into: browser.offers, lead: browser.query.lead)
            #expect(merged.list.contains(offer), "After web suggestions: \(words)")
            browser.take(offer)
            #expect(browser.tuning)
            #expect(SettingsWindow.shared.model?.page == .general)
            #expect(SettingsWindow.shared.model?.spot?.id == "show-yab")
            browser.tuning = false
        }
    }
}
