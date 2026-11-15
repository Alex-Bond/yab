import Foundation

/// The tab stack's named states (the back-stack prototype, scenes 5 to 8):
/// the right button with two, one and no other tabs and in Private, the
/// flick held, the held menu, and All Tabs. Each starts from the atlas's
/// start (Work, Onboarding v3 in Figma) and first has the tabs it shows in
/// front once, as a person's use would, so the pool has their pictures.
extension StateCatalog {
    static let tabs: [NamedState] = [
        NamedState("stack.private-last", "Last private tab", "An empty ordinary profile with one private page to close.") { app in
            SettingsStore.shared.welcomed = true
            app.surfaces.closeField()
            app.openPrivately(PageFixtures.search("Last private page", id: "private-last-close"))
            await paint(app)
        },
        NamedState("stack.1", "Stack: two more", "On the right, in a glass circle, two earlier tabs with a faint rim inside the edge: GitHub in front, tilted 8°, HN behind it, tilted -12°.") { app in
            await visit(app, ["work-hn", "work-gh-pr"])
        },
        NamedState("stack.2", "Stack: one more", "One earlier tab: one card in the circle.") { app in
            // Lisbon with one of today's closed: Flights in front, the Lisbon article before it.
            app.browser.showSpace("lisbon")
            app.browser.close("lisbon-alfama-wiki")
            await visit(app, ["lisbon-wiki"])
        },
        NamedState("stack.3", "Only this one", "No other tabs: a + in the circle.") { app in
            app.browser.showSpace("lisbon")
            app.browser.close("lisbon-wiki")
            app.browser.close("lisbon-alfama-wiki")
            await visit(app, [])
        },
        NamedState("zero.1", "Empty page", "The last of today's closed in a space with pins and kept: no pin in front, + New Tab on the plate, the space's emoji on the right, no back.") { app in
            await closeToday(app, leaving: nil)
        },
        NamedState("zero.pin", "Launch on a pin", "Today empty, a pin left in front: Yab comes up on the empty screen with the sheet.") { app in
            await closeToday(app, leaving: nil)
            if let pin = app.browser.space.visiblePins.first { app.browser.select(pin.id) }
            FieldModel.sheetInTests = true
            app.openLaunchField()
        },
        NamedState("zero.keptLone", "A kept tab alone", "Today empty, one kept tab open: its card closed, search comes up.") { app in
            await closeToday(app, leaving: nil)
            if let kept = app.browser.space.keptTabs.first { app.browser.select(kept.id) }
        },
        NamedState("zero.lone", "One today's tab", "Pins and kept around it, one today's tab in front: + in the circle.") { app in
            await closeToday(app, leaving: "work-hn")
        },
        NamedState("zero.lone.menu", "One today's tab, held", "New Tab, New Private Tab, New Chat, All Tabs · 1.") { app in
            await closeToday(app, leaving: "work-hn")
            try? await Task.sleep(for: .milliseconds(400))
            #if DEBUG
            TabStack.of(app).control?.presentMenuForTests()
            #endif
            try? await Task.sleep(for: .milliseconds(600))
        },
        NamedState("zero.lone.gallery", "One card", "All Tabs with the one card to close.") { app in
            await closeToday(app, leaving: "work-hn")
            await showAllTabs(app)
        },
        NamedState("zero.swiped", "Last card closed", "The empty page under where All Tabs was, Closed Hacker News with Undo.") { app in
            await closeToday(app, leaving: "work-hn")
            await showAllTabs(app)
            TabStack.of(app).closeCard("work-hn")
            try? await Task.sleep(for: .milliseconds(900))
        },
        NamedState("zero.undone", "Undo", "Undo: Hacker News back in front, + in the circle.") { app in
            await closeToday(app, leaving: "work-hn")
            await showAllTabs(app)
            TabStack.of(app).closeCard("work-hn")
            try? await Task.sleep(for: .milliseconds(900))
            if let toast = app.surfaces.toast { app.surfaces.undoToast(toast.id) }
            await paint(app)
        },
        NamedState("zero.plate", "Plate tapped", "A tap on + New Tab: New Tab's field, the pins waiting in it.") { app in
            await closeToday(app, leaving: nil)
            app.openNewTab()
            try? await Task.sleep(for: .milliseconds(900))
        },
        NamedState("zero.first", "First run", "After the welcome, in the empty world: no tabs, New Tab's field and the keyboard.") { app in
            SettingsUI.shared.welcomeForced = false
            SettingsStore.shared.welcomed = true
            app.openLaunchField()
            app.field.ask()
            try? await Task.sleep(for: .milliseconds(900))
        },
        NamedState("zero.fromMac", "A Mac opens a tab", "A tab reaches today while the page is empty: the page stays, the tab waits in the stack as one card.") { app in
            await closeToday(app, leaving: nil)
            let tab = Tab(id: "zero-mac", title: "From the Mac", site: "Example", icon: "example", url: "example.com/mac")
            app.browser.adopt(app.browser.spaces.map { space in
                guard space.id == app.browser.spaceID else { return space }
                var next = space
                next.today = [tab]
                next.placeTabs()
                next.current = SyncMapping.current(in: next, old: space)
                return next
            })
            try? await Task.sleep(for: .milliseconds(400))
        },
        NamedState("stack.4", "Private", "A stack of private tabs in a dark circle.") { app in
            await openPrivately(app, ["work-hn", "work-gh-pr", "work-lumen"])
        },
        NamedState("stack.5", "Swipe up", "The front card rose with the finger and grew a little.") { app in
            await visit(app, ["work-hn", "work-gh-pr"])
            let stack = TabStack.of(app)
            stack.flickBegan()
            stack.flickMoved(48)
        },
        NamedState("stack.6", "Tab growing", "Let go: GitHub grows from the card over Figma, Figma dims.") { app in
            await visit(app, ["work-hn", "work-gh-pr"])
            TabStack.of(app).holdFlick(at: 0.45)
        },
        NamedState("stack.many", "Stack: many tabs", "Figma in front; GitHub, HN, Lumen and Linear were open before it, each with a snapshot (for shooting All Tabs).") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
        },
        NamedState("stack.menu", "Stack menu", "New Tab, New Private Tab · two recent · All Tabs · 6.") { app in
            await visit(app, ["work-hn", "work-gh-pr"])
            try? await Task.sleep(for: .milliseconds(400))
            #if DEBUG
            TabStack.of(app).control?.presentMenuForTests()
            #endif
            try? await Task.sleep(for: .milliseconds(600))
        },
        NamedState("duo.stack.wide", "All tabs on its side", "Turned: the phone's row.") { app in
            FieldModel.sheetInTests = true
            await StateCatalog.turn(.landscapeLeft)
            try? await Task.sleep(for: .milliseconds(800))
            TabStack.of(app).openGallery()
            try? await Task.sleep(for: .milliseconds(1500))
        },
        NamedState("duo.stack.tall", "All tabs upright", "The phone's row.") { app in
            FieldModel.sheetInTests = true
            TabStack.of(app).openGallery()
            try? await Task.sleep(for: .milliseconds(1500))
        },
        NamedState("stack.gallery", "All tabs", "The previous one (GitHub) in focus with its title, the current one on the right on top, older ones on the left under a veil; + in a capsule.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
        },
        NamedState("stack.gallery.look", "All tabs in color", "The gallery background in the color picked on Color (preset 72F2E6), not a pale wash.") { app in
            if var look = SpaceLook(.object(["swatch": "custom", "color": "#72F2E6", "colors": .array(["#69E7B9", "#8C95E0"]), "grain": true, "grainAmount": 0.6])) {
                look.setDrawings("")
                app.browser.setSpace(app.browser.spaceID, look: look)
            }
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
        },
        NamedState("stack.gallery.2", "Scrolling through", "The gallery moved two cards: HN in focus, older ones closer.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            let stack = TabStack.of(app)
            if let focus = stack.gallery?.focus { stack.scrollGallery(to: focus - 2) }
        },
        NamedState("stack.open.1", "Opening, 0.05 s", "The page shrinks to the right, GitHub grows from the front card in the circle, the circle fades.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).holdOpening(at: 0.05)
        },
        NamedState("stack.open.2", "Opening, 0.1 s", "The cards halfway, the tilt almost gone, the captions fading in.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).holdOpening(at: 0.1)
        },
        NamedState("stack.open.3", "Opening, 0.15 s", "Almost in place; older ones come out on the left from behind HN.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).holdOpening(at: 0.15)
        },
        NamedState("stack.close.1", "Closing, 0.1 s", "A tap on the current (top) one: Figma grows into the page, nothing flies into the circle, the circle with GitHub and HN rises from below.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).choose("work-figma-onb", heldAt: 0.1)
        },
        NamedState("stack.close.2", "Closing to the previous, 0.1 s", "A tap on GitHub: it grows into the page, Figma flies into the circle's front card, HN fades in behind it in the circle.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).choose("work-gh-pr", heldAt: 0.1)
        },
        // The closing rule (prototype 6mGJ7hWG v3, scenes 4 to 6), each held
        // mid-move, at 0.06 s: the cards into the circle about halfway.
        NamedState("stack.close.top", "Open the top one, 0.06 s", "A tap on Figma (nothing above it): it grows into the page, the cards under it fade in place, the circle with GitHub and HN rises from below.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).choose("work-figma-onb", heldAt: 0.06)
        },
        NamedState("stack.close.second", "Open the second, 0.06 s", "A tap on GitHub: Figma flies into the circle over the page, HN (which lay under GitHub) fades in in the circle in its place.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).choose("work-gh-pr", heldAt: 0.06)
        },
        NamedState("stack.close.third", "Open the third, 0.06 s", "A tap on HN: Figma and GitHub, which lay on it, fly into the circle; Lumen and older fade under the growing page.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).choose("work-hn", heldAt: 0.06)
        },
        NamedState("stack.gallery.3", "Closing a tab", "The GitHub card lifted by the finger: let go and it flies away.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).liftCard("work-gh-pr", by: -150)
        },
        NamedState("stack.gallery.4", "Closed, Undo", "GitHub closed: the cards closed the gap, “Closed github.com · Undo” at the bottom.") { app in
            await visit(app, ["work-linear-method", "work-lumen", "work-hn", "work-gh-pr"])
            await showAllTabs(app)
            TabStack.of(app).closeCard("work-gh-pr")
        },
        NamedState("stack.gallery.private", "All tabs in Private", "Only private tabs.") { app in
            await openPrivately(app, ["work-hn", "work-gh-pr", "work-lumen"])
            await showAllTabs(app)
        },
        // Right after a launch (TabPictures, TabWarmup): no tab was in front
        // in this run, so the pool has no picture of any.
        NamedState("stack.gallery.cold", "All tabs after launch", "No tab opened yet: cards with snapshots from disk, the rest load quietly and fade in in place of their icons.") { app in
            await showAllTabs(app)
            await warmedUp(app)
        },
    ]

    /// Until All Tabs' warm-up has nothing left to load (20 s at most).
    @MainActor
    private static func warmedUp(_ app: AppModel) async {
        let stack = TabStack.of(app)
        for _ in 0..<80 {
            let warmup = stack.warmup
            guard warmup.isOn, warmup.runningCount > 0 || !warmup.waitingIDs.isEmpty else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // The last picture's cross-fade.
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Has each tab in front once, its page drawn, then the one it started
    /// on again: each is pictured as the next comes in front.
    @MainActor
    private static func visit(_ app: AppModel, _ ids: [Tab.ID]) async {
        _ = TabStack.of(app)
        let start = app.browser.tab?.id
        for id in ids + [start].compactMap({ $0 }) {
            app.browser.select(id)
            await paint(app)
        }
    }

    /// Work with today's closed but one (or all, with the kept and the pins
    /// still there), by the store's own Close as a person's closes go.
    @MainActor
    private static func closeToday(_ app: AppModel, leaving: Tab.ID?) async {
        _ = TabStack.of(app)
        app.browser.select(leaving ?? "work-hn")
        await paint(app)
        for tab in app.browser.space.today where tab.id != leaving && tab.id != app.browser.tab?.id { app.browser.close(tab.id) }
        if leaving == nil, let front = app.browser.tab { app.browser.close(front.id) }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Opens copies of the world's tabs as private tabs, one after another.
    @MainActor
    private static func openPrivately(_ app: AppModel, _ ids: [Tab.ID]) async {
        _ = TabStack.of(app)
        for id in ids {
            guard var tab = app.browser.tab(id) else { continue }
            tab.id = "private-" + id
            app.openPrivately(tab)
            await paint(app)
        }
    }

    @MainActor
    private static func paint(_ app: AppModel) async {
        guard let tab = app.browser.tab else { return }
        app.pages.activate(tab)
        await app.pages.waitUntilPainted(tab.id, timeout: .seconds(10))
        // The stack's order follows the selection on the next turn.
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// All Tabs, once the page in front is pictured for its card, and come.
    @MainActor
    private static func showAllTabs(_ app: AppModel) async {
        let stack = TabStack.of(app)
        stack.openGallery()
        for _ in 0..<60 where stack.gallery == nil { try? await Task.sleep(for: .milliseconds(50)) }
        for _ in 0..<40 where stack.gallery?.phase == .opening { try? await Task.sleep(for: .milliseconds(50)) }
    }
}
