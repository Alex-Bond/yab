import XCTest

/// An answer grows from the question the person typed in the page's field.
/// Preparation uses the same finger path, before the film's recording mark;
/// the measured movement starts with Return and ends with the landed bubble.
extension TransitionCatalog {
    static let chats: [Transition] = [
        // Add to Chat's tray, main page to Model and back: one surface whose
        // height follows its page (Chats/AttachTray), filmed to check it moves.
        Transition(
            "attachTrayModel",
            signposts: [],
            state: "attach.2",
            ready: { app in app.descendants(matching: .any)["chat.attachTray.model"].waitForExistence(timeout: 30) },
            perform: { app in
                app.descendants(matching: .any)["chat.attachTray.model"].tap()
                Thread.sleep(forTimeInterval: 0.9)
                app.descendants(matching: .any)["chat.attachTray.close"].tap()
            },
            arrived: { app in
                let model = app.descendants(matching: .any)["chat.attachTray.model"]
                return TransitionCatalog.wait { model.isHittable }
            }
        ),
        // A chat's card on the Chats page: the chat zooms out of it into its
        // own cover (UIKit's zoom, as Chat Info's), and ‹ zooms it back in.
        Transition(
            "chatRowZoom",
            signposts: [],
            state: "chats.page",
            ready: { app in ChatsTransitions.element(app, "newtab.chat.cafe").waitForExistence(timeout: 60) },
            perform: { app in
                ChatsTransitions.element(app, "newtab.chat.cafe").tap()
                guard TransitionCatalog.wait(5, { ChatsTransitions.element(app, "chat.history").isHittable }) else { return }
                Thread.sleep(forTimeInterval: 0.7)
                ChatsTransitions.element(app, "chat.history").tap()
            },
            arrived: { app in
                TransitionCatalog.wait { !ChatsTransitions.element(app, "chat.history").exists }
            }
        ),
        // The same chat taken back by the system's swipe from the left edge.
        Transition(
            "chatRowEdge",
            signposts: [],
            state: "chats.page",
            ready: { app in ChatsTransitions.element(app, "newtab.chat.cafe").waitForExistence(timeout: 60) },
            perform: { app in
                ChatsTransitions.element(app, "newtab.chat.cafe").tap()
                guard TransitionCatalog.wait(5, { ChatsTransitions.element(app, "chat.history").isHittable }) else { return }
                Thread.sleep(forTimeInterval: 0.7)
                let window = app.windows.firstMatch
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: window.frame.width * 0.62, dy: 0)),
                            withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { app in
                TransitionCatalog.wait { !ChatsTransitions.element(app, "chat.history").exists }
            }
        ),
        // A chat opened from the card, pulled down slowly and moved around
        // while held: the page follows the finger, smaller as it goes down,
        // then let go it flies into its card.
        Transition(
            "chatPullHold",
            signposts: [],
            state: "chats.page",
            ready: { app in ChatsTransitions.element(app, "newtab.chat.cafe").waitForExistence(timeout: 60) },
            perform: { app in
                ChatsTransitions.element(app, "newtab.chat.cafe").tap()
                guard TransitionCatalog.wait(5, { ChatsTransitions.element(app, "chat.history").isHittable }) else { return }
                Thread.sleep(forTimeInterval: 0.7)
                let size = app.windows.firstMatch.frame.size
                let start = CGPoint(x: size.width / 2, y: size.height * 0.42)
                // Down 250 and left 60, then right 120, held, let go.
                ChatsTransitions.drag(app, through: [
                    (start, 0),
                    (CGPoint(x: start.x - 30, y: start.y + 80), 0.35),
                    (CGPoint(x: start.x - 60, y: start.y + 250), 0.9),
                    (CGPoint(x: start.x + 60, y: start.y + 250), 1.5),
                    (CGPoint(x: start.x + 60, y: start.y + 252), 2.3),
                ])
            },
            arrived: { app in
                TransitionCatalog.wait { !ChatsTransitions.element(app, "chat.history").exists }
            }
        ),
        // Pulled down 150 and back up before letting go: the chat stays.
        Transition(
            "chatPullCancel",
            signposts: [],
            state: "chats.page",
            ready: { app in ChatsTransitions.element(app, "newtab.chat.cafe").waitForExistence(timeout: 60) },
            perform: { app in
                ChatsTransitions.element(app, "newtab.chat.cafe").tap()
                guard TransitionCatalog.wait(5, { ChatsTransitions.element(app, "chat.history").isHittable }) else { return }
                Thread.sleep(forTimeInterval: 0.7)
                let size = app.windows.firstMatch.frame.size
                let start = CGPoint(x: size.width / 2, y: size.height * 0.42)
                ChatsTransitions.drag(app, through: [
                    (start, 0),
                    (CGPoint(x: start.x, y: start.y + 150), 0.6),
                    (CGPoint(x: start.x, y: start.y + 150), 0.9),
                    (CGPoint(x: start.x, y: start.y - 10), 1.6),
                ])
                Thread.sleep(forTimeInterval: 0.8)
            },
            arrived: { app in
                TransitionCatalog.wait { ChatsTransitions.element(app, "chat.history").isHittable }
            }
        ),
        // A finger from the left edge takes a chat in the sheet (opened from
        // anywhere but its card) back to New Tab's Chats page, which comes
        // under it: handed to a cover, it zooms into its card as ‹ does.
        Transition(
            "chatEdgePop",
            signposts: [],
            state: "chat.3",
            ready: { app in ChatsTransitions.element(app, "chat.history").waitForExistence(timeout: 60)
                && TransitionCatalog.wait { ChatsTransitions.element(app, "chat.history").isHittable } },
            perform: { app in
                let window = app.windows.firstMatch
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: window.frame.width * 0.62, dy: 0)),
                            withVelocity: .slow, thenHoldForDuration: 0)
            },
            arrived: { app in
                TransitionCatalog.wait {
                    app.canTouch(app.chatsPageNewChat) && !ChatsTransitions.element(app, "chat.history").exists
                }
            }
        ),
        // Chat Info grows out of the face (UIKit's zoom) and a pull down
        // returns it into the face.
        Transition(
            "chatInfo",
            signposts: ["chatInfo"],
            state: "chat.3",
            ready: { app in ChatsTransitions.element(app, "chat.face").waitForExistence(timeout: 60)
                && TransitionCatalog.wait { ChatsTransitions.element(app, "chat.face").isHittable } },
            perform: { app in
                ChatsTransitions.element(app, "chat.face").tap()
                guard TransitionCatalog.wait(5, { ChatsTransitions.element(app, "chat.info").exists }) else { return }
                Thread.sleep(forTimeInterval: 0.8)
                let window = app.windows.firstMatch
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)),
                            withVelocity: .fast, thenHoldForDuration: 0)
            },
            arrived: { app in
                TransitionCatalog.wait {
                    !ChatsTransitions.element(app, "chat.info").exists
                        && ChatsTransitions.element(app, "chat.face").isHittable
                }
            }
        ),
        // Chat Info on a long chat (chat.long: 300 messages, work on 30
        // sites, files): the face tapped, Info zooms out of it, settles,
        // and ‹ zooms it back. Its film says whether the first frame waits.
        Transition(
            "chatInfoLong",
            signposts: ["chatInfo"],
            state: "chat.long",
            ready: { app in ChatsTransitions.element(app, "chat.face").waitForExistence(timeout: 60)
                && TransitionCatalog.wait { ChatsTransitions.element(app, "chat.face").isHittable } },
            perform: { app in
                ChatsTransitions.element(app, "chat.face").tap()
                guard TransitionCatalog.wait(5, { ChatsTransitions.element(app, "chat.info.back").isHittable }) else { return }
                Thread.sleep(forTimeInterval: 0.9)
                ChatsTransitions.element(app, "chat.info.back").tap()
            },
            arrived: { app in
                TransitionCatalog.wait {
                    !ChatsTransitions.element(app, "chat.info").exists
                        && ChatsTransitions.element(app, "chat.face").isHittable
                }
            },
            // It ends where it began: the perf test repeats it in one launch.
            undo: { _ in Thread.sleep(forTimeInterval: 0.5) }
        ),
        // Rename on the long chat's Info: the alert, words added, Rename;
        // the signpost is the commit's frames (ChatDetails).
        Transition(
            "chatInfoRename",
            signposts: ["chatRename"],
            state: "chat.info.long",
            ready: { app in TransitionCatalog.wait { ChatsTransitions.element(app, "chat.info.rename").isHittable } },
            perform: { app in
                ChatsTransitions.element(app, "chat.info.rename").tap()
                let alert = app.alerts["Rename Chat"]
                guard alert.waitForExistence(timeout: 5) else { return }
                alert.textFields.firstMatch.typeText(" 2")
                alert.buttons["Rename"].tap()
            },
            arrived: { app in
                TransitionCatalog.wait {
                    !app.alerts["Rename Chat"].exists && ChatsTransitions.element(app, "chat.info.title").label.hasSuffix("2")
                }
            },
            undo: { _ in Thread.sleep(forTimeInterval: 0.3) }
        ),
        Transition(
            "answerGrow",
            signposts: ["answerGrow", "questionFly"],
            state: "page.1",
            arguments: ["-YabTab", "work-figma-onb", "-YabOnDevice", "standin"],
            ready: { app in ChatsTransitions.warmFixture(app) },
            perform: { app in ChatsTransitions.go(app).tap() },
            arrived: { app in
                let question = app.descendants(matching: .any)["chat.question"]
                let answer = app.descendants(matching: .any)["chat.answer"]
                let head = app.descendants(matching: .any)["chat.answerHead"]
                guard head.waitForExistence(timeout: 5) else { return false }
                return TransitionCatalog.wait {
                    !app.textFields["field.input"].exists
                        && question.exists && question.isHittable && question.label == ChatsTransitions.question
                        && answer.exists && answer.isHittable
                        && app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Anna wants")).firstMatch.exists
                        && head.isHittable
                }
            }
        ),
    ]
}

private enum ChatsTransitions {
    static let question = "what does anna want?"

    /// One finger along a path, held the whole way (XCUICoordinate drags only
    /// in one straight line): the points in window points, each with the
    /// seconds from touch down when the finger is there; it lifts at the last.
    /// XCTest's own event path and synthesizer, found at run time; without
    /// them, one straight drag to the last point, held there.
    static func drag(_ app: XCUIApplication, through points: [(CGPoint, TimeInterval)]) {
        guard let first = points.first, let last = points.last else { return }
        if synthesize(points) { return }
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: first.0.x, dy: first.0.y))
        from.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: last.0.x, dy: last.0.y)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
    }

    private static func synthesize(_ points: [(CGPoint, TimeInterval)]) -> Bool {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
              let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let first = points.first, let last = points.last else { return false }
        typealias TouchDown = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias MakeRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Done = @convention(block) (Bool, NSError?) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, AnyObject, Done) -> Void
        let down = NSSelectorFromString("initForTouchAtPoint:offset:")
        let move = NSSelectorFromString("moveToPoint:atOffset:")
        let lift = NSSelectorFromString("liftUpAtOffset:")
        let makeRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
        let add = NSSelectorFromString("addPointerEventPath:")
        let synth = NSSelectorFromString("synthesizeEvent:completion:")
        guard pathClass.instancesRespond(to: down), pathClass.instancesRespond(to: move), pathClass.instancesRespond(to: lift),
              recordClass.instancesRespond(to: makeRecord), recordClass.instancesRespond(to: add) else { return false }
        let device = XCUIDevice.shared
        guard let synthesizer = (device.responds(to: NSSelectorFromString("eventSynthesizer"))
            ? device.value(forKey: "eventSynthesizer") as AnyObject? : nil),
              synthesizer.responds(to: synth) else { return false }
        let alloc = NSSelectorFromString("alloc")
        guard let blankPath = (pathClass as AnyObject).perform(alloc)?.takeUnretainedValue(),
              let blankRecord = (recordClass as AnyObject).perform(alloc)?.takeUnretainedValue() else { return false }
        let path = unsafeBitCast(class_getMethodImplementation(pathClass, down), to: TouchDown.self)(blankPath, down, first.0, first.1)
        for (point, at) in points.dropFirst() {
            unsafeBitCast(class_getMethodImplementation(pathClass, move), to: Move.self)(path, move, point, at)
        }
        unsafeBitCast(class_getMethodImplementation(pathClass, lift), to: Lift.self)(path, lift, last.1 + 0.02)
        // 1: portrait.
        let record = unsafeBitCast(class_getMethodImplementation(recordClass, makeRecord), to: MakeRecord.self)(
            blankRecord, makeRecord, "Yab drag" as NSString, 1)
        unsafeBitCast(class_getMethodImplementation(recordClass, add), to: Add.self)(record, add, path)
        var finished = false
        var worked = false
        let done: Done = { ok, _ in worked = ok; finished = true }
        unsafeBitCast(class_getMethodImplementation(object_getClass(synthesizer), synth), to: Synthesize.self)(synthesizer, synth, record, done)
        _ = TransitionCatalog.wait(last.1 + 5) { finished }
        return worked
    }

    static func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    static func go(_ app: XCUIApplication) -> XCUIElement {
        app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
    }

    /// Only Mira contains this page and reply. The stand-in is selected at
    /// launch, while all opening, typing and submission use native controls.
    static func warmFixture(_ app: XCUIApplication) -> Bool {
        guard Atlas.world == "mira" else { return false }
        let plate = app.descendants(matching: .any)["chrome.plate"]
        guard plate.waitForExistence(timeout: 60),
              plate.label.contains("Figma"), plate.label.contains("Onboarding") else { return false }
        plate.tap()
        let input = app.textFields["field.input"]
        guard input.waitForExistence(timeout: 5),
              app.keyboards.firstMatch.waitForExistence(timeout: 5) else { return false }
        input.typeText(question)
        let best = app.descendants(matching: .any)["field.best"]
        return TransitionCatalog.wait {
            (input.value as? String) == question
                && best.exists && best.label.contains(question) && best.label.contains("Ask Claude")
                && (best.value as? String) == "go"
                && go(app).exists && go(app).isHittable
                && !app.descendants(matching: .any)["chat.answerHead"].exists
        }
    }
}
