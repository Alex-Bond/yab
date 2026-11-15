import XCTest

/// The transitions of Settings and the first launch (M9), for perf and films
/// (Transitions.swift says how one is written). This branch's file: add
/// them here, and `TransitionCatalog.all` has them.
extension TransitionCatalog {
    static let settings: [Transition] = [
        // A page changes the sheet's body in place: Appearance over the root.
        Transition(
            "settingsPush", signposts: ["settingsPush"], state: "settings.1",
            ready: { app in app.buttons["settings.row.appearance"].waitForExistence(timeout: 30) },
            perform: { app in app.buttons["settings.row.appearance"].tap() },
            arrived: { app in TransitionCatalog.wait(5, {
                let choice = app.buttons["settings.choice.appearance.dark"]
                return TransitionCatalog.settingsPage(app).label == "Appearance" && choice.isHittable
                    && abs(choice.frame.minX - 16) < 1 && app.windows.firstMatch.frame.contains(choice.frame)
                    && app.buttons["settings.back"].isHittable
            }) },
            undo: { app in
                app.buttons["settings.back"].tap()
                _ = TransitionCatalog.wait { !TransitionCatalog.settingsPage(app).exists }
            }),
        // ‹ changes it back, quicker.
        Transition(
            "settingsBack", signposts: ["settingsBack"], state: "settings.1",
            ready: { app in
                let row = app.buttons["settings.row.appearance"]
                guard row.waitForExistence(timeout: 30) else { return false }
                row.tap()
                return TransitionCatalog.wait(5, {
                    let choice = app.buttons["settings.choice.appearance.dark"]
                    return choice.isHittable && abs(choice.frame.minX - 16) < 1 && app.buttons["settings.back"].isHittable
                })
            },
            perform: { app in app.buttons["settings.back"].tap() },
            arrived: { app in TransitionCatalog.wait(5, {
                let row = app.buttons["settings.row.appearance"]
                return !TransitionCatalog.settingsPage(app).exists && row.isHittable && abs(row.frame.minX - 16) < 1
                    && app.buttons["settings.close"].isHittable
            }) },
            undo: { app in
                app.buttons["settings.row.appearance"].tap()
                _ = TransitionCatalog.wait(5, {
                    let choice = app.buttons["settings.choice.appearance.dark"]
                    return choice.isHittable && abs(choice.frame.minX - 16) < 1
                })
            }),
        // Back from a page by a finger from the left edge, as iOS's: the page
        // follows it, the root comes out from under it; let go past the middle.
        Transition(
            "settingsBackSwipe", signposts: ["settingsBack"], state: "settings.1",
            ready: { app in
                let row = app.buttons["settings.row.appearance"]
                guard row.waitForExistence(timeout: 30) else { return false }
                row.tap()
                return TransitionCatalog.wait(5, { app.buttons["settings.back"].isHittable })
            },
            perform: { app in
                let window = app.windows.firstMatch
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.55)).withOffset(CGVector(dx: 6, dy: 0))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: window.frame.width * 0.6, dy: 0)),
                            withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { app in TransitionCatalog.wait(5, { app.buttons["settings.close"].isHittable }) }),
        // App Icon's own page, from its root row.
        Transition(
            "settingsAppIcon", signposts: ["settingsPush"], state: "settings.1",
            ready: { app in app.buttons["settings.row.appIcon"].waitForExistence(timeout: 30) },
            perform: { app in app.buttons["settings.row.appIcon"].tap() },
            arrived: { app in TransitionCatalog.wait(5, {
                app.buttons["settings.appIcon.use"].isHittable && app.buttons["settings.back"].isHittable
            }) },
            undo: { app in
                app.buttons["settings.back"].tap()
                _ = TransitionCatalog.wait { app.buttons["settings.close"].isHittable }
            }),
        // Settings rises from below as a plain sheet: from the word in the field.
        Transition(
            "settingsOpen", signposts: ["settingsOpen"], state: "settings.2",
            ready: { app in app.buttons["field.best"].waitForExistence(timeout: 30) },
            perform: { app in app.buttons["field.best"].tap() },
            arrived: { app in TransitionCatalog.wait(5, {
                let sheet = app.descendants(matching: .any)["settings.sheet"].firstMatch
                return sheet.exists && abs(sheet.frame.minY - 60) < 1
            }) }),
        // × drops it away.
        Transition(
            "settingsClose", signposts: ["settingsClose"], state: "settings.1",
            ready: { app in app.buttons["settings.close"].waitForExistence(timeout: 30) },
            perform: { app in app.buttons["settings.close"].tap() },
            arrived: { app in TransitionCatalog.wait(5, {
                !app.descendants(matching: .any)["settings.sheet"].firstMatch.exists
            }) }),
    ]

    static func settingsPage(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["settings.page.title"].firstMatch
    }
}
