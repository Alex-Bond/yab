import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct FieldPageRowsTests {
    private func settings(_ check: (UserDefaults) throws -> Void) rethrows {
        let name = "dev.serafim.fast.test.page-rows." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try check(defaults)
    }

    private func candidate(_ kind: FieldPageRows.Kind, id: String? = nil) -> FieldPageRows.Candidate {
        let id = id ?? kind.id
        return .init(id: id, kind: kind,
                     row: Suggestion(key: kind.title, title: "", url: nil, kind: .page(id)))
    }

    @Test func savedOrderIsStableAndLimitedToThree() {
        settings { defaults in
            let rows = [candidate(.userscriptCommands, id: "us:a\u{1F}command"),
                        candidate(.extensionButtons, id: "ext:a\u{1F}_execute_action"),
                        candidate(.reader), candidate(.floatVideo), candidate(.translatePage),
                        candidate(.extensionButtons, id: "ext:b\u{1F}_execute_action")]
            #expect(FieldPageRows.hidden(in: defaults) == [.userscriptCommands])
            #expect(FieldPageRows.choose(rows, in: defaults).site.map(\.kind) == [.floatVideo, .translatePage, .reader])
            FieldPageRows.move(.extensionButtons, before: .floatVideo, in: defaults)
            #expect(FieldPageRows.choose(rows, in: defaults).site.map(\.id) == [rows[1].id, rows[5].id, rows[3].id])
            FieldPageRows.add(.userscriptCommands, in: defaults)
            FieldPageRows.move(.userscriptCommands, before: .extensionButtons, in: defaults)
            #expect(FieldPageRows.choose(rows, in: defaults).site.map(\.id) == [rows[0].id, rows[1].id, rows[5].id])
        }
    }

    @Test func baseRowsCanBeHiddenMovedAndAddedBack() {
        settings { defaults in
            #expect(FieldPageRows.base(in: defaults) == [.copy, .markdown, .duplicate])
            FieldPageRows.move(.duplicate, before: .copy, in: defaults)
            #expect(FieldPageRows.base(in: defaults) == [.duplicate, .copy, .markdown])
            FieldPageRows.hide(.copy, in: defaults)
            #expect(FieldPageRows.base(in: defaults) == [.duplicate, .markdown])
            #expect(FieldPageRows.hiddenBase(in: defaults) == [.copy])
            FieldPageRows.add(.copy, in: defaults)
            #expect(FieldPageRows.base(in: defaults) == [.duplicate, .markdown, .copy])
            #expect(FieldPageRows.hiddenBase(in: defaults).isEmpty)
        }
    }

    @Test func developerRowsHaveTheirOwnGroupInSavedOrder() {
        settings { defaults in
            let rows = [candidate(.floatVideo), candidate(.inspectElement), candidate(.errorsAndNetwork), candidate(.hardReload)]
            FieldPageRows.move(.floatVideo, before: .errorsAndNetwork, in: defaults)
            FieldPageRows.move(.hardReload, before: .errorsAndNetwork, in: defaults)
            #expect(FieldPageRows.choose(rows, in: defaults).site.map(\.kind) == [.hardReload, .errorsAndNetwork, .inspectElement])
            for kind in FieldPageRows.standard where kind.developer { FieldPageRows.hide(kind, in: defaults) }
            #expect(FieldPageRows.choose(rows, in: defaults).site.map(\.kind) == [.floatVideo])
        }
    }

    @Test func keptOrderBypassesLimitAndStillNeedsPageContext() {
        settings { defaults in
            let rows = [candidate(.floatVideo), candidate(.reader), candidate(.actualSize), candidate(.tracking), candidate(.fillSign)]
            for row in rows.reversed() {
                FieldPageRows.keep(.init(id: row.id, title: row.row.key), on: true, in: defaults)
            }
            #expect(FieldPageRows.choose(rows, in: defaults).kept.map(\.id) == rows.reversed().map(\.id))
            #expect(FieldPageRows.choose(rows, in: defaults).site.isEmpty)
            FieldPageRows.moveKept(rows[0].id, before: rows[4].id, in: defaults)
            #expect(FieldPageRows.choose(rows, in: defaults).kept.map(\.id) == [rows[0].id, rows[4].id, rows[3].id, rows[2].id, rows[1].id])
            #expect(FieldPageRows.choose([], in: defaults).kept.isEmpty)
            FieldPageRows.hide(.actualSize, in: defaults)
            #expect(!FieldPageRows.entries(in: defaults).contains { $0.id == rows[2].id })
            #expect(!FieldPageRows.choose(rows, in: defaults).kept.contains { $0.kind == .actualSize })
        }
    }

    @Test func hiddenKindCoversEveryInstanceAndAddRestoresIt() {
        settings { defaults in
            let rows = [candidate(.extensionButtons, id: "ext:a\u{1F}_execute_action"),
                        candidate(.extensionButtons, id: "ext:b\u{1F}_execute_browser_action"),
                        candidate(.extensionCommands, id: "ext:a\u{1F}command")]
            FieldPageRows.hide(.extensionButtons, in: defaults)
            FieldPageRows.hide(.extensionButtons, in: defaults)
            #expect(FieldPageRows.choose(rows, in: defaults).site.map(\.id) == [rows[2].id])
            #expect(defaults.stringArray(forKey: FieldPageRows.hiddenKey)?.filter { $0 == FieldPageRows.Kind.extensionButtons.id }.count == 1)
            FieldPageRows.add(.extensionButtons, in: defaults)
            #expect(FieldPageRows.choose(rows + rows, in: defaults).site.map(\.id) == rows.map(\.id))
        }
    }

    @Test func addableHasHiddenThenKeptKindsAndUnkeepsAllTheirInstances() {
        settings { defaults in
            let a = FieldPageRows.Entry(id: "ext:a\u{1F}_execute_action", title: "Open A")
            let b = FieldPageRows.Entry(id: "ext:b\u{1F}_execute_action", title: "Open B")
            FieldPageRows.keep(a, on: true, in: defaults)
            FieldPageRows.keep(b, on: true, in: defaults)
            FieldPageRows.hide(.tracking, in: defaults)
            #expect(a.name == "Open A")
            #expect(!FieldPageRows.visible(in: defaults).contains(.extensionButtons))
            #expect(FieldPageRows.addable(in: defaults) == [.tracking, .userscriptCommands, .extensionButtons])
            FieldPageRows.add(.extensionButtons, in: defaults)
            #expect(FieldPageRows.entries(in: defaults).isEmpty)
            #expect(FieldPageRows.visible(in: defaults).contains(.extensionButtons))
            FieldPageRows.keep(a, on: true, in: defaults)
            FieldPageRows.keep(a, on: true, in: defaults)
            #expect(FieldPageRows.entries(in: defaults) == [a])
            FieldPageRows.keep(a, on: false, in: defaults)
            #expect(FieldPageRows.visible(in: defaults).contains(.extensionButtons))
        }
    }

    @Test func switchesAndOldHiddenInstancesMigrateOnce() {
        settings { defaults in
            for group in ["actions", "extensions", "userscripts", "developer"] {
                defaults.set(false, forKey: "field.page." + group)
            }
            // A kept row used to bypass a disabled group, and still does.
            defaults.set([["id": "page-action:reader", "title": "Reading Mode"]], forKey: FieldPageRows.keptKey)
            defaults.set([["id": "ext:a\u{1F}_execute_action", "title": "Open A"]], forKey: "field.page.hidden")
            #expect(FieldPageRows.hidden(in: defaults) == Set(FieldPageRows.standard.filter { $0 != .reader }))
            #expect(FieldPageRows.choose([candidate(.reader)], in: defaults).kept.map(\.kind) == [.reader])
            FieldPageRows.add(.floatVideo, in: defaults)
            defaults.set(true, forKey: "field.page.actions")
            FieldPageRows.migrate(in: defaults)
            #expect(!FieldPageRows.hidden(in: defaults).contains(.floatVideo))
            #expect(FieldPageRows.hidden(in: defaults).contains(.translatePage))
        }
        settings { defaults in
            defaults.set(true, forKey: "field.page.userscripts")
            #expect(FieldPageRows.hidden(in: defaults).isEmpty)
        }
    }

    @Test(arguments: ["actions", "extensions", "userscripts", "developer"])
    func disabledGroupHidesItsKinds(group: String) {
        settings { defaults in
            defaults.set(true, forKey: "field.page.userscripts")
            defaults.set(false, forKey: "field.page." + group)
            #expect(FieldPageRows.hidden(in: defaults) == Set(FieldPageRows.standard.filter { $0.legacyGroup == group }))
        }
    }

    @Test func syncedListsAreNotOverwrittenByLegacySwitchesAndOrderIsNormalized() {
        settings { defaults in
            defaults.set(false, forKey: "field.page.actions")
            defaults.set(["unknown", "tracking", "tracking"], forKey: FieldPageRows.orderKey)
            defaults.set([String](), forKey: FieldPageRows.hiddenKey)
            let order = FieldPageRows.order(in: defaults)
            #expect(order.first == .tracking)
            #expect(order.count == FieldPageRows.standard.count)
            #expect(Set(order) == Set(FieldPageRows.standard))
            #expect(FieldPageRows.hidden(in: defaults).isEmpty)
        }
    }

    @Test func everyCandidateKindAndToggleHasAMarkAndCategory() {
        #expect(FieldPageRows.kind("page-action:unmuteTab") == .muteTab)
        #expect(FieldPageRows.kind("ext:a\u{1F}_execute_action") == .extensionButtons)
        #expect(FieldPageRows.kind("ext:a\u{1F}_execute_browser_action") == .extensionButtons)
        #expect(FieldPageRows.kind("ext:a\u{1F}command") == .extensionCommands)
        #expect(FieldPageRows.kind("us:a\u{1F}command") == .userscriptCommands)
        for kind in FieldPageRows.standard {
            #expect(FieldPageRows.kind(kind.id) == kind)
            #expect(!kind.title.isEmpty && !kind.symbol.isEmpty && !kind.category.isEmpty)
        }
    }

    @Test func cleanerPreservesPageParametersEncodingAndFragment() {
        let url = URL(string: "https://shop.example.com/a%2Fb?utm_source=x&ref=main&fbclid=y&value=a%2Bb&UTM_source=z#Part%202")!
        #expect(Diary.shareable(url).absoluteString == "https://shop.example.com/a%2Fb?ref=main&value=a%2Bb#Part%202")
        #expect(Diary.sharingParameters(url) == ["utm_source", "fbclid"])
        let encoded = URL(string: "https://example.com/?utm%5Fsource=x&gclid=1")!
        #expect(Diary.shareable(encoded).absoluteString == "https://example.com/")
        #expect(Diary.sharingParameters(encoded) == ["utm_source", "gclid"])
        let clean = URL(string: "https://github.com/a/b?ref=main&source=code&feature=tree#readme")!
        #expect(Diary.shareable(clean) == clean)
        #expect(Diary.sharingParameters(clean).isEmpty)
    }

    @Test func languageOnlyWhenDifferent() {
        #expect(FieldPageRows.language("de-DE", sample: "", preferred: "en-US") == "German")
        #expect(FieldPageRows.language("en-GB", sample: "", preferred: "en-US") == nil)
        #expect(FieldPageRows.language("und", sample: "", preferred: "en") == nil)
        #expect(FieldPageRows.language("", sample: "", preferred: "en") == nil)
    }

    @Test func settingsAreIndexedAndSynced() {
        for key in [FieldPageRows.orderKey, FieldPageRows.hiddenKey, FieldPageRows.keptKey, FieldPageRows.baseKey] {
            #expect(SyncShapes.settingKeys.contains(key))
        }
        for group in ["actions", "extensions", "userscripts", "developer", "hidden"] {
            #expect(!SyncShapes.settingKeys.contains("field.page." + group))
        }
        for id in ["page-kept"] {
            #expect(SettingsItem.all.contains { $0.id == id && $0.page == .search })
        }
    }

    private func world(_ check: (Browser, Tab, UserDefaults) throws -> Void) rethrows {
        try settings { defaults in
            _ = NSApplication.shared
            let browser = Browser(windowID: UUID()), tab = Tab(bench: true)
            tab.restore(url: URL(string: "https://page.example.com/article?utm_source=x&fbclid=y")!, title: "Article")
            browser.lay([tab]); browser.activeID = tab.id
            browser.pageRowSettings = defaults
            browser.history = History([])
            let commands = FieldUnder.shared.commands, menus = browser.prefs.menuCommands
            let suggest = browser.prefs.searchSuggest, requests = browser.prefs.fieldRequests
            FieldUnder.shared.commands = true
            browser.prefs.searchSuggest = false; browser.prefs.fieldRequests = false
            defer {
                FieldUnder.shared.commands = commands; browser.prefs.menuCommands = menus
                browser.prefs.searchSuggest = suggest; browser.prefs.fieldRequests = requests
                browser.dismiss(); browser.letGo()
                browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            }
            try check(browser, tab, defaults)
        }
    }

    @Test func baseRowsAndContextHeadingAndCleanAddress() {
        world { browser, tab, _ in
            browser.query.here = tab.address; browser.editing = true
            browser.replaceTyped(Address.whole(tab.address!))
            let rows = browser.quietRows()
            let base = rows.filter { browser.quietSection($0) == "This Page" && $0.kind != .page("agent") }
            #expect(base.map(\.key) == ["Copy URL", "Copy Markdown Link", "Duplicate Tab"])
            #expect(base.first?.title == "page.example.com/article")
            let tracking = rows.first { $0.kind == .page("tracking") }
            #expect(tracking?.title == "utm_source, fbclid")
            #expect(tracking.flatMap { browser.quietSection($0) } == "On page.example.com")
        }
    }

    @Test func browserUsesSavedPriorityAndKeptOrder() {
        world { browser, tab, defaults in
            tab.fieldPageFacts = FieldPageFacts(address: tab.address, video: true, language: "German")
            FieldPageRows.move(.tracking, before: .floatVideo, in: defaults)
            #expect(browser.pageRows(on: tab).map(\.key).prefix(3) == ["Copy URL with Tracking", "Float Video", "Translate Page"])
            FieldPageRows.keep(.init(id: FieldPageRows.Kind.translatePage.id, title: "Translate Page"), on: true, in: defaults)
            FieldPageRows.keep(.init(id: FieldPageRows.Kind.floatVideo.id, title: "Float Video"), on: true, in: defaults)
            #expect(browser.pageRows(on: tab).filter { $0.pageHeading == "This Page" }.map(\.key) == ["Translate Page", "Float Video"])
            FieldPageRows.moveKept(FieldPageRows.Kind.floatVideo.id, before: FieldPageRows.Kind.translatePage.id, in: defaults)
            #expect(browser.pageRows(on: tab).filter { $0.pageHeading == "This Page" }.map(\.key) == ["Float Video", "Translate Page"])
        }
    }

    @Test func keepHideAndRemoveUseTheSameShortcutAsFavorites() throws {
        try world { browser, tab, defaults in
            browser.query.here = tab.address; browser.editing = true
            browser.replaceTyped(Address.whole(tab.address!))
            let tracking = try #require(browser.offers.first { $0.kind == .page("tracking") })
            let actions = browser.pageRowActions(tracking, [])
            let keep = try #require(actions.first { $0.id == "favorite" })
            #expect(keep.title == "Keep in This Page")
            #expect(keep.keys == Keymap.shared.text(.fieldFavorite))
            keep.run()
            let kept = try #require(browser.offers.first { $0.kind == .page("tracking") })
            #expect(browser.quietSection(kept) == "This Page")
            #expect(browser.offers.firstIndex(of: kept)! > browser.offers.firstIndex { $0.kind == .page("duplicate") }!)
            #expect(browser.pageRowActions(kept, []).first?.title == "Remove from This Page")
            try #require(browser.pageRowActions(kept, []).first { $0.id == "favorite" }).run()
            #expect(FieldPageRows.entries(in: defaults).isEmpty)
            #expect(FieldPageRows.visible(in: defaults).contains(.tracking))
            keep.run()
            try #require(browser.pageRowActions(kept, []).first { $0.id == "hide-page-row" }).run()
            #expect(!browser.offers.contains { $0.kind == .page("tracking") })
            #expect(FieldPageRows.entries(in: defaults).isEmpty)
        }
    }

    @Test func liveFactsAndMutePairKeepTheirContext() {
        world { browser, tab, defaults in
            let mute = FieldPageRows.Entry(id: "page-action:muteTab", title: "Mute Tab")
            FieldPageRows.keep(mute, on: true, in: defaults)
            tab.noisy = true
            if AudioWatch.canMute {
                #expect(browser.pageRows(on: tab).contains { $0.key == "Mute Tab" && $0.pageHeading == "This Page" && $0.title == "playing" })
                tab.mute(true)
                #expect(browser.pageRows(on: tab).contains { $0.key == "Unmute Tab" && $0.pageHeading == "This Page" })
                FieldPageRows.hide(.muteTab, in: defaults)
                #expect(!browser.pageRows(on: tab).contains { $0.key == "Unmute Tab" })
            }
            tab.fieldPageFacts = FieldPageFacts(address: tab.address, video: true, language: "German")
            #expect(browser.pageRows(on: tab).contains { $0.key == "Float Video" })
            #expect(browser.pageRows(on: tab).contains { $0.key == "Translate Page" && $0.title == "from German" })
            tab.fieldPageFacts.address = URL(string: "https://previous.example.com/")!
            #expect(!browser.pageRows(on: tab).contains { $0.key == "Float Video" || $0.key == "Translate Page" })
        }
    }

    @Test func hiddenActionsStillLeadComposedHistoryAndSuggestionsAndAppearInActions() {
        world { browser, tab, defaults in
            for kind: FieldPageRows.Kind in [.tracking, .floatVideo, .translatePage] { FieldPageRows.hide(kind, in: defaults) }
            tab.fieldPageFacts = FieldPageFacts(address: tab.address, video: true, language: "German")
            for menus in [false, true] {
                browser.prefs.menuCommands = menus
                for title in ["Copy URL with Tracking", "Float Video", "Translate Page"] {
                    let url = URL(string: "https://history.example.com/" + title.replacingOccurrences(of: " ", with: "-"))!
                    browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url), title: title, count: 200, last: Date(), typed: 100)])
                    browser.query.actionsPage = false; browser.replaceTyped(title)
                    #expect(browser.offers.first?.key == title)
                    let web = [Suggestion(key: title + " web", title: "", url: nil, kind: .suggested)]
                    #expect(SearchSuggestions.merge(web, into: browser.offers, lead: browser.query.lead).list.first?.key == title)
                    browser.query.actionsPage = true; browser.replaceTyped(title)
                    #expect(browser.offers.contains { $0.key == title })
                }
            }
        }
    }
}
