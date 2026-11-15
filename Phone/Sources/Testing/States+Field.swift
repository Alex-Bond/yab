import CoreGraphics
import Foundation

/// The named states of the field branch: the atlas's "Field over the page"
/// (field.1-5) and "New tab" (newtab.1-2), the plate's menu (page.6),
/// the board "Private" (privacy.1-5) and the word
/// "settings" in New Tab (settings.2). Each starts from the atlas's start:
/// Work, Onboarding v3 in Figma, nothing running.
extension StateCatalog {
    /// The prototype's samples (FV.samples) and the link Telegram sends.
    enum FieldSamples {
        static let ask = "what does anna want?"
        static let task = "book the tap 18:35 to lisbon, window seat"
        static let gift = "gift ideas for jonas"
        static let lumen = URL(string: "https://lumen.events/e/design-systems-night")!
    }

    static let field: [NamedState] = [
        NamedState("search.new", "Search sheet", "New Tab: the field and the recent pages, the page dimmed.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: false)
        },
        NamedState("search.launch", "Sheet at launch", "Yab coming to the front: the sheet standing from the first frame.") { app in
            FieldModel.sheetInTests = true
            app.openLaunchField()
        },
        NamedState("search.pull.35", "Sheet, pulled 35 %", "The rows gone, the field narrowing, the spaces not yet in.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: false)
            try? await Task.sleep(for: .milliseconds(700))
            app.field.sheetExpand = 0.35
        },
        NamedState("search.pull.60", "Sheet, pulled 60 %", "One sheet in the space's color, the pins under the narrowing field.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: false)
            try? await Task.sleep(for: .milliseconds(700))
            app.field.sheetExpand = 0.6
        },
        NamedState("search.pull.90", "Sheet, pulled 90 %", "The field nearly the capsule, the head coming in.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: false)
            try? await Task.sleep(for: .milliseconds(700))
            app.field.sheetExpand = 0.9
        },
        NamedState("search.chats", "Chats, foot bar", "Chats on the swipe: new chat, search, the check; the list under them.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: false)
            try? await Task.sleep(for: .milliseconds(700))
            app.field.expandSheet()
            try? await Task.sleep(for: .milliseconds(700))
            NewTabPager.shared.jump = NewTabPager.chatsPage
        },
        NamedState("search.address", "Sheet, address", "The plate's field in the sheet, the address selected.") { app in
            FieldModel.sheetInTests = true
            app.surfaces.openField(.address)
        },
        NamedState("search.typed", "Sheet, typed", "The best row right under the field.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: false)
            app.field.typed("lis")
        },
        NamedState("search.private", "Sheet, private", "The eyes shut: dark, one line.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: true)
        },
        NamedState("search.picks", "Search rows from a Mac", "A new iPhone in sync: the Mac's habits, its localhost left out.") { app in
            let now = Date()
            func place(_ url: String, _ title: String, _ typed: Bool = false) -> SyncedPlace {
                SyncedPlace(key: url, url: url, title: title, last: now.timeIntervalSince1970 - 3600, typed: typed, device: "mac")
            }
            app.field.fixturePicks = Suggestions.Input(
                visits: [], places: [place("https://github.com/", "GitHub: Let's build from here", true), place("https://github.com/pulls", "Pull requests", true),
                                     place("https://linear.app/", "Linear", true), place("https://mail.google.com/", "Gmail", true),
                                     place("http://localhost:3000/", "Local", true), place("https://x.com/", "X - The Everything App / X"),
                                     place("https://www.youtube.com/", "YouTube")],
                own: "phone", current: nil, engineHost: "google.com", now: now, hour: 11, limit: Metrics.SearchSheet.rows)
            FieldModel.sheetInTests = true
            app.surfaces.openField(.newTab)
            try? await Task.sleep(for: .milliseconds(600))
        },
        NamedState("search.chats.page", "Chats search over a page", "Search on Chats from a page: no address, no favicon, no eyes.") { app in
            FieldModel.sheetInTests = true
            app.surfaces.openField(.address)
            try? await Task.sleep(for: .milliseconds(600))
            app.field.expandSheet()
            try? await Task.sleep(for: .milliseconds(700))
            NewTabPager.shared.jump = NewTabPager.chatsPage
            try? await Task.sleep(for: .milliseconds(700))
        },
        NamedState("search.spaces", "Sheet, spaces", "Pulled up: the spaces, keyboard down.") { app in
            FieldModel.sheetInTests = true
            app.field.openNewTab(privately: false)
            try? await Task.sleep(for: .milliseconds(600))
            app.field.expandSheet()
        },
        NamedState("field.1", "Address selected", "The page card: Copy Link, Share, Ask, On Mac.") { app in
            app.surfaces.openField(.address)
        },
        NamedState("field.2", "Tab found", "“hacker”: your own tab on top, go switches to it.") { app in
            app.surfaces.openField(.address)
            app.field.typed("hacker")
        },
        NamedState("field.3", "Search", "“lisbon weather october”: the search key.") { app in
            app.surfaces.openField(.address)
            app.field.typed("lisbon weather october")
        },
        NamedState("field.4", "Question", "A question mark: Ask about this page on top.") { app in
            app.surfaces.openField(.address)
            app.field.typed(FieldSamples.ask)
        },
        NamedState("field.5", "Task", "A verb first: Task for Claude, the send key.") { app in
            app.browser.select("lisbon-flights")
            app.surfaces.openField(.address)
            app.field.typed(FieldSamples.task)
        },
        NamedState("newtab.1", "Sections", "Now, Recent Tabs, Frequent.") { app in
            app.surfaces.openField(.newTab)
        },
        NamedState("newtab.2", "Words", "“lis”: tabs, search, a question, a task.") { app in
            app.surfaces.openField(.newTab)
            app.field.typed("lis")
        },
        NamedState("page.6", "Page menu", "≡: the plate becomes the menu's address row, the sheet grows from it.") { app in
            StateCatalog.openPageMenu(app)
        },
        NamedState("chats.page", "Chats in the card", "The first page, before Private: New Chat and the chats, a search over them at the bottom.") { app in
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            app.field.openSpaces()
        },
        NamedState("about.1", "About", "About Yab as the Mac's: the icon, Yab, the version and build, one line, the links, the copyright.") { app in
            app.field.openSpaces()
            try? await Task.sleep(for: .milliseconds(300))
            AboutModel.shared.hold()
        },
        NamedState("newtab.private", "Private in the card, locked", "The Private page in New Tab: a lock, “No private tabs”, Unlock.") { app in
            NewTabPager.shared.startAt = NewTabPager.privatePage
            app.field.openSpaces()
        },
        NamedState("newtab.private.tabs", "Private in the card, locked, two tabs", "The same page with two private tabs open.") { app in
            let back = app.browser.spaceID
            app.openPrivately(PageFixtures.search(FieldSamples.gift))
            app.openPrivately(PageFixtures.search("flights to lisbon in march"))
            app.browser.showSpace(back)
            NewTabPager.shared.startAt = NewTabPager.privatePage
            app.field.openSpaces()
        },
        NamedState("newtab.private.trying", "Private in the card, Unlock tapped", "The words and button are gone, the lock alone in the center waiting for Face ID.") { app in
            #if DEBUG
            PrivateNewTab.tryingForStates = true
            #endif
            NewTabPager.shared.startAt = NewTabPager.privatePage
            app.field.openSpaces()
        },
        NamedState("newtab.private.empty", "Private in the card, empty", "The Private page after Face ID, with nothing open.") { app in
            #if DEBUG
            PrivateNewTab.listedForStates = true
            #endif
            NewTabPager.shared.startAt = NewTabPager.privatePage
            app.field.openSpaces()
        },
        NamedState("field.erased", "Erased the address", "The address field after erasing: ⓧ turned into eyes, the field as from the plus.") { app in
            app.surfaces.openField(.address)
            app.field.typed("")
        },
        NamedState("field.erased.shut", "Erased the address, eyes shut", "The same eyes shut: Incognito, a dark field, a private tab will open.") { app in
            app.surfaces.openField(.address)
            app.field.typed("")
            // After the card is up, as a finger would.
            try? await Task.sleep(for: .milliseconds(400))
            app.field.setPrivate(true)
        },
        NamedState("spaces.full", "Full screen", "Spaces full screen, edge to edge; down from the top of the list they go into the pill.") { app in
            app.field.openSpaces()
        },
        NamedState("spaces.open", "Open tab", "The space's open tab on its page: a white plate, like a selected row.") { app in
            if let tab = app.browser.space.today.dropFirst().first { app.browser.select(tab.id) }
            app.field.openSpaces()
        },
        NamedState("spaces.look", "Space in color", "The space card in the color picked on Color (preset 72F2E6), the open tab highlighted.") { app in
            if let look = SpaceLook(.object(["swatch": "custom", "color": "#72F2E6", "colors": .array(["#69E7B9", "#8C95E0"]), "grain": true, "grainAmount": 0.6])) {
                app.browser.setSpace(app.browser.spaceID, look: look)
            }
            if let tab = app.browser.space.today.dropFirst().first { app.browser.select(tab.id) }
            app.field.openSpaces()
        },
        NamedState("spaces.last", "Last space", "The folded card on the last space: the right inset matches the left.") { app in
            NewTabPager.shared.startAt = app.browser.spaces.last(where: { !$0.isPrivate })?.id
            app.field.openSpaces()
        },
        NamedState("chats.search", "Chat search", "“lis” in the field narrows the chat list.") { app in
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            app.field.openSpaces()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                app.field.typed("lis")
            }
        },
        // The two morphs held part way, for pictures of their frames.
        NamedState("lift.20", "Swipe 20%", "The card grows from the pill, the pill turned into the field.") { app in
            app.field.beginLift(); app.field.liftMoved(-0.2 * 640)
        },
        NamedState("lift.45", "Swipe 45%", "The sides spread apart, the pins show.") { app in
            app.field.beginLift(); app.field.liftMoved(-0.45 * 640)
        },
        NamedState("lift.75", "Swipe 75%", "The capsule faded in.") { app in
            app.field.beginLift(); app.field.liftMoved(-0.75 * 640)
        },
        NamedState("tofield.30", "Menu → field 30%", "The sheet's body is gone, the sheet shrinks to the row.") { app in
            StateCatalog.openPageMenu(app)
            StateCatalog.menuToField(app, 0.3)
        },
        NamedState("tofield.60", "Menu → field 60%", "The sheet is almost the field.") { app in
            StateCatalog.openPageMenu(app)
            StateCatalog.menuToField(app, 0.6)
        },
        NamedState("tofield.85", "Menu → field 85%", "The field replaces the sheet's row, the page card over it.") { app in
            StateCatalog.openPageMenu(app)
            StateCatalog.menuToField(app, 0.85)
        },
        NamedState("privacy.1", "Eyes in the field", "New tab: eyes on the right of the field, a ✕ beside them on a gray backing.") { app in
            app.surfaces.openField(.newTab)
        },
        NamedState("privacy.2", "Eyes shut", "A soft haptic, the lids close, the word Incognito beside them.") { app in
            app.surfaces.openField(.newTab)
            app.field.setPrivate(true)
        },
        NamedState("privacy.3", "Typed", "Only search or an address: no tabs, no chats, no agent suggestions.") { app in
            app.surfaces.openField(.newTab)
            app.field.setPrivate(true)
            app.field.typed(FieldSamples.gift)
        },
        NamedState("privacy.4", "Private tab", "The plate is dark, an incognito icon on the space button.") { app in
            app.openPrivately(PageFixtures.search(FieldSamples.gift))
        },
        NamedState("settings.2", "Word in the field", "“sett”: Settings on top, the go key.") { app in
            app.surfaces.openField(.newTab)
            app.field.typed("sett")
        },
    ] + fieldChecks

    /// The field branch's checks beyond the atlas (the prototype draws none
    /// of these frames): a private tab's own field and menu, Back after a
    /// search from the plate.
    static let fieldChecks: [NamedState] = [
        NamedState("fieldcheck.1", "Private tab field", "The card: only Copy Link and Share.") { app in
            app.openPrivately(PageFixtures.search(FieldSamples.gift))
            app.surfaces.openField(.address)
        },
        NamedState("fieldcheck.2", "Words in a private tab", "Only search in this tab: no tabs, no Claude.") { app in
            app.openPrivately(PageFixtures.search(FieldSamples.gift))
            app.surfaces.openField(.address)
            app.field.typed("hacker news")
        },
        NamedState("fieldcheck.3", "Private tab menu", "No Ask, task or Open on Mac.") { app in
            app.openPrivately(PageFixtures.search(FieldSamples.gift))
            // Once the private tab is in front: the chrome puts a page menu
            // away as the tab in front changes (ChromeLayer), and took this
            // one away as soon as it was drawn. Then the menu as ≡ leaves it,
            // shown, not only mounted (page.6).
            try? await Task.sleep(for: .milliseconds(400))
            StateCatalog.openPageMenu(app)
        },
        NamedState("fieldcheck.5", "Back after a search", "A search from the plate's field in the same tab, Back brought Figma back.") { app in
            guard let figma = app.browser.tab else { return }
            app.pages.activate(figma)
            await app.pages.waitUntilPainted(figma.id)
            app.surfaces.openField(.address)
            app.field.typed("lisbon weather october")
            app.fieldReturn()
            await app.pages.waitUntilPainted(figma.id)
            app.goBack()
            try? await Task.sleep(for: .seconds(1.5))
        },
    ]
}
