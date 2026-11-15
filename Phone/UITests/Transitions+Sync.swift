import XCTest

/// The transitions of sync (M7), for perf and films
/// (Transitions.swift says how one is written). This branch's file: add
/// them here, and `TransitionCatalog.all` has them.
///
/// The first run's chain (Welcome/FirstRun) is here too: each of its
/// hand-overs is one movement, so `Phone/scripts/remote film - NAME` can
/// look at it frame by frame.
extension TransitionCatalog {
    static let sync: [Transition] = [
        Transition(
            "firstRunStart",
            state: "welcome.23",
            ready: { $0.buttons["welcome.start"].waitForExistence(timeout: 20) },
            perform: { app in app.buttons["welcome.start"].tap() },
            arrived: { app in app.buttons["welcome.noMac"].waitForExistence(timeout: 5) }
        ),
        Transition(
            "firstRunCode",
            state: "welcome.7",
            ready: { $0.buttons["welcome.useCode"].waitForExistence(timeout: 20) },
            perform: { app in app.buttons["welcome.useCode"].tap() },
            arrived: { app in app.descendants(matching: .any)["welcome.code"].waitForExistence(timeout: 5) }
        ),
        Transition(
            "firstRunRecovery",
            state: "welcome.9",
            ready: { $0.buttons["welcome.recovery"].waitForExistence(timeout: 20) },
            perform: { app in app.buttons["welcome.recovery"].tap() },
            arrived: { app in app.descendants(matching: .any)["welcome.key"].waitForExistence(timeout: 5) }
        ),
        Transition(
            "firstRunShield",
            state: "welcome.6",
            ready: { $0.buttons["welcome.join"].waitForExistence(timeout: 20) },
            perform: { app in app.buttons["welcome.join"].tap() },
            arrived: { app in app.switches["welcome.blockAds"].waitForExistence(timeout: 6) }
        ),
        Transition(
            "firstRunIcon",
            state: "welcome.16",
            ready: { $0.buttons["welcome.continue"].waitForExistence(timeout: 20) },
            perform: { app in app.buttons["welcome.continue"].tap() },
            arrived: { app in app.buttons["welcome.linksNotNow"].waitForExistence(timeout: 5) }
        ),
        Transition(
            "firstRunField",
            state: "welcome.18",
            // The app always wears the search sheet; a test run draws it only
            // when asked (FieldModel.sheetAllowed). No tab is asked for: a
            // phone that has just joined ends the first run on the empty
            // browser, with the Mac's tabs as rows in the sheet.
            arguments: ["-YabSearchSheet"],
            ready: { $0.buttons["welcome.linksNotNow"].waitForExistence(timeout: 20) },
            perform: { app in app.buttons["welcome.linksNotNow"].tap() },
            // The field, then the sheet and the keyboard it brings; the wait
            // holds the camera long enough for all of it (2.5 s and more).
            arrived: { app in
                let field = app.textFields["field.input"].waitForExistence(timeout: 8)
                _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
                Thread.sleep(forTimeInterval: 2)
                return field
            }
        ),
        Transition(
            "firstRunBack",
            state: "welcome.9",
            ready: { $0.buttons["welcome.back"].waitForExistence(timeout: 20) },
            perform: { app in app.buttons["welcome.back"].tap() },
            arrived: { app in app.buttons["welcome.useCode"].waitForExistence(timeout: 5) }
        ),
    ]
}
