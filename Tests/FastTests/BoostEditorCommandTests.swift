import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct BoostEditorCommandTests {
    private func world(_ check: (Browser, Tab, String) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID()), tab = Tab(bench: true)
        let host = "editor-\(UUID().uuidString.lowercased()).example.test"
        tab.restore(url: URL(string: "https://\(host)/")!, title: "Editor fixture")
        browser.lay([tab]); browser.activeID = tab.id
        let commands = FieldUnder.shared.commands, suggestions = browser.prefs.searchSuggest, requests = browser.prefs.fieldRequests, menus = browser.prefs.menuCommands
        FieldUnder.shared.commands = true; browser.prefs.searchSuggest = false; browser.prefs.fieldRequests = false
        defer {
            BoostEditor.shared.close()
            BoostEditorLooks.shared.set(BoostEditorLook(), host: host, profile: AddonProfiles.of(tab))
            BoostEditorLooks.shared.flush()
            FieldUnder.shared.commands = commands; browser.prefs.searchSuggest = suggestions; browser.prefs.fieldRequests = requests; browser.prefs.menuCommands = menus
            browser.dismiss(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        try check(browser, tab, host)
    }

    @Test func customizeLeadsHistoryAndSuggestionsAndIsInActions() {
        world { browser, _, _ in
            let url = URL(string: "https://another.example.test/customize")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url), title: "Customize Site", count: 200, last: Date(), typed: 100)])
            for expanded in [false, true] {
                browser.prefs.menuCommands = expanded
                for words in ["customize", "customize site", "Customize…", Command.customizeSite.title, "boost editor"] {
                    browser.query.actionsPage = false; browser.replaceTyped(words)
                    #expect(browser.offers.first?.kind == .command(.customizeSite), "\(words)")
                    let web = ["customize chrome", "customize site css", "customize browser"].map { Suggestion(key: $0, title: "", url: nil, kind: .suggested) }
                    #expect(SearchSuggestions.merge(web, into: browser.offers, lead: browser.query.lead).list.first?.kind == .command(.customizeSite))
                    browser.query.actionsPage = true; browser.replaceTyped(words)
                    #expect(browser.offers.contains { $0.kind == .command(.customizeSite) })
                }
            }
        }
    }

    @Test func toggleCommandsFollowStateAndRunAgainstThisProfile() {
        world { browser, tab, host in
            var look = BoostEditorLook(); look.amount = 0.6
            BoostEditorLooks.shared.set(look, host: host, profile: AddonProfiles.of(tab))
            for enabled in [true, false] {
                look.enabled = enabled
                BoostEditorLooks.shared.set(look, host: host, profile: AddonProfiles.of(tab))
                let command: Command = enabled ? .customizationOff : .customizationOn
                let other: Command = enabled ? .customizationOn : .customizationOff
                #expect(command.available(in: browser)); #expect(!other.available(in: browser))
                let url = URL(string: "https://another.example.test/customization")!
                browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url), title: command.title, count: 200, last: Date(), typed: 100)])
                for words in [command.title, "customization", "site customization"] {
                    browser.query.actionsPage = false; browser.replaceTyped(words)
                    #expect(browser.offers.first?.kind == .command(command))
                    let web = [Suggestion(key: words + " browser", title: "", url: nil, kind: .suggested)]
                    #expect(SearchSuggestions.merge(web, into: browser.offers, lead: browser.query.lead).list.first?.kind == .command(command))
                    browser.query.actionsPage = true; browser.replaceTyped(words)
                    #expect(browser.offers.contains { $0.kind == .command(command) })
                    #expect(!browser.offers.contains { $0.kind == .command(other) })
                }
                command.run(in: browser)
                #expect(BoostEditorLooks.shared.look(host: host, profile: AddonProfiles.of(tab)).enabled == !enabled)
            }
            #expect(Command.customizationOff.kept == .customizationOn)
            #expect(Command.customizationOn.halves == [.customizationOn, .customizationOff])
        }
    }

    @Test func unsupportedAndPrivatePagesHaveNoEditorEntry() {
        world { browser, tab, _ in
            tab.restore(url: URL(string: "yab://store")!, title: "Store")
            #expect(!Command.customizeSite.available(in: browser))
            #expect(!BoostAddMenu.make(browser: browser, tab: tab).items.contains { $0.title == "Customize…" })
            let privateTab = Tab(shy: true, bench: true)
            privateTab.restore(url: URL(string: "https://example.test/")!, title: "Private")
            browser.lay([privateTab]); browser.activeID = privateTab.id
            #expect(!Command.customizeSite.available(in: browser))
            #expect(!Command.customizationOff.available(in: browser))
        }
    }

    @Test func reopeningRejectsOldRepliesAndOriginalHoldsReleaseIndependently() {
        world { browser, tab, _ in
            let editor = BoostEditor.shared
            editor.show(browser, tab: tab)
            let previous = editor.identity
            #expect(editor.owns(tab, session: previous))
            editor.close()
            editor.show(browser, tab: tab)
            #expect(!editor.owns(tab, session: previous))
            #expect(editor.owns(tab, session: editor.identity))
            editor.holdOriginal(true, input: .pointer)
            editor.holdOriginal(true, input: .option)
            editor.holdOriginal(false, input: .pointer)
            #expect(editor.original)
            editor.holdOriginal(false, input: .option)
            #expect(!editor.original)
            editor.holdOriginal(true, input: .pointer)
            editor.cancelOriginal()
            #expect(!editor.original)
            editor.close()
            #expect(!editor.owns(tab, session: editor.identity))
            editor.holdOriginal(true, input: .option)
            #expect(!editor.original)
        }
    }
}
