import XCTest

/// The tab stack's transitions, for perf and films (Transitions.swift says
/// how one is written): All Tabs opening from the stack's circle, and the
/// three closing cases of the rule (TabGalleryMotion.Closing): the top card,
/// the tab in front's, where nothing flies and the circle comes up from
/// below; the second, the previous tab's, where Figma flies into the circle
/// and HN appears in it; the third, HN's, where Figma and GitHub fly in.
/// From `stack.many` (Figma in front, GitHub, HN, Lumen and Linear used
/// before it, each pictured).
extension TransitionCatalog {
    static let tabs: [Transition] = [
        Transition(
            "tabsNew", signposts: ["searchSheet"], state: "stack.gallery", arguments: ["-YabSearchSheet"],
            ready: { app in TabsTransitions.galleryUp(app) },
            perform: { app in app.buttons["tabs.new"].tap() },
            arrived: { app in app.textFields["field.input"].waitForExistence(timeout: 10) }
        ),
        Transition(
            "tabsSidebar", state: "stack.gallery", arguments: ["-YabSearchSheet"],
            ready: { app in TabsTransitions.galleryUp(app) },
            perform: { app in app.buttons["tabs.sidebar"].tap() },
            arrived: { app in app.buttons["spaces.done"].waitForExistence(timeout: 10) }
        ),
        Transition(
            "tabsPinch", signposts: ["tabsOpen"], state: "stack.many",
            ready: { app in TabsTransitions.stackReady(app) && app.webViews.firstMatch.exists },
            perform: { app in app.webViews.firstMatch.pinch(withScale: 0.45, velocity: -1.5) },
            arrived: { app in TabsTransitions.galleryUp(app) }
        ),
        Transition(
            "tabsOpen",
            state: "stack.many",
            ready: { app in TabsTransitions.stackReady(app) },
            perform: { app in app.buttons["chrome.plus"].tap() },
            arrived: { app in TabsTransitions.galleryUp(app) },
            undo: { app in
                TabsTransitions.tapCard(app, "work-figma-onb")
                _ = TabsTransitions.stackReady(app)
            }
        ),
        Transition(
            "tabsScroll",
            state: "stack.gallery",
            ready: { app in TabsTransitions.galleryUp(app) },
            perform: { app in
                let card = TabsTransitions.element(app, "tabs.card.work-figma-onb")
                guard card.exists else { XCTFail("no Figma card to scroll"); return }
                let screen = app.windows.firstMatch.frame
                let x = min(max(card.frame.minX + 30, 20), screen.width - 20)
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: x, dy: card.frame.midY))
                start.press(forDuration: 0.05,
                            thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)),
                            withVelocity: .slow, thenHoldForDuration: 0.05)
            },
            arrived: { app in
                TransitionCatalog.wait(10) {
                    let card = TabsTransitions.element(app, "tabs.card.work-figma-onb")
                    return card.exists && abs(card.frame.midX - app.windows.firstMatch.frame.midX) < 12
                }
            }
        ),
        Transition(
            "tabsCardClose",
            signposts: ["tabsCardFly", "tabsReflow"],
            state: "stack.gallery",
            ready: { app in TabsTransitions.galleryUp(app) },
            perform: { app in
                let card = TabsTransitions.element(app, "tabs.card.work-gh-pr")
                guard card.exists else { XCTFail("no GitHub card to close"); return }
                let screen = app.windows.firstMatch.frame
                let x = min(max(card.frame.minX + 40, 20), screen.width - 20)
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: x, dy: card.frame.midY))
                start.press(forDuration: 0.05,
                            thenDragTo: start.withOffset(CGVector(dx: 0, dy: -380)),
                            withVelocity: .fast, thenHoldForDuration: 0)
            },
            arrived: { app in
                TransitionCatalog.wait(10) {
                    TabsTransitions.element(app, "tabs.gallery").exists
                        && !TabsTransitions.element(app, "tabs.card.work-gh-pr").exists
                        && TabsTransitions.element(app, "tabs.card.work-hn").exists
                }
            }
        ),
        Transition(
            "tabsCardOpen",
            state: "stack.gallery",
            ready: { app in TabsTransitions.galleryUp(app) },
            perform: { app in TabsTransitions.tapCard(app, "work-figma-onb") },
            arrived: { app in TabsTransitions.galleryGone(app) }
        ),
        Transition(
            "tabsPreviousCardOpen",
            signposts: ["tabsCardOpen"],
            state: "stack.gallery",
            ready: { app in TabsTransitions.galleryUp(app) },
            perform: { app in TabsTransitions.tapCard(app, "work-gh-pr") },
            arrived: { app in TabsTransitions.galleryGone(app) }
        ),
        Transition(
            "tabsThirdCardOpen",
            signposts: ["tabsCardOpen"],
            state: "stack.gallery",
            ready: { app in TabsTransitions.galleryUp(app) },
            perform: { app in TabsTransitions.tapCard(app, "work-hn") },
            arrived: { app in TabsTransitions.galleryGone(app) }
        ),
    ]
}

private enum TabsTransitions {
    static func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// The stack names GitHub as the tab used before Figma.
    static func stackReady(_ app: XCUIApplication) -> Bool {
        let stack = app.buttons["chrome.plus"]
        guard stack.waitForExistence(timeout: 60) else { return false }
        return TransitionCatalog.wait(30) { stack.exists && stack.isHittable && stack.label.hasPrefix("Previous tab, feat(editor)") }
    }

    /// All Tabs is up and at rest: its + is there only then.
    static func galleryUp(_ app: XCUIApplication) -> Bool {
        guard element(app, "tabs.gallery").waitForExistence(timeout: 30) else { return false }
        return TransitionCatalog.wait(10) { element(app, "tabs.new").exists && element(app, "tabs.new").isHittable }
    }

    static func galleryGone(_ app: XCUIApplication) -> Bool {
        TransitionCatalog.wait(10) { !element(app, "tabs.gallery").exists && app.buttons["chrome.plus"].exists }
    }

    /// A card's own visible part: the tab in front's card is mostly past the
    /// screen's right edge, so the tap lands 40 points into what shows.
    static func tapCard(_ app: XCUIApplication, _ id: String) {
        let card = element(app, "tabs.card.\(id)")
        guard card.waitForExistence(timeout: 10) else { XCTFail("no card for \(id)"); return }
        let screen = app.windows.firstMatch.frame
        let x = min(max(card.frame.minX + 40, 20), screen.width - 20)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: card.frame.midY)).tap()
    }
}
