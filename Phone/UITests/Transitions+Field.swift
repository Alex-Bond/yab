import XCTest

/// The transitions of the field and asking (M3): fieldOpen, fieldClose, plusToField, eyes ..., for perf and films
/// (Transitions.swift says how one is written). This branch's file: add
/// them here, and `TransitionCatalog.all` has them.
extension TransitionCatalog {
    static let field: [Transition] = [
        // Words sent: the sheet goes up to the top and the page shows through it.
        Transition(
            "sheetUpToPage",
            arguments: ["-YabSearchSheet", "-YabTab", "work-launch-notes"],
            ready: { app in
                let plate = app.descendants(matching: .any)["chrome.plate"]
                guard plate.waitForExistence(timeout: 60) else { return false }
                plate.firstMatch.tap()
                guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else { return false }
                app.typeText("tern launch notes")
                return app.descendants(matching: .any)["field.best"].waitForExistence(timeout: 5)
            },
            perform: { app in app.descendants(matching: .any)["field.best"].firstMatch.tap() },
            arrived: { app in app.keyboards.firstMatch.waitForNonExistence(timeout: 5) }
        ),
        // The search sheet from a page, cold: the first open since launch, each repeat a fresh launch.
        Transition(
            "sheetFirstOpen",
            signposts: ["searchSheet"],
            arguments: ["-YabSearchSheet", "-YabTab", "work-launch-notes"],
            ready: { app in app.descendants(matching: .any)["chrome.plate"].waitForExistence(timeout: 60) },
            perform: { app in app.descendants(matching: .any)["chrome.plate"].firstMatch.tap() },
            arrived: { app in app.keyboards.firstMatch.waitForExistence(timeout: 5) }
        ),
        // Open and close again, warm.
        Transition(
            "sheetOpen",
            signposts: ["searchSheet"],
            arguments: ["-YabSearchSheet", "-YabTab", "work-launch-notes"],
            ready: { app in app.descendants(matching: .any)["chrome.plate"].waitForExistence(timeout: 60) },
            perform: { app in app.descendants(matching: .any)["chrome.plate"].firstMatch.tap() },
            arrived: { app in app.keyboards.firstMatch.waitForExistence(timeout: 5) },
            undo: { app in
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
                _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
                _ = TransitionCatalog.wait { !app.descendants(matching: .any)["search.sheet"].exists }
            }
        ),
        // A pull up the sheet: the spaces. Each repeat a fresh launch, the finger's own morph.
        Transition(
            "sheetToSpaces",
            signposts: ["spacesMorph"],
            state: "search.new",
            arguments: ["-YabSearchSheet"],
            ready: { app in app.descendants(matching: .any)["search.sheet"].waitForExistence(timeout: 60) },
            perform: { app in
                let window = app.windows.firstMatch
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)),
                            withVelocity: .fast, thenHoldForDuration: 0)
            },
            arrived: { app in TransitionCatalog.wait { app.descendants(matching: .any)["search.sheet"].firstMatch.value as? String == "spaces" } }
        ),
        // + on the spaces the pull opened: back to the low sheet with the keyboard.
        Transition(
            "sheetBack",
            signposts: ["spacesMorph"],
            state: "search.spaces",
            arguments: ["-YabSearchSheet"],
            ready: { app in app.descendants(matching: .any)["spaces.new"].waitForExistence(timeout: 60) },
            perform: { app in app.descendants(matching: .any)["spaces.new"].firstMatch.tap() },
            arrived: { app in app.keyboards.firstMatch.waitForExistence(timeout: 5) }
        ),
        // + on the spaces a plate swipe opened: the recording's case.
        Transition(
            "spacesPlus",
            signposts: ["spacesMorph"],
            state: "spaces.last",
            arguments: ["-YabSearchSheet"],
            ready: { app in app.descendants(matching: .any)["spaces.new"].waitForExistence(timeout: 60) },
            perform: { app in app.descendants(matching: .any)["spaces.new"].firstMatch.tap() },
            arrived: { app in app.keyboards.firstMatch.waitForExistence(timeout: 5) }
        ),
        // ≡: the plate rises into the menu's address row, the sheet grows out of it.
        Transition(
            "plateMenu",
            ready: { app in app.buttons["chrome.pageMenu"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["chrome.pageMenu"].tap() },
            arrived: { app in app.buttons["plate.menu.siteSettings"].waitForExistence(timeout: 5) },
            undo: { app in
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
                _ = TransitionCatalog.wait { !app.descendants(matching: .any)["plate.menu"].exists }
            }
        ),
        // A tap beside: the row lands back into the plate.
        Transition(
            "plateMenuClose",
            state: "page.6",
            ready: { app in app.buttons["plate.menu.siteSettings"].waitForExistence(timeout: 60) },
            perform: { app in app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() },
            arrived: { app in TransitionCatalog.wait { app.descendants(matching: .any)["chrome.plate"].exists } }
        ),
        // Site Settings: the same sheet, the row shrinks into "‹ figma.com".
        Transition(
            "siteSettingsIn",
            state: "page.6",
            ready: { app in app.buttons["plate.menu.siteSettings"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["plate.menu.siteSettings"].tap() },
            arrived: { app in app.buttons["site.back"].waitForExistence(timeout: 5) },
            undo: { app in
                app.buttons["site.back"].tap()
                _ = app.buttons["plate.menu.siteSettings"].waitForExistence(timeout: 5)
            }
        ),
        Transition(
            "siteSettingsOut",
            state: "site.1",
            ready: { app in app.buttons["site.back"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["site.back"].tap() },
            arrived: { app in app.buttons["plate.menu.siteSettings"].waitForExistence(timeout: 5) }
        ),
        // Downloads, three ways in: the same sheet and spring as Site Settings,
        // one step deeper from it, and straight out of the plate from the line.
        Transition(
            "downloadsIn",
            signposts: ["siteSettingsIn"],
            state: "downloads.menu",
            ready: { app in app.buttons["plate.menu.downloads"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["plate.menu.downloads"].tap() },
            arrived: { app in app.descendants(matching: .any)["downloads.page"].waitForExistence(timeout: 5) },
            undo: { app in
                app.buttons["site.back"].tap()
                _ = app.buttons["plate.menu.downloads"].waitForExistence(timeout: 5)
            }
        ),
        Transition(
            "downloadsOut",
            signposts: ["siteSettingsOut"],
            state: "downloads.page",
            ready: { app in app.buttons["site.back"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["site.back"].tap() },
            arrived: { app in app.buttons["plate.menu.siteSettings"].waitForExistence(timeout: 5) }
        ),
        Transition(
            "downloadsDeep",
            signposts: ["siteSettingsIn"],
            state: "downloads.site",
            ready: { app in app.buttons["site.downloaded"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["site.downloaded"].tap() },
            arrived: { app in app.descendants(matching: .any)["downloads.page"].waitForExistence(timeout: 5) },
            undo: { app in
                app.buttons["site.back"].tap()
                _ = app.buttons["site.downloaded"].waitForExistence(timeout: 5)
            }
        ),
        Transition(
            "downloadsFromNow",
            state: "downloads.now",
            ready: { app in app.descendants(matching: .any)["chrome.now"].waitForExistence(timeout: 60) },
            perform: { app in app.descendants(matching: .any)["chrome.now"].tap() },
            arrived: { app in app.descendants(matching: .any)["downloads.page"].waitForExistence(timeout: 5) }
        ),
        // Copy Link: the link turns into a tick where it is, the menu stays.
        Transition(
            "linkCopied",
            state: "page.6",
            ready: { app in app.buttons["plate.menu.copy"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["plate.menu.copy"].tap() },
            arrived: { app in TransitionCatalog.wait { app.buttons["plate.menu.copy"].value as? String == "Copied" } }
        ),
        // The spaces card: a finger on a page's list stretches it over the
        // screen, and from there lets it back down.
        Transition(
            "spacesStretch",
            state: "spaces.last",
            ready: { app in app.descendants(matching: .any)["newtab.spaces"].waitForExistence(timeout: 60) },
            perform: { app in
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)),
                            withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { _ in TransitionCatalog.wait(1.5) { false } || true }
        ),
        Transition(
            "spacesShrink",
            state: "spaces.full",
            ready: { app in app.descendants(matching: .any)["newtab.spaces"].waitForExistence(timeout: 60) },
            perform: { app in
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)),
                            withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { _ in TransitionCatalog.wait(1.5) { false } || true }
        ),
        // A chat out of its row on the Chats page, then a pull down on its
        // head back into the row.
        Transition(
            "chatFromSpaces",
            state: "chats.page",
            ready: { app in app.descendants(matching: .any)["newtab.chat.cafe"].waitForExistence(timeout: 60) },
            perform: { app in
                app.descendants(matching: .any)["newtab.chat.cafe"].tap()
                _ = app.descendants(matching: .any)["chat.title"].waitForExistence(timeout: 3)
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                let head = app.descendants(matching: .any)["chat.title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                head.press(forDuration: 0.05, thenDragTo: head.withOffset(CGVector(dx: 0, dy: 320)),
                           withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { _ in TransitionCatalog.wait(1.5) { false } || true }
        ),
        Transition(
            "chatBackToSpaces",
            state: "chats.page",
            ready: { app in app.descendants(matching: .any)["newtab.chat.cafe"].waitForExistence(timeout: 60) },
            perform: { app in
                app.descendants(matching: .any)["newtab.chat.cafe"].tap()
                _ = app.descendants(matching: .any)["chat.history"].waitForExistence(timeout: 3)
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                app.descendants(matching: .any)["chat.history"].tap()
            },
            arrived: { _ in TransitionCatalog.wait(1.5) { false } || true }
        ),
        // A finger along the plate: the next tab.
        Transition(
            "tabSwipe",
            arguments: ["-YabTab", "work-launch-notes"],
            ready: { app in
                app.descendants(matching: .any)["chrome.plate"].waitForExistence(timeout: 60)
                    && app.webViews.firstMatch.staticTexts["Tern 2.0 launch notes"].waitForExistence(timeout: 60)
            },
            perform: { app in
                let plate = app.descendants(matching: .any)["chrome.plate"].coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
                plate.press(forDuration: 0.05, thenDragTo: plate.withOffset(CGVector(dx: -220, dy: 0)),
                            withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { _ in TransitionCatalog.wait(1.5) { false } || true }
        ),
        // ✕ on the spaces: the screen goes back into the plate.
        Transition(
            "spacesClose",
            state: "spaces.full",
            ready: { app in app.buttons["field.close"].waitForExistence(timeout: 60) },
            perform: { app in app.buttons["field.close"].tap() },
            arrived: { _ in TransitionCatalog.wait(1.5) { false } || true }
        ),
        // Past the last tab: New Tab's spaces slide in, the pill becomes the field.
        Transition(
            "newTabSwipe",
            state: "page.last",
            ready: { app in app.descendants(matching: .any)["chrome.plate"].waitForExistence(timeout: 60) },
            perform: { app in
                let plate = app.descendants(matching: .any)["chrome.plate"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
                plate.press(forDuration: 0.05, thenDragTo: plate.withOffset(CGVector(dx: -260, dy: 0)),
                            withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { _ in TransitionCatalog.wait(2) { false } || true }
        ),
        // The spaces' list scrolled under the head and held there: the head's edge.
        Transition(
            "spacesScroll",
            state: "spaces.full",
            ready: { app in app.descendants(matching: .any)["newtab.spaces"].waitForExistence(timeout: 60) },
            perform: { app in
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)),
                            withVelocity: .slow, thenHoldForDuration: 1.5)
            },
            arrived: { _ in TransitionCatalog.wait(1.0) { false } || true }
        ),
    ]
}
