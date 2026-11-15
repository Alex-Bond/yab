import AppKit
import Testing
@testable import Fast

@MainActor
struct HeaderPressOwnershipTests {
    private func event(_ type: NSEvent.EventType, x: CGFloat = 100) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 380),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private final class HitPage: NSView, PageScriptTarget {
        var code: PageCode?
        var requestedWorld: PageWorld?
        var requestedGesture: Bool?
        var answer: Result<Any?, Error> = .success(false)
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                      done: (@MainActor (Result<Any?, Error>) -> Void)?) {
            code = script; requestedWorld = world; requestedGesture = gesture
            done?(answer)
        }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? {
            try answer.get()
        }
    }

    @Test func theCurrentNativeDownSuppliesTheExactZoomedHitPoint() throws {
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let page = HitPage(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        let down = try event(.leftMouseDown, x: 100.25)
        var sent: [NSEvent] = []
        let press = TopPress(down: down, forward: { sent.append($0) },
                             drag: { _ in Issue.record("The current target is a page control") }, finished: {})
        press.check(in: page, zoom: 2)
        if case .function(_, let arguments)? = page.code {
            #expect(arguments["x"] as? Double == 50.125)
            #expect(arguments["y"] as? Double == 10)
        } else { Issue.record("Expected the per-press DOM function") }
        #expect(page.requestedWorld == .yab && page.requestedGesture == false)
        #expect(sent.count == 1 && sent[0] === down)
    }

    @Test func anUnavailableHitTestCannotAuthorizeAWindowGesture() throws {
        enum Failed: Error { case documentGone }
        let page = HitPage(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        page.answer = .failure(Failed.documentGone)
        let down = try event(.leftMouseDown)
        var sent: [NSEvent] = [], finishes = 0
        let press = TopPress(down: down, forward: { sent.append($0) },
                             drag: { _ in Issue.record("An unavailable hit test cannot drag") }, finished: { finishes += 1 })
        press.check(in: page, zoom: 1)
        #expect(sent.count == 1 && sent[0] === down && finishes == 1)
    }

    @Test func aControlReplacingAHoveredGapGetsItsOriginalSequence() throws {
        let down = try event(.leftMouseDown), move = try event(.leftMouseDragged, x: 104)
        var sent: [NSEvent] = [], drags = 0, finishes = 0
        let press = TopPress(down: down, forward: { sent.append($0) },
                             drag: { _ in drags += 1 }, finished: { finishes += 1 })
        press.receive(move)
        #expect(sent.isEmpty)
        press.resolve(false)
        #expect(sent.count == 2 && sent[0] === down && sent[1] === move)
        #expect(drags == 0 && finishes == 1)
        press.resolve(true)
        #expect(drags == 0 && finishes == 1)
    }

    @Test func anEmptyHandleUsesTheNativeDragAndDoesNotClickThePage() throws {
        let down = try event(.leftMouseDown)
        var sent: [NSEvent] = [], dragged: [NSEvent] = [], finishes = 0
        let press = TopPress(down: down, forward: { sent.append($0) },
                             drag: { dragged.append($0) }, finished: { finishes += 1 })
        press.resolve(true)
        press.receive(try event(.leftMouseDragged, x: 102))
        #expect(dragged.isEmpty)
        press.receive(try event(.leftMouseDragged, x: 104))
        press.receive(try event(.leftMouseDragged, x: 110))
        press.receive(try event(.leftMouseUp, x: 110))
        #expect(dragged.count == 1 && dragged[0] === down)
        #expect(sent.isEmpty && finishes == 1)
    }

    @Test func aClickOnEmptyBackgroundKeepsItsOriginalDownAndUp() throws {
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        var sent: [NSEvent] = [], finishes = 0
        let press = TopPress(down: down, forward: { sent.append($0) },
                             drag: { _ in Issue.record("A click must not drag") }, finished: { finishes += 1 })
        press.resolve(true)
        press.receive(up)
        #expect(sent.count == 2 && sent[0] === down && sent[1] === up)
        #expect(finishes == 1)
    }

    @Test func aReleasedGestureIsForwardedInOrderEvenWhenTheHitAnswerArrivesLate() throws {
        for handle in [false, true] {
            let down = try event(.leftMouseDown), move = try event(.leftMouseDragged, x: 104), up = try event(.leftMouseUp, x: 104)
            var sent: [NSEvent] = [], finishes = 0
            let press = TopPress(down: down, forward: { sent.append($0) },
                                 drag: { _ in Issue.record("Cannot drag a released pointer") }, finished: { finishes += 1 })
            press.receive(move)
            press.receive(up)
            #expect(sent.isEmpty && finishes == 0)
            press.resolve(handle)
            #expect(sent.count == 3 && sent[0] === down && sent[1] === move && sent[2] === up)
            #expect(finishes == 1)
        }
    }
}
