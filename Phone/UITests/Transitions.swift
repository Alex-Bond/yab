import XCTest

/// A movement the perf and film tests can make happen with a real finger:
/// where it starts, what the finger does, how to tell it arrived, and how to
/// go back for the next repeat. `name` is the Motion's (Design/Motion.swift),
/// the signpost it runs inside; `signposts` are every name it emits.
///
/// Each feature lists its own in its file `Transitions+<Feature>.swift`
/// (field, chats, tasks, settings, sync, tabs), which is there already with
/// an empty array that `all` reads: a feature edits only its own file, never
/// this one, so branches don't meet in one line.
struct Transition {
    let name: String
    var signposts: [String]
    /// The named state it starts from (launched without -YabNoAnim), if any.
    var state: String?
    /// More launch arguments (-YabTab work-launch-notes ...).
    var arguments: [String] = []
    /// Ready to start: the page drawn, the button there.
    var ready: (XCUIApplication) -> Bool = { _ in true }
    /// The finger.
    let perform: (XCUIApplication) -> Void
    /// The movement arrived.
    var arrived: (XCUIApplication) -> Bool = { _ in true }
    /// Back to the start, for the next repeat (nil: relaunch instead).
    var undo: ((XCUIApplication) -> Void)?

    init(_ name: String, signposts: [String]? = nil, state: String? = nil, arguments: [String] = [],
         ready: @escaping (XCUIApplication) -> Bool = { _ in true },
         perform: @escaping (XCUIApplication) -> Void,
         arrived: @escaping (XCUIApplication) -> Bool = { _ in true },
         undo: ((XCUIApplication) -> Void)? = nil) {
        self.name = name
        self.signposts = signposts ?? [name]
        self.state = state
        self.arguments = arguments
        self.ready = ready
        self.perform = perform
        self.arrived = arrived
        self.undo = undo
    }
}

enum TransitionCatalog {
    static var all: [Transition] { page + field + chats + tasks + settings + sync + tabs }

    static func named(_ name: String) -> Transition? { all.first { $0.name == name } }

    /// Polls until `check` holds or the time is up.
    static func wait(_ timeout: TimeInterval = 5, _ check: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return check()
    }
}

/// The page and its chrome (the skeleton's): the plate folding on a scroll.
extension TransitionCatalog {
    static let page: [Transition] = [
        Transition(
            "chromeFold",
            arguments: ["-YabTab", "work-launch-notes"],
            // A minute: the first launch after an install starts a cold web
            // process, slow on a loaded Mac.
            ready: { app in
                app.descendants(matching: .any)["chrome.plate"].waitForExistence(timeout: 60)
                    && app.webViews.firstMatch.staticTexts["Tern 2.0 launch notes"].waitForExistence(timeout: 60)
            },
            perform: { app in app.webViews.firstMatch.swipeUp(velocity: .slow) },
            arrived: { app in
                let plate = app.descendants(matching: .any)["chrome.plate"]
                return TransitionCatalog.wait { abs(plate.frame.height - 44) < 1 }
            },
            undo: { app in
                app.webViews.firstMatch.swipeDown(velocity: .slow)
                let plate = app.descendants(matching: .any)["chrome.plate"]
                _ = TransitionCatalog.wait { abs(plate.frame.height - 50) < 1 }
            }
        ),
        Transition(
            "chromeUnfold",
            signposts: ["chromeFold"],
            state: "page.2",
            ready: { app in app.descendants(matching: .any)["chrome.plate"].waitForExistence(timeout: 60) },
            perform: { app in app.descendants(matching: .any)["chrome.plate"].tap() },
            arrived: { app in
                let input = app.textFields["field.input"]
                return TransitionCatalog.wait { input.isHittable && app.keyboards.firstMatch.exists }
            }
        ),
        lift("chromeLift", tab: "work-hn", text: "Hacker News"),
        lift("chromeLiftShort", tab: "work-launch-notes", text: "Tern 2.0 launch notes"),
    ]

    /// Pulled back down, the page unfolds the plate out of its capsule
    /// (page.folded, as AtlasMotionTests' unfold): a long host
    /// (news.ycombinator.com) and a short one (paper.so), since the words'
    /// room beside ≡ and ↻ is what differs between them.
    private static func lift(_ name: String, tab: String, text: String) -> Transition {
        Transition(
            name,
            signposts: ["chromeFold"],
            state: "page.folded",
            arguments: ["-YabTab", tab],
            // Still folded when the finger comes: a page's first scroll report
            // at the top unfolds the state's capsule on its own now and then
            // (filmed 2026-11-06, the chrome open from the first frame).
            ready: { app in
                let plate = app.descendants(matching: .any)["chrome.plate"]
                return plate.waitForExistence(timeout: 60)
                    && app.webViews.firstMatch.staticTexts[text].waitForExistence(timeout: 60)
                    && TransitionCatalog.wait { abs(plate.frame.height - 44) < 1 }
            },
            perform: { app in app.webViews.firstMatch.swipeDown(velocity: .slow) },
            arrived: { app in
                let plate = app.descendants(matching: .any)["chrome.plate"]
                return TransitionCatalog.wait { abs(plate.frame.height - 48) < 1 }
            }
        )
    }
}
