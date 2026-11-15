import XCTest

/// The transitions of tasks (M8), for perf and films (Transitions.swift says
/// how one is written): the task's chat out of the Now line and folded back
/// into it, and the code's sheet out of the line. Each starts from a named
/// state and its signposts are the Motions it runs (Design/Motion.swift).
extension TransitionCatalog {
    static let tasks: [Transition] = [
        Transition(
            "nowToChat",
            state: "now.3",
            ready: { app in TasksTransitions.now(app).waitForExistence(timeout: 60) },
            perform: { app in TasksTransitions.now(app).tap() },
            arrived: { app in
                let sheet = app.descendants(matching: .any)["task.chat.sheet"]
                return sheet.waitForExistence(timeout: 5) && TransitionCatalog.wait { abs(sheet.frame.minY - 60) < 1 }
            },
            undo: { app in
                app.descendants(matching: .any)["task.chat.who"].swipeDown(velocity: .fast)
                _ = TransitionCatalog.wait { !app.descendants(matching: .any)["task.chat.sheet"].exists }
            }
        ),
        Transition(
            "chatToNow",
            state: "chat.9",
            ready: { app in
                let title = app.descendants(matching: .any)["task.chat.who"]
                return title.waitForExistence(timeout: 60) && TransitionCatalog.wait { title.isHittable }
            },
            perform: { app in app.descendants(matching: .any)["task.chat.who"].swipeDown(velocity: .fast) },
            arrived: { app in
                TransitionCatalog.wait { !app.descendants(matching: .any)["task.chat.sheet"].exists }
                    && TasksTransitions.now(app).waitForExistence(timeout: 3)
            },
            undo: { app in
                TasksTransitions.now(app).tap()
                let title = app.descendants(matching: .any)["task.chat.who"]
                _ = title.waitForExistence(timeout: 5) && TransitionCatalog.wait { title.isHittable }
            }
        ),
        Transition(
            "sheetGrow",
            state: "now.5",
            ready: { app in TasksTransitions.now(app).waitForExistence(timeout: 60) },
            perform: { app in TasksTransitions.now(app).tap() },
            arrived: { app in
                let sheet = app.descendants(matching: .any)["task.code"]
                guard sheet.waitForExistence(timeout: 5) else { return false }
                // Grown: its frame holds still at its own width.
                return TransitionCatalog.wait { abs(sheet.frame.minX - 8) < 1 }
            },
            undo: { app in
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
                _ = TransitionCatalog.wait { !app.descendants(matching: .any)["task.code"].exists }
            }
        ),
    ]
}

enum TasksTransitions {
    /// The Now line in the chrome.
    static func now(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["chrome.now"] }
}
