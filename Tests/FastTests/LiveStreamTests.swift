import Foundation
import Testing
import SyncKit
@testable import Fast

// The live streams of the chats Yab runs: Codex's app server and
// `exec --json`, Claude Code's stream-json. Sample events in the shapes the
// CLIs write (codex 0.157 `app-server generate-ts`, claude 2.1's strings),
// no CLI at all.
@MainActor
struct LiveStreamTests {
    /// A server talking on thread T1.
    static func server() -> CodexServer {
        var id = 0
        let server = CodexServer { data in
            for line in data.split(separator: 0x0A) {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let n = object["id"] as? Int { id = n }
            }
        }
        server.open(thread: nil, fork: nil, instructions: "", cwd: "/room")
        _ = server.heard(["id": id, "result": [:]])
        _ = server.heard(["id": id, "result": ["thread": ["id": "T1"]]])
        return server
    }

    static func note(_ server: CodexServer, _ method: String, _ params: [String: Any]) -> [CodexServer.Heard] {
        var params = params
        if params["threadId"] == nil { params["threadId"] = "T1" }
        return server.heard(["method": method, "params": params])
    }

    static func session(_ cli: String) -> Agents.Session {
        let session = Agents.Session(id: "live-" + UUID().uuidString.prefix(6), cli: cli, name: cli, prompt: "", state: .running)
        // Nobody to tell, and a turn still to come: nothing ends by itself.
        session.quiet = true
        session.unread = 1
        session.items = [ChatItem(id: "q1", kind: .asked, text: "Fix it", state: .done)]
        return session
    }

    // MARK: Codex's server

    @Test func planUpdatedIsAChecklist() {
        let server = Self.server()
        let heard = Self.note(server, "turn/plan/updated", ["turnId": "u1", "explanation": NSNull(), "plan": [
            ["step": "Read the schema", "status": "completed"],
            ["step": "Add the payout table", "status": "inProgress"],
            ["step": "Run the tests", "status": "pending"],
        ]])
        guard case .checklist(let turn, let text) = heard.first else { Issue.record("no checklist"); return }
        #expect(turn == "u1")
        #expect(text == "[x] Read the schema\n[>] Add the payout table\n[ ] Run the tests")
        // As TodoWrite's: the field's plan reads it.
        let session = Self.session("codex")
        Agents.shared.hear(heard, on: session)
        let chat = Chat(id: "c", title: "", began: .other, cli: "codex", items: session.items, state: "running", answer: "", started: Date(), updated: Date())
        #expect(ChatPlan.steps(chat)?.map(\.text) == ["Read the schema", "Add the payout table", "Run the tests"])
        #expect(ChatPlan.steps(chat)?[1].now == true)
    }

    @Test func deltasGrowTheirSteps() {
        let server = Self.server()
        let session = Self.session("codex")
        let run: [String: Any] = ["type": "commandExecution", "id": "c1", "command": "swift test", "status": "inProgress",
                                  "commandActions": [["type": "unknown", "command": "swift test"]], "aggregatedOutput": NSNull()]
        Agents.shared.hear(Self.note(server, "item/started", ["turnId": "u1", "item": run]), on: session)
        Agents.shared.hear(Self.note(server, "item/commandExecution/outputDelta", ["turnId": "u1", "itemId": "c1", "delta": "Building\n"]), on: session)
        Agents.shared.hear(Self.note(server, "item/commandExecution/outputDelta", ["turnId": "u1", "itemId": "c1", "delta": "Testing\n"]), on: session)
        #expect(session.items.last { $0.id == "c1" }?.text == "Building\nTesting\n")
        #expect(session.items.last { $0.id == "c1" }?.state == .running)

        Agents.shared.hear(Self.note(server, "item/reasoning/summaryTextDelta", ["turnId": "u1", "itemId": "r1", "delta": "**Looking** at", "summaryIndex": 0]), on: session)
        Agents.shared.hear(Self.note(server, "item/reasoning/summaryTextDelta", ["turnId": "u1", "itemId": "r1", "delta": " the tests", "summaryIndex": 0]), on: session)
        Agents.shared.hear(Self.note(server, "item/reasoning/summaryPartAdded", ["turnId": "u1", "itemId": "r1", "summaryIndex": 1]), on: session)
        Agents.shared.hear(Self.note(server, "item/reasoning/summaryTextDelta", ["turnId": "u1", "itemId": "r1", "delta": "Then", "summaryIndex": 1]), on: session)
        let thought = session.items.last { $0.id == "r1" }
        #expect(thought?.kind == .thinking)
        #expect(thought?.text == "**Looking** at the tests\n\nThen")
        // The live line says its gist while it thinks.
        #expect(ChatLive.words(session.items, shown: ChatLive.Shown(step: nil, since: Date())) == "Looking at the tests")

        Agents.shared.hear(Self.note(server, "item/plan/delta", ["turnId": "u1", "itemId": "p1", "delta": "1. Read\n"]), on: session)
        #expect(session.items.last { $0.id == "p1" }?.kind == .plan)

        // Its end says how it went, and keeps what it printed.
        var done = run
        done["status"] = "completed"
        done["exitCode"] = 0
        done["durationMs"] = 1200
        Agents.shared.hear(Self.note(server, "item/completed", ["turnId": "u1", "item": done]), on: session)
        let ran = session.items.last { $0.id == "c1" }
        #expect(ran?.state == .done && ran?.text == "Building\nTesting\n")
        #expect(ran?.extra?["exit"] == "0" && ran?.extra?["ms"] == "1200")
    }

    @Test func threadWordsGoOnTheSession() {
        let server = Self.server()
        let session = Self.session("codex")
        Agents.shared.hear(Self.note(server, "thread/name/updated", ["threadName": "Payout table"]), on: session)
        #expect(session.title == "Payout table")
        Agents.shared.hear(Self.note(server, "thread/tokenUsage/updated", ["turnId": "u1", "tokenUsage": [
            "total": ["totalTokens": 90_000, "inputTokens": 80_000, "cachedInputTokens": 60_000, "cacheWriteInputTokens": 0, "outputTokens": 10_000, "reasoningOutputTokens": 2_000],
            "last": ["totalTokens": 41_000, "inputTokens": 40_000, "cachedInputTokens": 30_000, "cacheWriteInputTokens": 0, "outputTokens": 1_000, "reasoningOutputTokens": 200],
            "modelContextWindow": 272_000]]), on: session)
        #expect(session.contextUsed == 41_000 && session.contextWindow == 272_000 && session.tokensUsed == 90_000)
        Agents.shared.hear(Self.note(server, "turn/diff/updated", ["turnId": "u1", "diff": "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"]), on: session)
        #expect(session.turnDiff?.hasPrefix("--- a/x") == true)
        Agents.shared.hear(Self.note(server, "item/mcpToolCall/progress", ["turnId": "u1", "itemId": "m1", "message": "Reading 3 of 10"]), on: session)
        #expect(session.now == "Reading 3 of 10")
        // Another thread's (a subagent's) is not this chat's.
        #expect(Self.note(server, "thread/name/updated", ["threadId": "T2", "threadName": "Other"]).isEmpty)
    }

    @Test func noticesAreQuietLines() {
        let server = Self.server()
        let session = Self.session("codex")
        for (method, params) in [
            ("model/rerouted", ["turnId": "u1", "fromModel": "gpt-5.5", "toModel": "gpt-5.5-mini", "reason": "highRiskCyberActivity"]),
            ("warning", ["threadId": NSNull(), "message": "Your plan is almost out of room"]),
            ("configWarning", ["summary": "Unknown key in config.toml", "details": NSNull()]),
            ("deprecationNotice", ["summary": "The shell tool is going away", "details": NSNull()]),
        ] as [(String, [String: Any])] {
            Agents.shared.hear(server.heard(["method": method, "params": params]), on: session)
        }
        let notices = session.items.filter(\.isAside).map(\.text)
        // Codex on its own config and API goes to the log, not the chat.
        #expect(notices == ["Switched to gpt-5.5-mini from gpt-5.5 for this turn", "Your plan is almost out of room"])
        // Said once, and never the answer.
        Agents.shared.hear(server.heard(["method": "warning", "params": ["message": "Your plan is almost out of room"]]), on: session)
        #expect(session.items.filter(\.isAside).count == 2)
        #expect(session.result.isEmpty)
        let chat = Chat(id: "c", title: "", began: .other, cli: "codex", items: session.items, state: "running", answer: "", started: Date(), updated: Date())
        #expect(!chat.items.contains { Chat.visibleMessage($0, failed: false, failure: "") })
    }

    @Test func editsCarryTheirDiffs() {
        let server = Self.server()
        let item: [String: Any] = ["type": "fileChange", "id": "e1", "status": "completed", "changes": [
            ["path": "/repo/src/stripe.ts", "kind": ["type": "update", "move_path": NSNull()],
             "diff": "@@ -1,3 +1,4 @@\n a\n-b\n+c\n+d\n e\n"],
            ["path": "/repo/src/payout.ts", "kind": ["type": "add"], "diff": "one\ntwo\nthree\n"],
        ]]
        let heard = Self.note(server, "item/completed", ["turnId": "u1", "item": item])
        let edits = heard.compactMap { heard -> ChatItem? in if case .completed(let step) = heard { return step } else { return nil } }
        #expect(edits.count == 2)
        #expect(edits[0].id == "e1:/repo/src/stripe.ts" && edits[0].detail == "stripe.ts")
        #expect(edits[0].extra?["added"] == "2" && edits[0].extra?["removed"] == "1" && edits[0].extra?["diff"] == "1")
        #expect(edits[1].extra?["added"] == "3" && edits[1].extra?["new"] == "1" && edits[1].text == "+one\n+two\n+three")
    }

    @Test func commandsSayWhatTheyDid() {
        let read = ChatItem.codexSteps(["type": "commandExecution", "id": "c1", "command": "sed -n 1,80p ChatItem.swift", "status": "completed",
                                        "commandActions": [["type": "read", "command": "sed", "name": "ChatItem.swift", "path": "/r/Sources/ChatItem.swift"]],
                                        "exitCode": 0, "durationMs": 12], done: true)[0]
        #expect(read.kind == .tool && read.name == "Read" && read.detail == "ChatItem.swift")
        #expect(StepWords.of(read).line(.done) == "Read ChatItem.swift")
        let looked = ChatItem.codexSteps(["type": "commandExecution", "id": "c2", "command": "rg -n codex && ls Sources", "status": "completed",
                                          "commandActions": [["type": "search", "command": "rg", "query": "codex", "path": NSNull()],
                                                             ["type": "listFiles", "command": "ls", "path": "Sources"]],
                                          "exitCode": 0], done: true)[0]
        #expect(looked.name == "explore")
        #expect(StepWords.of(looked).line(.done) == "Explored: \u{201C}codex\u{201D}, Sources")
        let failed = ChatItem.codexSteps(["type": "commandExecution", "id": "c3", "command": "swift build", "status": "completed",
                                          "commandActions": [["type": "unknown", "command": "swift build"]],
                                          "aggregatedOutput": "error: no", "exitCode": 1], done: true)[0]
        #expect(failed.kind == .command && failed.state == .failed && failed.text == "error: no" && failed.extra?["exit"] == "1")
        let declined = ChatItem.codexSteps(["type": "commandExecution", "id": "c4", "command": "rm -rf x", "status": "declined",
                                            "commandActions": [], "exitCode": NSNull()], done: true)[0]
        #expect(declined.state == .failed && declined.extra == nil)
    }

    @Test func searchesPicturesAndMarkers() {
        let search = ChatItem.codexSteps(["type": "webSearch", "id": "w1", "query": "stripe payouts",
                                          "action": ["type": "search", "query": "stripe payouts", "queries": NSNull()],
                                          "results": [["url": "https://docs.stripe.com/payouts", "title": "Payouts"]]], done: true)[0]
        #expect(search.name == "web_search" && search.detail == "\u{201C}stripe payouts\u{201D}")
        #expect(search.extra?["sources"] == "https://docs.stripe.com/payouts")
        let page = ChatItem.codexSteps(["type": "webSearch", "id": "w2", "query": "",
                                        "action": ["type": "openPage", "url": "https://docs.stripe.com/api"], "results": NSNull()], done: true)[0]
        #expect(page.name == "WebFetch" && page.detail == "docs.stripe.com")

        let viewed = ChatItem.codexSteps(["type": "imageView", "id": "i1", "path": "/tmp/shot.png"], done: true)[0]
        #expect(viewed.name == "view_image" && viewed.extra?["image"] == "/tmp/shot.png")
        let made = ChatItem.codexSteps(["type": "imageGeneration", "id": "g1", "status": "completed", "revisedPrompt": "A violet dot",
                                        "result": "", "failure": NSNull(), "savedPath": "/tmp/dot.png"], done: true)[0]
        #expect(made.name == "image_gen" && made.state == .done && made.extra?["image"] == "/tmp/dot.png")
        #expect(StepWords.of(made).line(.done) == "Made an image \u{201C}A violet dot\u{201D}")

        let compacting = ChatItem.codexSteps(["type": "contextCompaction", "id": "k1"], done: false)[0]
        #expect(compacting.kind == .tool && StepWords.of(compacting).quiet)
        let compacted = ChatItem.codexSteps(["type": "contextCompaction", "id": "k1"], done: true)[0]
        #expect(compacted.isAside && compacted.name == "compacted")
        #expect(ChatItem.codexSteps(["type": "enteredReviewMode", "id": "v1", "review": "the current changes"], done: true)[0].text == "Reviewing the current changes")
        #expect(ChatItem.codexSteps(["type": "exitedReviewMode", "id": "v2", "review": "Looks fine"], done: true)[0].isAside)
        for quiet in [["type": "hookPrompt", "id": "h1", "fragments": []], ["type": "sleep", "id": "s1", "durationMs": 5000]] as [[String: Any]] {
            let step = ChatItem.codexSteps(quiet, done: true)[0]
            #expect(StepWords.of(step).quiet)
        }
    }

    @Test func execTurnSaysItsUsage() {
        let session = Self.session("codex")
        Agents.shared.hear(["type": "turn.completed", "usage": ["input_tokens": 1200, "cached_input_tokens": 800, "output_tokens": 300]], on: session)
        #expect(session.tokensUsed == 1500)
    }

    // MARK: Claude Code's stream-json

    @Test func retriesSayWhyAndWhichTry() {
        let session = Self.session("claude")
        Agents.shared.hear(["type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 10, "retry_delay_ms": 500,
                            "error_status": 529, "error": "overloaded", "session_id": "S"], on: session)
        Agents.shared.hear(["type": "system", "subtype": "api_retry", "attempt": 2, "max_retries": 10, "retry_delay_ms": 1000,
                            "error_status": 529, "error": "overloaded", "session_id": "S"], on: session)
        let retry = session.items.filter { $0.name == "retry" }
        #expect(retry.count == 1)
        #expect(StepWords.of(retry[0]).line(.running) == "Retrying, Anthropic is busy (2 of 10)")
        #expect(session.now == "Retrying, Anthropic is busy (2 of 10)")
        // Words at last: the retry is over.
        Agents.shared.hear(["type": "assistant", "message": ["id": "m1", "content": [["type": "text", "text": "Fixed."]]]], on: session)
        #expect(session.items.first { $0.name == "retry" }?.state == .done)
        #expect(Agents.retryWords(["error": "server_error", "error_status": 500, "attempt": 3, "max_retries": 10]) == "Anthropic had a server error (3 of 10)")
        #expect(Agents.retryWords(["error": "unknown", "error_status": NSNull(), "attempt": 1, "max_retries": 10,
                                   "no_response": ["waited_ms": 60_000]]) == "no answer from Anthropic (1 of 10)")
    }

    @Test func compactionIsADivider() {
        let session = Self.session("claude")
        Agents.shared.hear(["type": "system", "subtype": "status", "status": "compacting"], on: session)
        #expect(session.items.last?.name == "compact" && session.items.last?.state == .running)
        Agents.shared.hear(["type": "system", "subtype": "compact_boundary", "uuid": "b1",
                            "compact_metadata": ["trigger": "auto", "pre_tokens": 160_000]], on: session)
        Agents.shared.hear(["type": "system", "subtype": "status", "status": NSNull()], on: session)
        #expect(session.items.first { $0.name == "compact" }?.state == .done)
        #expect(session.items.last?.isAside == true && session.items.last?.name == "compacted")
    }

    @Test func deniedStepsSaySo() {
        let session = Self.session("claude")
        Agents.shared.hear(["type": "assistant", "message": ["id": "m1", "content": [
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "rm -rf build"]],
            ["type": "tool_use", "id": "t2", "name": "mcp__linear__create_issue", "input": ["title": "x"]],
        ]]], on: session)
        Agents.shared.hear(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "Permission to use Bash has been denied."],
        ]]], on: session)
        Agents.shared.hear(["type": "assistant", "message": ["id": "m2", "content": [["type": "text", "text": "I couldn't delete it."]]]], on: session)
        Agents.shared.hear(["type": "result", "subtype": "success", "is_error": false, "result": "I couldn't delete it.",
                            "num_turns": 3, "total_cost_usd": 0.042, "terminal_reason": "completed", "session_id": "S",
                            "permission_denials": [["tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": "rm -rf build"]],
                                                   ["tool_name": "mcp__linear__create_issue", "tool_use_id": "t2", "tool_input": [:]]]], on: session)
        #expect(session.items.first { $0.id == "t1" }?.state == .failed)
        #expect(session.items.first { $0.id == "t1" }?.text == "Not allowed: Bash")
        #expect(session.items.first { $0.id == "t2" }?.text == "Not allowed: create_issue")
        #expect(session.items.last { $0.isAside }?.text == "Not allowed: Bash and create_issue")
        #expect(session.turnsTaken == 3 && session.cost == 0.042 && session.ending == "completed")
        // The answer is still its words.
        #expect(session.result == "I couldn't delete it.")
        #expect(session.state == .running)
    }

    @Test func apiErrorsFailTheTurn() {
        for error in ["authentication_failed", "server_error", "overloaded", "invalid_request"] {
            let session = Self.session("claude")
            let words = "API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"
            Agents.shared.hear(["type": "assistant", "error": error, "message": ["id": "m1", "content": [["type": "text", "text": words]]]], on: session)
            #expect(session.apiError == error)
            #expect(session.items.last?.isAside == true && session.items.last?.name == "error")
            // Not an answer.
            #expect(!session.items.contains { Chat.visibleMessage($0, failed: false, failure: "") })
            Agents.shared.hear(["type": "result", "subtype": "success", "is_error": false, "result": words, "session_id": "S"], on: session)
            #expect(session.state == .failed)
            #expect(session.result == words)
            #expect(session.apiError == nil)
        }
        // A plan's limit has its own way (another account), not this one.
        #expect(!Agents.failing.contains("rate_limit"))
    }
}
