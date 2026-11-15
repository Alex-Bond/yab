import Foundation
import Testing
import YabCoreClient
@testable import Fast

/// Gap 8 of RESULT-extensions-parity.md: an extension's panel follows the
/// tab in front as Google Chrome's does (panel_parity_chrome.py on Chrome
/// 157, docs/evidence/ext-sidepanel-parity/chrome/chrome.json).
struct ChromiumSidePanelSwitchTests {
    private let id = "ennhhnlidajopkaghklalaedfmmmgega"

    private func options(tab: String = "", global: String = "") -> ChromiumSidePanel.Options {
        var value = ChromiumSidePanel.Options(path: tab.isEmpty ? global : tab, enabled: true, openOnClick: true)
        value.tabPath = tab
        value.globalPath = global
        return value
    }

    @Test func aTabWithoutItsOwnShowsTheWindowsPanel() {
        // "global: to B (no options of its own)" and "to C (its own options off)": global.html.
        #expect(ChromiumSidePanel.switched(showing: true, leftOpen: nil, options: options(global: "global.html")) == .window("global.html"))
    }

    @Test func aTabsOwnPanelWinsOverTheWindows() {
        #expect(ChromiumSidePanel.switched(showing: true, leftOpen: nil, options: options(tab: "a.html", global: "global.html")) == .tab("a.html"))
    }

    @Test func aTabsOwnPanelLeftOpenComesBackWithIt() {
        // "global: back to A" (a.html, the same document) and "tab only: back to D" (b.html).
        #expect(ChromiumSidePanel.switched(showing: true, leftOpen: "ctx", options: nil) == .leftOpen("ctx"))
        // Back to D from F, where the column had closed.
        #expect(ChromiumSidePanel.switched(showing: false, leftOpen: "ctx", options: nil) == .leftOpen("ctx"))
    }

    @Test func withoutTheWindowsPanelTheColumnCloses() {
        // "tab only: to F (no panel anywhere)".
        #expect(ChromiumSidePanel.switched(showing: true, leftOpen: nil, options: options()) == .close)
        // "tab only: to E (its own panel, never shown there)": Chrome closes too.
        #expect(ChromiumSidePanel.switched(showing: true, leftOpen: nil, options: options(tab: "a.html")) == .close)
        // Unreadable options: nothing to show.
        #expect(ChromiumSidePanel.switched(showing: true, leftOpen: nil, options: nil) == .close)
    }

    @Test func nothingShowingStaysSo() {
        #expect(ChromiumSidePanel.switched(showing: false, leftOpen: nil, options: options(tab: "a.html", global: "g.html")) == .keep)
    }

    @Test func readsTheOptionsChangedEvent() throws {
        let tab = try #require(ChromiumSidePanel.changed(["extensionId": .string(id), "tabId": .number(42),
                                                          "path": .string("a2.html"), "enabled": .bool(true)]))
        #expect(tab.extensionID == id && tab.tab == 42 && tab.path == "a2.html" && tab.enabled == true)
        let window = try #require(ChromiumSidePanel.changed(["extensionId": .string(id), "tabId": .number(-1), "enabled": .bool(false)]))
        #expect(window.tab == nil && window.path == nil && window.enabled == false)
        #expect(ChromiumSidePanel.changed(["extensionId": .string("nope")]) == nil)
    }

    @Test func panelPagesAreTheExtensionsOwn() {
        #expect(ChromiumSidePanel.url(id, "/a.html")?.absoluteString == "chrome-extension://\(id)/a.html")
        #expect(ChromiumSidePanel.url(id, "") == nil)
    }

    @Test func theScriptAsksForTheTabsOwnAndTheGlobalOptions() {
        let script = ChromiumSidePanel.optionsScript(tabID: 7)
        #expect(script.contains("const tabId = 7;"))
        #expect(script.contains("o.tabId === tabId"))
        #expect(ChromiumSidePanel.optionsScript(tabID: nil).contains("const tabId = null;"))
    }
}
