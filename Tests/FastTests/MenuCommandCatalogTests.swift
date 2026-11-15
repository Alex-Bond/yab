import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct MenuCommandCatalogTests {
    private func withPage(_ body: (Browser, Tab) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let suite = "dev.serafim.fast.test.menu-commands-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        browser.favorites = FieldFavorites(defaults: defaults)
        let tab = Tab(bench: true)
        let host = "command-\(UUID().uuidString.lowercased()).example"
        let url = URL(string: "https://\(host)/")!
        tab.restore(url: url, title: "Catalog page")
        browser.lay([tab])
        browser.activeID = tab.id
        let suggestions = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
        let menuCommands = browser.prefs.menuCommands
        let menuSetting = Store.settings.object(forKey: MenuCommands.key)
        let commands = FieldUnder.shared.commands
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        browser.prefs.menuCommands = true
        FieldUnder.shared.commands = true
        browser.history = History([])
        defer {
            defaults.removePersistentDomain(forName: suite)
            if let name = DevSites.name(url) { DevSites.forget(name) }
            browser.dismiss()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggestions
            browser.prefs.fieldRequests = requests
            browser.prefs.menuCommands = menuCommands
            Store.settings.set(menuSetting, forKey: MenuCommands.key)
            FieldUnder.shared.commands = commands
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        try body(browser, tab)
    }

    @Test func experimentalSwitchRestoresLegacySearchAndDisablesSavedNewActions() throws {
        try withPage { browser, tab in
            let full = browser.prefs.fullURL
            let bar = browser.prefs.addressBar
            defer { browser.prefs.fullURL = full; browser.prefs.addressBar = bar }
            browser.prefs.addressBar = true
            browser.prefs.fullURL = false
            let target = try #require(MenuCommands.targets(.developerPanel, in: browser).first)
            let favorite = try #require(FieldFavorite.of(target.offer))
            browser.favorites.all = [favorite]
            browser.setDevMode(tab, false)
            browser.replaceTyped("developer mode")
            #expect(browser.offers.first?.kind == .command(.devModeOn))

            browser.prefs.menuCommands = false
            #expect(!Store.settings.bool(forKey: MenuCommands.key))
            #expect(Command.reload.available(in: browser))
            for command in MenuCommands.entries.keys where !MenuCommands.everyone.contains(command) { #expect(!command.available(in: browser)) }
            #expect(MenuCommands.targets(in: browser).allSatisfy { MenuCommands.everyone.contains($0.operation) })
            #expect(Command.tidyTabs.matchesExactly("organize today tabs", in: browser))
            #expect(!MenuCommands.runTarget(target.id, in: browser))
            #expect(browser.favoriteRows(now: Date()).isEmpty)
            Command.showFullURL.run(in: browser)
            #expect(!browser.prefs.fullURL)
            #expect(!Command.devModeOn.matchesExactly("developer mode", in: browser))
            #expect(!Command.devModeOn.opens(in: browser))
            #expect(Command.devModeOn.score("developer mode", in: browser) == Command.devModeOn.score("developer mode", expanded: false))
            browser.replaceTyped("developer mode")
            #expect(browser.offers.first?.kind != .command(.devModeOn))
            for actions in [true, false] {
                browser.query.actionsPage = actions
                browser.replaceTyped(Command.showFullURL.title)
                #expect(!browser.offers.contains { $0.kind == .command(.showFullURL) })
                #expect(!browser.offers.contains { $0.menuTargetID != nil })
            }

            browser.prefs.menuCommands = true
            #expect(Store.settings.bool(forKey: MenuCommands.key))
            #expect(browser.favoriteRows(now: Date()).first?.menuTargetID == target.id)
            #expect(Command.showFullURL.available(in: browser))
            browser.replaceTyped("developer mode")
            #expect(browser.offers.first?.kind == .command(.devModeOn))
        }
    }

    @Test func sharePageLeadsHistoryAndSuggestionsAndAppearsInActions() throws {
        try withPage { browser, tab in
            let url = URL(string: "https://share.example.test/page")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                title: "Share Page", count: 200, last: Date(), typed: 100)])
            let saved = Keymap.shared.chosen[Shortcut.Action.sharePage.rawValue]
            defer {
                if let saved { Keymap.shared.set(Hotkey(stored: saved), for: .sharePage) }
                else { Keymap.shared.reset(.sharePage) }
            }
            for key: Hotkey? in [nil, Hotkey("s", .control)] {
                Keymap.shared.set(key, for: .sharePage)
                #expect(Command.sharePage.keys == (key?.text ?? ""))
                for actions in [false, true] {
                    browser.query.actionsPage = actions
                    for words in ["Share Page…", "share page", "share this page", "share link"] {
                        browser.replaceTyped(words)
                        #expect(browser.offers.first?.kind == .command(.sharePage))
                        let merged = SearchSuggestions.merge([
                            Suggestion(key: words + " chrome", title: "", url: nil, kind: .suggested)
                        ], into: browser.offers, lead: browser.query.lead)
                        #expect(merged.list.first?.kind == .command(.sharePage))
                    }
                }
            }
            #expect(Command.sharePage.available(in: browser))
            #expect(Command.sharePage.opens(in: browser))
            #expect(MenuCommands.entries[.sharePage]?.shortcut == .sharePage)
            let empty = Browser(windowID: UUID())
            #expect(!Command.sharePage.available(in: empty))
            _ = tab
        }
    }

    @Test func everyRegisteredActionHasSearchableWordsAndAPreparedScore() {
        for (command, entry) in MenuCommands.entries {
            #expect(Command.allCases.contains(command))
            #expect(!entry.title.isEmpty)
            for words in [entry.title] + entry.aliases {
                #expect(command.matchesExactly(words), "\(command): \(words)")
                #expect(command.score(words) == 4, "\(command): \(words)")
                #expect(command.score(words) == command.scoreUnprepared(words))
            }
        }
        for command in Command.allCases {
            #expect(!command.title.isEmpty)
            #expect(!command.symbol.isEmpty)
        }
    }

    @Test func developerModeLeadsHistoryAndWebSuggestionsInBothStates() throws {
        try withPage { browser, tab in
            let url = URL(string: "https://developer.example.test/mode")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                                             title: "Developer Mode in another browser", count: 200, last: Date(), typed: 100)])
            for enabled in [false, true] {
                browser.setDevMode(tab, enabled)
                let command: Command = enabled ? .devModeOff : .devModeOn
                for words in ["developer mode", "dev mode", command.title] {
                    browser.replaceTyped(words)
                    #expect(browser.ending == nil)
                    #expect(browser.offers.first?.kind == .command(command), "\(words), enabled: \(enabled)")
                    #expect(browser.query.lead == 0)
                    if words == "developer mode" { #expect(browser.offers.contains { $0.url == url }) }
                    let suggestions = ["developer mode chrome", "developer mode iphone",
                                       "developer mode ios", "developer mode chromebook"].map {
                        Suggestion(key: $0, title: "", url: nil, kind: .suggested)
                    }
                    let merged = SearchSuggestions.merge(suggestions, into: browser.offers, lead: browser.query.lead)
                    #expect(merged.list.first?.kind == .command(command))
                    #expect(merged.lead == 0)
                    #expect(merged.list.filter { $0.kind == .command(command) }.count == 1)
                }
            }
        }
    }

    @Test func addingExtensionsLeadsHistoryAndSuggestionsAndAppearsInActions() throws {
        try withPage { browser, _ in
            let url = URL(string: "https://extension.example.test/add")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                                             title: "Add Extension", count: 200, last: Date(), typed: 100)])
            for actions in [false, true] {
                browser.query.actionsPage = actions
                for words in ["Add Extension", "install extension", "custom extension", "unpacked extension", "load unpacked", "A Folder on This Mac"] {
                    browser.replaceTyped(words)
                    #expect(browser.offers.first?.kind == .command(.addExtension))
                    let suggestions = [Suggestion(key: words + " chrome", title: "", url: nil, kind: .suggested)]
                    let merged = SearchSuggestions.merge(suggestions, into: browser.offers, lead: browser.query.lead)
                    #expect(merged.list.first?.kind == .command(.addExtension))
                    #expect(Command.addExtension.available(in: browser))
                    #expect(Command.addExtension.opens(in: browser))
                    #expect(MenuCommands.entries[.addExtension]?.shortcut == nil)
                }
                // The short toolbar label can also match Addresses in Actions.
                // It remains an indexed action above history and web guesses.
                browser.replaceTyped("Add")
                let add = try #require(browser.offers.firstIndex { $0.kind == .command(.addExtension) },
                    "Actions=\(actions), available=\(Command.addExtension.available(in: browser)), exact=\(Command.addExtension.matchesExactly("Add", in: browser)), score=\(String(describing: Command.addExtension.score("Add", in: browser))), rows=\(browser.offers.map { String(describing: $0.kind) })")
                for (index, row) in browser.offers.enumerated() where row.kind == .visited || row.kind == .suggested {
                    #expect(add < index)
                }
                let merged = SearchSuggestions.merge([Suggestion(key: "Add chrome", title: "", url: nil, kind: .suggested)], into: browser.offers, lead: browser.query.lead)
                let mergedAdd = try #require(merged.list.firstIndex { $0.kind == .command(.addExtension) })
                for (index, row) in merged.list.enumerated() where row.kind == .visited || row.kind == .suggested {
                    #expect(mergedAdd < index)
                }
            }
        }
    }

    @Test func importingExtensionsUsesTheSameAvailabilityAndLeadsHistoryAndSuggestions() throws {
        try withPage { browser, _ in
            let engine = Store.settings.object(forKey: PageEngineSelection.key)
            let list = Extensions.of(browser)
            let saved = list.installed
            defer {
                Store.settings.set(engine, forKey: PageEngineSelection.key)
                list.joinList(saved)
            }
            Store.settings.set(PageEngineKind.chromium.rawValue, forKey: PageEngineSelection.key)
            let id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
            list.takeNative(id: id, name: "Import fixture", version: "1.0", enabled: true)
            let native = ChromiumExtensions.of(browser)
            let busy = native.busy
            defer { native.busy = busy }
            native.busy = false
            #expect(Command.importExtensions.available(in: browser))
            let url = URL(string: "https://extensions.example.test/import")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url), title: "Import Extensions", count: 200, last: Date(), typed: 100)])
            for actions in [false, true] {
                browser.query.actionsPage = actions
                for words in ["Import", "Import Extensions", "Import Yab Extensions"] {
                    browser.replaceTyped(words)
                    #expect(browser.offers.first?.kind == .command(.importExtensions))
                    let merged = SearchSuggestions.merge([Suggestion(key: words + " chrome", title: "", url: nil, kind: .suggested)], into: browser.offers, lead: browser.query.lead)
                    #expect(merged.list.first?.kind == .command(.importExtensions))
                }
            }
            native.busy = true
            #expect(!Command.importExtensions.available(in: browser))
        }
    }

    @Test func rankingAnActionAliasDoesNotGiveItDefaultReturn() throws {
        try withPage { browser, _ in
            let url = URL(string: "https://refresh.example.test/")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                                             title: "Refresh", count: 200, last: Date(), typed: 100)])
            browser.replaceTyped("refresh")
            #expect(browser.ending == nil)
            #expect(browser.offers.first?.kind == .command(.reload))
            let lead = try #require(browser.query.lead)
            #expect(browser.offers[lead].kind == .search || browser.offers[lead].kind == .task)
            #expect(lead != 0)
            let suggested = Suggestion(key: "refresh page", title: "", url: nil, kind: .suggested)
            let merged = SearchSuggestions.merge([suggested], into: browser.offers, lead: lead)
            #expect(merged.list.first?.kind == .command(.reload))
            #expect(merged.lead.map { merged.list[$0].id } == browser.offers[lead].id)
            // A longer query stays a web search, rather than stealing a word
            // somewhere inside a feature's name.
            browser.replaceTyped("developer mode chrome")
            #expect(browser.offers.first?.kind != .command(.devModeOn))
        }
    }

    @Test func measureMenuNameFindsTheExistingFieldActionInBothStates() throws {
        try withPage { browser, tab in
            browser.setDevMode(tab, true)
            let url = URL(string: "https://measure.example.test/")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                                             title: "Measure", count: 200, last: Date(), typed: 100)])
            for measuring in [false, true] {
                tab.measuring = measuring
                let command: Command = measuring ? .hideRulers : .measurePage
                let other: Command = measuring ? .measurePage : .hideRulers
                #expect(command.available(in: browser))
                #expect(!other.available(in: browser))
                for words in ["Measure", command.title] {
                    browser.replaceTyped(words)
                    #expect(browser.ending == nil)
                    #expect(browser.offers.first?.kind == .command(command))
                    if words == "Measure" { #expect(browser.offers.contains { $0.url == url }) }
                    let suggested = Suggestion(key: words + " tutorial", title: "", url: nil, kind: .suggested)
                    let merged = SearchSuggestions.merge([suggested], into: browser.offers, lead: browser.query.lead)
                    #expect(merged.list.first?.kind == .command(command))
                    #expect(merged.list.contains { $0.kind == .suggested })
                    browser.query.actionsPage = true
                    browser.replaceTyped(words)
                    #expect(browser.offers.contains { $0.kind == .command(command) })
                    browser.query.actionsPage = false
                }
                command.run(in: browser)
                #expect(tab.measuring == !measuring)
            }
            browser.setDevMode(tab, false)
            #expect(!Command.measurePage.available(in: browser))
            #expect(!Command.hideRulers.available(in: browser))
        }
    }

    @Test func actionsAndPlainSearchExposeTheSameNewCommands() throws {
        try withPage { browser, _ in
            for command in [Command.inspectElement, .errorsAndNetwork, .smallWindow, .copyDiagnostics,
                            .captureFullPage, .capturePortrait, .copyPageMarkdown, .savePageMarkdown] {
                #expect(command.available(in: browser))
                browser.query.actionsPage = true
                browser.replaceTyped(command.title)
                #expect(browser.offers.contains { $0.kind == .command(command) }, "\(command)")
                browser.query.actionsPage = false
                browser.replaceTyped(command.title)
                #expect(browser.offers.contains { $0.kind == .command(command) }, "\(command)")
            }
        }
    }

    @Test func explicitSiteAndAppearanceStatesHaveOneAvailableAction() throws {
        try withPage { browser, _ in
            let look = browser.prefs.look
            let bar = browser.prefs.addressBar
            let full = browser.prefs.fullURL
            defer { browser.prefs.look = look; browser.prefs.addressBar = bar; browser.prefs.fullURL = full }
            browser.prefs.look = .light
            #expect(!Command.lightTheme.available(in: browser))
            #expect(Command.darkTheme.available(in: browser))
            Command.darkTheme.run(in: browser)
            #expect(browser.prefs.look == .dark)
            #expect(!Command.darkTheme.available(in: browser))
            browser.prefs.addressBar = true
            browser.prefs.fullURL = false
            #expect(Command.showFullURL.available(in: browser))
            #expect(!Command.showSiteURL.available(in: browser))
            Command.showFullURL.run(in: browser)
            #expect(!Command.showFullURL.available(in: browser))
            #expect(Command.showSiteURL.available(in: browser))
        }
    }

    @Test func newAndExistingCommandsShowRemappedKeys() {
        let pairs: [(Command, Shortcut.Action)] = [(.inspectElement, .inspectElement), (.nextSpace, .nextSpace),
                                                  (.reload, .reload), (.devModeOn, .devMode), (.lastTab, .tab9),
                                                  (.measurePage, .measure), (.hideRulers, .measure)]
        for (command, action) in pairs {
            let old = Keymap.shared.keys(action)
            let key = Hotkey("f19", [.control, .option, .command])
            Keymap.shared.set(key, for: action)
            #expect(command.keys == Keymap.shared.text(action))
            #expect(command.keys == key.text)
            Keymap.shared.set(old, for: action)
        }
    }

    @Test func developerPanelsHaveTypedRoutesAndStaleTargetsCannotRun() throws {
        try withPage { browser, tab in
            let targets = MenuCommands.targets(.developerPanel, in: browser)
            let network = try #require(targets.first { $0.title == "Open Network Panel" })
            #expect(network.matchesExactly("network"))
            #expect(network.offer.menuTargetID == network.id)
            FieldUnder.shared.commands = false
            #expect(!FieldUnder.shared.wants(network.offer))
            FieldUnder.shared.commands = true
            #expect(Set(targets.map(\.id)).count == targets.count)
            browser.replaceTyped("network")
            #expect(browser.offers.first?.menuTargetID == network.id)
            #expect(!MenuCommands.runTarget("developerPanel:unknown-target", in: browser))
            browser.lay([]); browser.activeID = nil
            #expect(!MenuCommands.runTarget(network.id, in: browser))
        }
    }

    @Test func namedFoldersUseStableIdsAndFavoritesKeepTheSameDestination() throws {
        try withPage { browser, tab in
            let nest = Nest(name: "Catalog Folder \(UUID().uuidString.prefix(8))", open: false)
            tab.kept = true
            tab.nest = nest
            let rename = try #require(MenuCommands.targets(.renameFolder, in: browser).first { $0.id.hasSuffix(nest.id.uuidString) })
            browser.replaceTyped(rename.title)
            #expect(browser.offers.first?.menuTargetID == rename.id)
            let favorite = try #require(FieldFavorite.of(rename.offer))
            #expect(favorite.what == .menuTarget(rename.id))
            #expect(MenuCommands.runTarget(rename.id, in: browser))
            #expect(browser.folderBook.naming == nest.id)
            tab.nest = nil
            #expect(!MenuCommands.runTarget(rename.id, in: browser))
        }
    }

    @Test func favoritesFollowExplicitToggleStates() {
        for pair in [(Command.muteTab, Command.unmuteTab), (.showFullURL, .showSiteURL),
                     (.keepSiteAwake, .allowSiteSleep), (.measurePage, .hideRulers), (.showChat, .hideChat)] {
            #expect(pair.0.kept == pair.1.kept)
            #expect(pair.0.halves == [pair.0, pair.1])
        }
        #expect(Command.stopTranslation.kept == .translatePage)
        #expect(Command.showOriginalPage.halves == [.translatePage, .showOriginalPage, .stopTranslation])
    }

    @Test func aSmallWindowsFieldCannotActOnTheMainWindowsPage() throws {
        try withPage { browser, _ in
            browser.fieldGuest = Tab(bench: true)
            defer { browser.fieldGuest = nil }
            #expect(!Command.copyPageMarkdown.available(in: browser))
            #expect(!Command.moveToSpace.available(in: browser))
            #expect(!Command.closeWindow.available(in: browser))
            #expect(Command.shortcuts.available(in: browser))
            #expect(MenuCommands.targets(in: browser).isEmpty)
        }
    }

    @Test func privateWindowsNeverListPersonalDestinations() throws {
        try withPage { browser, _ in
            let tab = Tab(shy: true, bench: true)
            tab.restore(url: URL(string: "https://private.example.test/")!, title: "Private")
            browser.lay([tab]); browser.activeID = tab.id
            #expect(browser.privateBrowsing)
            let personal: Set<Command> = [.switchSpace, .moveToSpace, .moveFolder, .openFolder, .closeFolder,
                                          .renameFolder, .customizeFolder, .ungroupFolder, .newLiveFolder,
                                          .updateLiveFolder, .stopLiveFolder]
            #expect(!MenuCommands.targets(in: browser).contains { personal.contains($0.operation) })
            #expect(!Command.newSpace.available(in: browser))
            #expect(!Command.renameSpace.available(in: browser))
            #expect(!Command.savePageMarkdown.available(in: browser))
        }
    }
}
