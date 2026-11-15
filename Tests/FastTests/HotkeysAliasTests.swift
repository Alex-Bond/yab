import Testing
@testable import Fast

struct HotkeysAliasTests {
    @Test @MainActor func alternateMenuTitlesUseTheSameAction() {
        let raw = [
            "Show Sidebar": "@k",
            "Back to Your Tabs": "@$i",
            "Unpin Tab": "@$d",
            "Show History": "@y",
            "Show Downloads": "@$j",
        ]
        let keys = Hotkeys.normalizedUserKeys(raw, visibleTitles: [
            .column: "Show Sidebar", .mail: "Back to Your Tabs", .pin: "Unpin Tab",
        ])
        #expect(keys["Hide Sidebar"] == "@k")
        #expect(keys["Mail"] == "@$i")
        #expect(keys["Pin Tab"] == "@$d")
        #expect(keys["Search History"] == "@y")
        #expect(keys["Search Downloads"] == "@$j")
    }

    @Test @MainActor func visibleMenuTitleWinsWhenBothVariantsAreAssigned() {
        let raw = ["Hide Sidebar": "@s", "Show Sidebar": "@k",
                   "Pin Tab": "@$d", "Pin 2 Tabs": "@$p"]
        let keys = Hotkeys.normalizedUserKeys(raw, visibleTitles: [
            .column: "Show Sidebar", .pin: "Pin 2 Tabs",
        ])
        #expect(keys["Hide Sidebar"] == "@k")
        #expect(keys["Pin Tab"] == "@$p")
        let search = Hotkeys.normalizedUserKeys(["Search History": "@h", "Show History": "@y"], visibleTitles: [:])
        #expect(search["Search History"] == "@h")
    }

    @Test @MainActor func changingMenuTitlesImportToTheSameShortcut() {
        let raw = [
            "Separate Split View": "@s",
            "Change Letter": "@r",
            "Close 2 Tabs": "@w",
            "Duplicate 2 Tabs": "@d",
            "Copy 2 URLs": "@c",
            "Copy 2 Markdown Links": "@m",
            "Add 2 Tabs to a Folder": "@b",
        ]
        let visible: [Shortcut.Action: String] = [
            .split: "Separate Split View", .rename: "Change Letter", .closeTab: "Close 2 Tabs",
            .duplicate: "Duplicate 2 Tabs", .copyAddress: "Copy 2 URLs",
            .copyMarkdownLink: "Copy 2 Markdown Links", .bookmark: "Add 2 Tabs to a Folder",
        ]
        let keys = Hotkeys.normalizedUserKeys(raw, visibleTitles: visible)
        #expect(keys["Split View"] == "@s")
        #expect(keys["Rename Tab…"] == "@r")
        #expect(keys["Close Tab"] == "@w")
        #expect(keys["Duplicate Tab"] == "@d")
        #expect(keys["Copy URL"] == "@c")
        #expect(keys["Copy Markdown Link"] == "@m")
        #expect(keys["Add This Page"] == "@b")
        for (action, title) in visible {
            #expect(Hotkeys.action(forTitle: title) == action)
        }
    }
}
