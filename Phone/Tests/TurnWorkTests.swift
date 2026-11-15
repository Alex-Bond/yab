import SyncKit
import XCTest
@testable import YabPhone

/// What a Mac chat's turns did, as the iPhone reads it from synced items:
/// turns, the steps a list shows, repeats folded, how long, and the words
/// for a turn done, stopped or failed (TurnWork, StepWords).
@MainActor
final class TurnWorkTests: XCTestCase {
    private let t0 = 1_759_700_000.0

    private func head(_ state: String, answer: String = "", id: String = "a:w") throws -> SyncChat {
        try XCTUnwrap(SyncChat(Record(collection: "chat", id: id, fields: [
            "device": "mac-a", "title": "Work", "state": .string(state), "answer": .string(answer), "cli": "claude",
            "started": .number(t0), "updated": .number(t0 + 300),
        ])))
    }

    private var n = 0
    private func item(_ kind: String, _ name: String = "", _ detail: String = "", text: String = "", state: String = "done",
                      at: Double, to: Double? = nil, chat: String = "a:w") throws -> SyncChatItem {
        n += 1
        var fields: [String: Value] = ["chat": .string(chat), "n": .number(Double(n)), "kind": .string(kind), "name": .string(name),
                                       "detail": .string(detail), "text": .string(text), "state": .string(state), "began": .number(t0 + at)]
        if let to { fields["ended"] = .number(t0 + to) }
        return try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "\(chat)/\(n)", fields: fields)))
    }

    func testEachQuestionBeginsATurnAndItsWorkStaysInIt() throws {
        let items = [
            try item("asked", text: "Find a café", at: 0),
            try item("tool", "open", "timeout.com", at: 2, to: 10),
            try item("tool", "memory_search", at: 11, to: 12),
            try item("message", text: "Café da Garagem.", at: 40, to: 42),
            try item("asked", "steer", text: "With wifi", at: 5),
            try item("asked", text: "And for dinner?", at: 100),
            try item("tool", "WebSearch", "\u{201C}dinner Alfama\u{201D}", at: 101, to: 104),
            try item("tool", "WebSearch", "\u{201C}dinner Alfama\u{201D}", at: 105, to: 108),
            try item("message", text: "Taberna Sal Grosso.", at: 130, to: 131),
        ]
        XCTAssertEqual(TurnWork.turns(items).map(\.count), [5, 4], "words steered into a turn stay in it")
        let chat = SyncMapping.chat(try head("done"), items: items, sends: [], macAsleep: false, old: nil)
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer, .you, .you, .answer])
        let first = try XCTUnwrap(chat.messages[1].work)
        XCTAssertEqual(first.kind, .actions)
        XCTAssertEqual(first.steps.map(\.name), ["open"], "Yab's bookkeeping never gets a row")
        XCTAssertEqual(first.words, "Worked for 42s")
        XCTAssertEqual(first.question, "Find a café")
        XCTAssertEqual(first.text, "Café da Garagem.")
        XCTAssertEqual(first.at, Date(timeIntervalSince1970: t0 + 42))
        XCTAssertEqual(TurnWork.hosts(first.steps), ["timeout.com"])
        let read = TurnWork.Step(id: "r", kind: "tool", name: "Read", detail: "Package.swift", state: "done")
        XCTAssertEqual(TurnWork.hosts([read]), [], "a file is not a site")
        let second = try XCTUnwrap(chat.messages[4].work)
        XCTAssertEqual(second.steps.count, 2)
        XCTAssertEqual(TurnWork.runs(second.steps).map(\.count), [2], "the same search twice is one row")
        XCTAssertEqual(second.summary, "Worked for 31s \u{00B7} 2 steps")
        // While the chat runs, nothing to ask again.
        let live = SyncMapping.chat(try head("running"), items: Array(items.prefix(4)), sends: [], macAsleep: false, old: nil, now: Date(timeIntervalSince1970: t0 + 400))
        XCTAssertEqual(live.messages.map(\.role), [.you, .answer, .typing])
        XCTAssertNil(live.messages[1].work, "steps are never shown while a turn works")
    }

    func testRepeatsFoldOnlyWhileTheyStayAlike() {
        func step(_ name: String, _ detail: String, _ state: String = "done") -> TurnWork.Step {
            TurnWork.Step(id: UUID().uuidString, kind: "tool", name: name, detail: detail, state: state)
        }
        let runs = TurnWork.runs([step("Read", "a.swift"), step("Read", "a.swift"), step("Read", "a.swift"), step("Read", "b.swift"),
                                  step("Read", "b.swift", "failed"), step("Read", "b.swift", "failed")])
        XCTAssertEqual(runs.map(\.count), [3, 1, 2])
    }

    func testHowLongATurnWorkedLessTheTimeItWaitedOnYou() throws {
        XCTAssertEqual(TurnWork.span(0.4), "1s")
        XCTAssertEqual(TurnWork.span(40), "40s")
        XCTAssertEqual(TurnWork.span(72), "1m 12s")
        XCTAssertEqual(TurnWork.span(120), "2m")
        XCTAssertEqual(TurnWork.span(3780), "1h 3m")
        let turn = [
            try item("asked", text: "Book it", at: 0),
            try item("tool", "ask", "Which day?", at: 10, to: 70),
            try item("tool", "click", "\u{201C}Book\u{201D}", at: 71, to: 75),
        ]
        XCTAssertEqual(TurnWork.worked(turn), 15, "a minute waiting on you isn't work")
        XCTAssertNil(TurnWork.worked([try item("asked", text: "x", at: 0)]))
        XCTAssertEqual(TurnWork.doneWords("done", seconds: nil), "Done")
        XCTAssertEqual(TurnWork.doneWords("stopped", seconds: nil), "You stopped it")
        XCTAssertEqual(TurnWork.doneWords("failed", seconds: 130), "Couldn\u{2019}t finish after 2m 10s")
        let command = TurnWork.Step(id: "c", kind: "command", name: "command", detail: "swift build", state: "done",
                                    began: Date(timeIntervalSince1970: 0), ended: Date(timeIntervalSince1970: 48))
        XCTAssertEqual(TurnWork.took(command), "48s")
        var quick = command
        quick.ended = Date(timeIntervalSince1970: 1)
        XCTAssertNil(TurnWork.took(quick), "under two seconds says nothing")
    }

    func testAStoppedTurnSaysSoAndItsStepLeftGoingWasStopped() throws {
        let items = [
            try item("asked", text: "Book a table", at: 0),
            try item("tool", "open", "timeout.com", at: 2, to: 9),
            try item("tool", "click", "\u{201C}Reserve\u{201D}", state: "running", at: 20),
            try item("message", "stopped", at: 38),
        ]
        let chat = SyncMapping.chat(try head("done"), items: items, sends: [], macAsleep: false, old: nil)
        // Said in a note, its steps never shown.
        XCTAssertEqual(chat.messages.map(\.role), [.you, .note])
        XCTAssertEqual(chat.messages[1].text, "You stopped after 38s")
        XCTAssertEqual(TurnWork.steps(items, ending: "stopped").map(\.state), ["done", "stopped"])
        XCTAssertEqual(StepWords.of(TurnWork.steps(items, ending: "stopped")[1]).verb("stopped"), "Clicking")
    }

    func testAFailedTurnSaysWhyOnceAndOffersItAgain() throws {
        let error = #"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let items = [
            try item("asked", text: "Summarize the pull requests", at: 0),
            try item("command", "command", "gh pr list", text: "Fetching\nerror: HTTP 401: Bad credentials\nTry gh auth login", state: "failed", at: 2, to: 5),
            try item("tool", "open", "github.com", state: "running", at: 6),
            try item("message", text: error, state: "failed", at: 40),
            try item("message", "error", text: error, at: 41),
        ]
        let chat = SyncMapping.chat(try head("failed", answer: error), items: items, sends: [], macAsleep: false, old: nil)
        XCTAssertEqual(chat.messages.map(\.role), [.you, .work], "the error is the failure's, never an answer or a note; no line of steps")
        let failure = try XCTUnwrap(chat.messages[1].work)
        XCTAssertEqual(failure.kind, .failure)
        XCTAssertEqual(failure.title, "Claude\u{2019}s server failed partway.")
        XCTAssertEqual(failure.question, "Summarize the pull requests")
        let worked = failure
        XCTAssertEqual(worked.steps.map(\.state), ["failed", "failed"], "a step going when it failed didn't get done")
        XCTAssertEqual(worked.failedCount, 2)
        XCTAssertEqual(TurnWork.why(worked.steps[0]), "error: HTTP 401: Bad credentials")
        // Failed with no items kept: still said why.
        let bare = SyncMapping.chat(try head("failed", answer: "connection reset"), items: [], sends: [], macAsleep: false, old: nil)
        XCTAssertEqual(bare.messages.last?.work?.title, "The connection dropped partway.")
        XCTAssertEqual(ChatProblem("", agent: "ChatGPT").title, "ChatGPT stopped before it finished.")
    }

    func testARunningTurnShowsItsSubagentsOverTheDots() throws {
        let items = [
            try item("asked", text: "Compare flights", at: 0),
            try item("subagent", "spawnAgent", "Check TAP fares", state: "running", at: 10),
            try item("subagent", "spawnAgent", "Check Ryanair fares", at: 11, to: 30),
            try item("subagent", "wait", state: "running", at: 31),
        ]
        let chat = SyncMapping.chat(try head("running"), items: items, sends: [], macAsleep: false, old: nil, now: Date(timeIntervalSince1970: t0 + 400))
        XCTAssertEqual(chat.messages.map(\.role), [.you, .work, .typing])
        let live = try XCTUnwrap(chat.messages[1].work)
        XCTAssertEqual(live.kind, .subagents)
        XCTAssertEqual(live.subagents.map(\.name), ["Check TAP fares"])
        XCTAssertEqual(live.subagents.first?.since, Date(timeIntervalSince1970: t0 + 10))
    }

    func testThoughtsFoldAndReportsAreCards() throws {
        let report = "Subagent Euler (s1) is done (done, sonnet, 3/3 completed).\n\nThe log fails on SyncKit.\nNothing else is new."
        let items = [
            try item("asked", text: "Why does CI fail?", at: 0),
            try item("thinking", "thought", text: "Clean checkout.", at: 1, to: 6),
            try item("thinking", "thought", text: "Submodules.", at: 7, to: 10),
            try item("thinking", text: "live stream thinking", at: 11, to: 12),
            try item("message", "compacted", at: 13),
            try item("message", text: "Add submodules.", at: 20, to: 21),
            try item("asked", text: report, at: 30),
            try item("message", text: "(quiet)", at: 31),
        ]
        let chat = SyncMapping.chat(try head("done"), items: items, sends: [], macAsleep: false, old: nil)
        XCTAssertEqual(chat.messages.map(\.role), [.you, .work, .note, .answer, .work])
        XCTAssertEqual(chat.messages[1].work?.words, "Thought for 8s")
        XCTAssertEqual(chat.messages[1].work?.text, "Clean checkout.\n\nSubmodules.")
        XCTAssertEqual(chat.messages[2].text, "Context compacted")
        let card = try XCTUnwrap(chat.messages[4].work)
        XCTAssertEqual(card.kind, .report)
        XCTAssertEqual(card.title, "Euler")
        XCTAssertEqual(card.detail, "The log fails on SyncKit.")
        XCTAssertEqual(card.text, "The log fails on SyncKit.\nNothing else is new.")
    }

    func testStepsReadAsTheMacSaysThem() {
        let open = StepWords.tool("open", detail: "www.timeout.com")
        XCTAssertEqual(open.line("done"), "Opened timeout.com")
        XCTAssertEqual(open.site, "timeout.com")
        XCTAssertEqual(StepWords.tool("WebSearch", detail: "").line("done"), "Searched the web")
        XCTAssertEqual(StepWords.tool("linear/create_issue", detail: "").line("done"), "Created an issue in Linear")
        XCTAssertEqual(StepWords.tool("linear/create_issue", detail: "").site, "linear.app")
        XCTAssertEqual(StepWords.tool("fancy_tool", detail: "").line("failed"), "Couldn\u{2019}t use fancy tool")
        XCTAssertEqual(StepWords.tool("open", detail: "a.com, b.com, c.com").object, "a.com and 2 more")
        XCTAssertEqual(StepWords.tool("snapshot", detail: "tab:ab12").line("done"), "Read", "a Mac's tab id names nothing here")
        XCTAssertTrue(StepWords.tool("memory_search", detail: "").quiet)
        XCTAssertEqual(StepWords.of(kind: "command", name: "command", detail: "/bin/zsh -lc 'swift build'", text: "").object, "swift build")
        XCTAssertEqual(StepWords.of(kind: "subagent", name: "spawnAgent", detail: "Check fares", text: "").line("done"), "Started a subagent Check fares")
        XCTAssertEqual(StepWords.of(kind: "subagent", name: "spawnAgent", detail: "", text: "").art, .robot)
    }

    func testEveryMarkDraws() {
        for art in StepArt.allCases {
            XCTAssertFalse(art.strokes.isEmpty, art.rawValue)
            XCTAssertEqual(art.image.size, CGSize(width: 24, height: 24), art.rawValue)
        }
    }

    func testMessagesKeepTheirWorkAndOldOnesStillRead() throws {
        let work = TurnWork(kind: .actions, id: "t", words: "Worked for 3s",
                            steps: [TurnWork.Step(id: "s", kind: "tool", name: "open", detail: "a.com", state: "done")], text: "Hi")
        let message = Message(role: .answer, text: "Hi", by: .claude, work: work)
        let back = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(back, message)
        let old = try JSONDecoder().decode(Message.self, from: Data(#"{"role":"answer","text":"Hi"}"#.utf8))
        XCTAssertNil(old.work)
        let sparse = try JSONDecoder().decode(TurnWork.self, from: Data(#"{"kind":"worked"}"#.utf8))
        XCTAssertEqual(sparse.kind, .worked)
        XCTAssertTrue(sparse.steps.isEmpty)
    }
}
