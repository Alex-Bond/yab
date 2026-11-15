import SwiftUI
import Foundation

/// Going back (the back stack's prototype, 2026-10-08): a tab a link
/// opened, pulled from the left edge at its first page with its opener as a
/// card under it, and closed with Undo; a page with nothing behind it, its ‹
/// dimmed and the page against the rubber band; a tab closed on the spaces
/// with Undo. WebKit's own swipe (scene 1) has no state: it can't be held.
/// Lisbon's Wikipedia opens The best things to do in Lisbon, as Google
/// opened the hurricane's advisory in the prototype.
extension StateCatalog {
    static let back: [NamedState] = [
        NamedState("back.firstpage", "Tab's first page",
                   "Back to the tab that opened it: that tab is a card under the page, the page slides off to the right.") { app in
            guard await openedByLink(app) else { return }
            app.backStack.hold(at: app.backStack.width * 0.45)
        },
        NamedState("back.closed", "Tab closed",
                   "Let go: the parent tab is in front, “Closed timeout.com · Undo” at the bottom.") { app in
            guard await openedByLink(app) else { return }
            app.backStack.backToOpener()
        },
        NamedState("back.nothing", "Nowhere to go back", "The page gives with resistance, ‹ is dimmed.") { app in
            // The prototype's finger 170 in: the page 76 along.
            guard await front(app, "lisbon-wiki") != nil else { return }
            app.backStack.hold(at: 170)
        },
        NamedState("back.dim", "‹ dimmed", "First page, no tab opened this one: no going back.") { app in
            _ = await front(app, "lisbon-wiki")
        },
        NamedState("back.spaces", "Closed from spaces", "Spaces up from the plate, the tab closed: a toast with Undo at the top.") { app in
            app.field.openSpaces()
            try? await Task.sleep(for: .milliseconds(300))
            ColumnState.of(app).close("work-hn")
        },
    ]

    /// A tab in front, its page drawn.
    @MainActor
    private static func front(_ app: AppModel, _ id: Tab.ID) async -> Tab? {
        app.browser.select(id)
        guard let tab = app.browser.tab, tab.id == id else { return nil }
        app.pages.activate(tab)
        await app.pages.waitUntilPainted(tab.id, timeout: .seconds(12))
        return tab
    }

    /// Lisbon's Wikipedia drawn, then a link of it opening Time Out in a tab
    /// of its own, as a page's target=_blank does (WebPool.onOpenWindowFrom).
    @MainActor
    private static func openedByLink(_ app: AppModel) async -> Bool {
        guard let opener = await front(app, "lisbon-wiki"), let url = URL(string: "https://timeout.com") else { return false }
        let tab = PageFixtures.tab(for: url, in: app.world)
        app.browser.open(tab, in: "lisbon", deduplicate: false)
        app.backStack.opened(tab.id, by: opener.id)
        guard let shown = app.browser.tab, shown.id == tab.id else { return false }
        app.pages.activate(shown)
        await app.pages.waitUntilPainted(shown.id, timeout: .seconds(12))
        return true
    }
}
