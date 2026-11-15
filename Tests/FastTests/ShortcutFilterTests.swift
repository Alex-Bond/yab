import Testing
import AppKit
@testable import Fast

@MainActor
struct ShortcutFilterTests {
    @Test func clearRestoresBothFiltersAndTheQuery() {
        let selection = ShortcutFilter.Selection()
        selection.search = "tab"
        selection.modifications = [.changed]
        selection.chosen = ["Tabs"]
        selection.categories = ["Tabs", "Mail"]
        selection.clear()
        #expect(selection.search.isEmpty && selection.modifications.isEmpty && selection.chosen.isEmpty)
        #expect(selection.categories == ["Tabs", "Mail"])
    }

    @Test func openingShortcutsAgainRevealsRowsHiddenByOldFilters() {
        let model = SettingsModel()
        model.go(.shortcuts)
        model.shortcutFilters.search = "capture"
        model.shortcutFilters.modifications = [.disabled]
        model.shortcutFilters.chosen = ["Screenshot"]
        model.go(.shortcuts)
        #expect(model.shortcutFilters.search.isEmpty)
        #expect(model.shortcutFilters.modifications.isEmpty && model.shortcutFilters.chosen.isEmpty)
    }

    @Test func searchCombinesWordsAliasesCategoriesAndPhysicalKeys() {
        let entries = [ShortcutFilter.Entry(id: "capture", category: "Screenshot", name: "Capture area", alias: "snap",
                                           keys: [Hotkey("s", [.control, .option, .shift, .command])], caps: [["⌃", "⌥", "⇧", "⌘", "S"]], enabled: false)]
        for text in [" SNAP ", "area capture", "snap screenshot", "ctrl cmd", "⌃⌘", "ctrl opt shift cmd s"] {
            #expect(ShortcutFilter.visible(entries, search: text).map(\.id) == ["capture"])
        }
        #expect(ShortcutFilter.visible(entries, search: "cmd s").isEmpty)
        #expect(ShortcutFilter.visible(entries, search: "", modifications: [.alias]).map(\.id) == ["capture"])
        #expect(ShortcutFilter.visible(entries, search: "snap", modifications: [.disabled], categories: ["Screenshot"]).map(\.id) == ["capture"])
        #expect(ShortcutFilter.visible(entries, search: "", modifications: [.enabled]).isEmpty)
        #expect(!entries[0].enabled)
    }

    @Test func unmodifiedKeysRemainSearchable() {
        let entries = [
            ShortcutFilter.Entry(id: "escape", category: "Page", name: "Dismiss", caps: [["esc"]]),
            ShortcutFilter.Entry(id: "function", category: "Page", name: "Inspector", caps: [["F12"]]),
            ShortcutFilter.Entry(id: "space", category: "Mail", name: "Quick Look", caps: [["Space"]]),
        ]
        for (query, id) in [("esc", "escape"), ("F12", "function"), ("space", "space")] {
            #expect(ShortcutFilter.visible(entries, search: query).map(\.id) == [id])
        }
    }

    @Test func categoryAndModificationIntersectAndClearIndependently() {
        let entries = [
            ShortcutFilter.Entry(id: "tabs", category: "Tabs", name: "Duplicate", changed: true),
            ShortcutFilter.Entry(id: "mail", category: "Mail", name: "Reply", keys: [Hotkey("r", .command)], caps: [["⌘", "R"]]),
        ]
        #expect(ShortcutFilter.visible(entries, search: "", modifications: [.changed], categories: ["Tabs"]).map(\.id) == ["tabs"])
        #expect(ShortcutFilter.visible(entries, search: "", modifications: [.set], categories: ["Tabs"]).isEmpty)
        #expect(ShortcutFilter.visible(entries, search: "", categories: ["Mail"]).map(\.id) == ["mail"])
        #expect(ShortcutFilter.visible(entries, search: "").count == 2)
        #expect(ShortcutFilter.categories(Array(entries.reversed())) == ["Tabs", "Mail"])
    }

    @Test func choicesInOneFilterWidenAndTheTwoFiltersNarrow() {
        let entries = [
            ShortcutFilter.Entry(id: "tabs", category: "Tabs", name: "Duplicate", changed: true),
            ShortcutFilter.Entry(id: "mail", category: "Mail", name: "Reply", keys: [Hotkey("r", .command)], caps: [["⌘", "R"]]),
            ShortcutFilter.Entry(id: "page", category: "Page", name: "Print", alias: "print"),
        ]
        #expect(ShortcutFilter.visible(entries, search: "", categories: ["Tabs", "Mail"]).map(\.id) == ["tabs", "mail"])
        #expect(ShortcutFilter.visible(entries, search: "", modifications: [.changed, .alias]).map(\.id) == ["tabs", "page"])
        #expect(ShortcutFilter.visible(entries, search: "", modifications: [.changed, .set], categories: ["Mail"]).map(\.id) == ["mail"])
        let counts = ShortcutFilter.counts(entries)
        #expect(counts.categories == ["Tabs": 1, "Mail": 1, "Page": 1])
        #expect(counts.modifications[.set] == 1 && counts.modifications[.enabled] == 3 && counts.modifications[.conflict] == 0)
    }

    @Test func conflictsUseFullInventoryAndIgnoreDisabledCommandsAndIntentionalReuse() {
        let key = Hotkey("r", .command)
        let entries = [
            ShortcutFilter.Entry(id: "reload", category: "Tabs", name: "Reload", keys: [key], action: .reload),
            ShortcutFilter.Entry(id: "extension", category: "Extension", name: "Capture", keys: [key]),
            ShortcutFilter.Entry(id: "off", category: "Extension", name: "Disabled", keys: [key], enabled: false),
        ]
        #expect(ShortcutFilter.visible(entries, search: "reload", modifications: [.conflict], categories: ["Tabs"]).map(\.id) == ["reload"])
        #expect(ShortcutFilter.conflicts(entries) == ["reload", "extension"])
        let defaults = [
            ShortcutFilter.Entry(id: "reload", category: "Tabs", name: "Reload", keys: [key], action: .reload),
            ShortcutFilter.Entry(id: "rewrite", category: "Agent", name: "Rewrite", keys: [key], action: .answerRewrite),
        ]
        #expect(ShortcutFilter.conflicts(defaults).isEmpty)
    }
}
