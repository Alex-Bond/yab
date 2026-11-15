import Foundation
import Testing
@testable import Fast

/// Tidy on the kept line (TidyTabs.swift, feedback #313): the model's
/// answer read, today's tabs put in folders of today's by it, and ⌘Z
/// putting the row back as it was.
@MainActor
@Suite(.serialized)
struct TidyTabsTests {
    /// Uses only the existing public behavior on both the committed parent
    /// and candidate. A saved setting must affect a fresh Browser's actual
    /// eligibility, without calling the new Preferences property in tests.
    @Test func groupingChoiceControlsActualEligibilityAfterReload() throws {
        try #require(Store.testing)
        let old = Store.settings.object(forKey: "tidy.tabs")
        let answer = TidyTabs.benchAnswer
        defer {
            Store.settings.set(old, forKey: "tidy.tabs")
            TidyTabs.benchAnswer = answer
        }
        TidyTabs.benchAnswer = "{}"
        let choices: [Bool?] = [nil, false, true, false]
        for choice in choices {
            if let choice { Store.settings.set(choice, forKey: "tidy.tabs") }
            else { Store.settings.removeObject(forKey: "tidy.tabs") }
            let id = UUID(), browser = Browser(windowID: id)
            let tabs = (0..<5).map { index in
                let tab = Tab()
                tab.restore(url: URL(string: "https://tidy-settings.test/\(index)")!, title: "Page \(index)")
                browser.prepare(tab)
                return tab
            }
            defer {
                browser.dozing?.invalidate()
                browser.stuck.timer?.invalidate()
                browser.pressure?.cancel()
                for tab in tabs { tab.close() }
                browser.lay([])
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
            #expect(Browser.tidyTabsFrom == 5)
            browser.lay(Array(tabs.prefix(4)))
            #expect(!browser.canTidyTabs)
            browser.lay(tabs)
            try #require(browser.tidyTabsLoose.count == 5)
            try #require(TidyTabs.can)
            let enabled = choice ?? true
            #expect(browser.canTidyTabs == enabled, "saved grouping choice must control actual five-tab eligibility")
            // Never dispatch on the baseline's unsupported disabled choice.
            // The candidate's actual disabled entry must remain a no-op.
            if !browser.canTidyTabs {
                browser.tidyTabs()
                #expect(!browser.tabsTidying)
                #expect(browser.tabs.allSatisfy { $0.nest == nil })
            }
            print("TIDY_CHOICE saved=\(String(describing: choice)) enabled=\(browser.canTidyTabs) fourTab=false provider=true")
        }
    }

    @Test func groupingSwitchCanBeFoundInSettingsSearch() {
        let results = SettingsResult.search("Tidy tabs")
        #expect(results.rows.contains { result in
            guard case .item(let item) = result else { return false }
            return item.id == "tidy-tabs" && item.page == .whileYouBrowse
        }, "grouping switch must be discoverable independently of title shortening")
    }

    @Test func groupingChoiceIsCountedInWhileYouBrowseSummary() {
        let keys = ["tidy.tabs", "tidy.titles", "folders.names", "tidy.downloads", "field.instant", "links.preview"]
        let old = keys.map { Store.settings.object(forKey: $0) }
        let titlesEnabled = ShortNames.enabled
        defer {
            for (key, value) in zip(keys, old) { Store.settings.set(value, forKey: key) }
            ShortNames.enabled = titlesEnabled
        }
        for key in keys { Store.settings.set(false, forKey: key) }
        #expect(WhileYouBrowsePage.summary(Preferences()) == "Off")
        Store.settings.set(true, forKey: "tidy.tabs")
        #expect(WhileYouBrowsePage.summary(Preferences()) == "1 of 6 on", "grouping choice must be counted separately from titles")
    }

    @Test func theAnswerIsReadStrictly() {
        let said = """
        Here you go: {"groups":[{"name":"Travel Planning","tabs":[1,2,3]},{"name":"Baking","tabs":["4",5,5,9]},
        {"name":"A sentence that is far too long to be a folder name.","tabs":[6,7]},{"name":"Solo","tabs":[6]},
        {"name":"Again","tabs":[1,8]}]}
        """
        let groups = TidyTabs.answer(said, count: 8)
        #expect(groups == [
            TidyTabs.Group(name: "Travel Planning", tabs: [0, 1, 2]),
            TidyTabs.Group(name: "Baking", tabs: [3, 4]),
        ])
        #expect(TidyTabs.answer("no idea", count: 8) == nil)
        #expect(TidyTabs.answer(#"{"groups":[]}"#, count: 8) == nil)
        #expect(TidyTabs.answer(#"{"groups":[{"name":"News","tabs":[0,1]}]}"#, count: 3, from: 0) == [TidyTabs.Group(name: "News", tabs: [0, 1])])
    }

    @Test func tidyLeavesOutTabsFromAnotherSpace() throws {
        let id = UUID()
        let browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs { browser.close(tab) }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let opened = (0..<3).map { browser.open(URL(string: "https://example.test/\($0)")!, foreground: false) }
        browser.lay(opened)
        opened[2].homeSpace = UUID()
        #expect(browser.tidyTabsLoose.map(\.id) == opened.prefix(2).map(\.id))
    }

    @Test func tidyRechecksVisitingTabsWhenTheAnswerArrives() throws {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs { browser.close(tab) }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let tabs = (0..<3).map { browser.open(URL(string: "https://example.test/late-tidy/\($0)")!, foreground: false) }
        browser.lay(tabs)
        let asked = browser.tidyTabsLoose
        try #require(asked.count == 3)
        // The model was asked before the tab became a visitor. Its answer
        // must not file a tab whose folder belongs to another space.
        tabs[1].homeSpace = UUID()
        browser.applyTidy([TidyTabs.Group(name: "Topic", tabs: [0, 1, 2])], of: asked)
        #expect(tabs[1].nest == nil)
        #expect(tabs[0].nest != nil)
        #expect(tabs[0].nest === tabs[2].nest)
        browser.folderBook.refresh()
        #expect(tabs[0].nest === tabs[2].nest)
    }

    @Test func tidyMakesFoldersOfTodaysAndUndoPutsTheRowBack() throws {
        let id = UUID()
        let browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs { browser.close(tab) }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let names = ["news1", "docs1", "shop1", "news2", "docs2", "news3", "shop2", "docs3"]
        let opened = names.map { browser.open(URL(string: "https://example.test/\($0)")!, foreground: false) }
        browser.lay(opened)
        let before = browser.tabs.map(\.id)
        let loose = browser.tidyTabsLoose
        #expect(loose.count == 8)
        let index = { (name: String) in loose.firstIndex { $0.address?.lastPathComponent == name }! }
        browser.applyTidy([
            TidyTabs.Group(name: "News", tabs: ["news1", "news2", "news3"].map(index)),
            TidyTabs.Group(name: "Docs", tabs: ["docs1", "docs2", "docs3"].map(index)),
            TidyTabs.Group(name: "Shopping", tabs: ["shop1", "shop2"].map(index)),
        ], of: loose)
        let folder = { (tab: Tab) in tab.nest?.name }
        #expect(browser.tabs.map(folder) == ["News", "News", "News", "Docs", "Docs", "Docs", "Shopping", "Shopping"])
        #expect(browser.tabs.allSatisfy { $0.nest?.today == true && !$0.kept })
        #expect(browser.canUndoWindow)
        #expect(browser.undoWindow())
        #expect(browser.tabs.map(\.id) == before)
        #expect(browser.tabs.allSatisfy { $0.nest == nil })
        #expect(browser.nests.isEmpty)
    }
}
