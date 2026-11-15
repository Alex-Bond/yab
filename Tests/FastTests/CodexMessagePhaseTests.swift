import Foundation
import Testing
@testable import Fast

/// Value events and existing normalization only, no CLI or agent session.
@MainActor
struct CodexMessagePhaseTests {
    @Test func rawPhasesKeepEveryWordAndRoundTrip() throws {
        for phase in ["commentary", "final_answer", "partial_answer", "future_phase"] {
            let raw: [String: Any] = ["type": "agentMessage", "id": "m", "text": "I will check. Final words stay.", "phase": phase]
            let item = try #require(ChatItem.codex(raw, done: true))
            #expect(item.kind == .message && item.state == .done)
            #expect(item.text == "I will check. Final words stay.")
            #expect(item.extra?["codexPhase"] == phase)
            let stored = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
            #expect(stored == item)
        }
    }

    @Test func absentNullAndLegacyMessagesStayUnclassified() throws {
        let phases: [Any?] = [nil, NSNull()]
        for phase in phases {
            var raw: [String: Any] = ["type": "agentMessage", "id": "m", "text": "I will check."]
            if let phase { raw["phase"] = phase }
            let item = try #require(ChatItem.codex(raw, done: true))
            #expect(item == ChatItem(id: "m", kind: .message, text: "I will check.", state: .done))
        }
        let legacy = try #require(ChatItem.codexExec(["type": "agent_message", "id": "old", "text": "Answer"], done: true))
        #expect(legacy == ChatItem(id: "old", kind: .message, text: "Answer", state: .done))
    }

    @Test func deltasInheritItemMetadataAndCompletionIsAuthoritative() throws {
        let server = CodexServer { _ in }
        func event(_ method: String, _ item: [String: Any]) -> [CodexServer.Heard] {
            server.heard(["method": method, "params": ["item": item]])
        }
        let raw: [String: Any] = ["type": "agentMessage", "id": "m", "text": "", "phase": "commentary"]
        guard case .started(let start, _) = event("item/started", raw).first else {
            Issue.record("missing started item"); return
        }
        var items: [ChatItem] = []
        items.put(start)
        let delta = server.heard(["method": "item/agentMessage/delta", "params": ["itemId": "m", "delta": "Visible words"]])
        guard case .delta(let id, let words) = delta.first else { Issue.record("missing delta"); return }
        items.grow(id, by: words)
        #expect(items.count == 1 && items[0].text == "Visible words")
        #expect(items[0].extra?["codexPhase"] == "commentary")
        guard case .completed(let final) = event("item/completed", ["type": "agentMessage", "id": "m", "text": "Complete answer", "phase": "final_answer"]).first else {
            Issue.record("missing completed item"); return
        }
        items.put(final)
        #expect(items.count == 1 && items[0].text == "Complete answer")
        #expect(items[0].extra?["codexPhase"] == "final_answer")
        guard case .completed(let unknown) = event("item/completed", ["type": "agentMessage", "id": "m", "text": "Authoritative unknown", "phase": NSNull()]).first else {
            Issue.record("missing unknown completion"); return
        }
        items.put(unknown)
        #expect(items[0].text == "Authoritative unknown" && items[0].extra?["codexPhase"] == nil)
        let restored = try JSONDecoder().decode([ChatItem].self, from: JSONEncoder().encode(items))
        #expect(restored == items)
    }

    @Test func otherItemKindsAndApprovalRepliesAreUnchanged() throws {
        let thinking = try #require(ChatItem.codex(["type": "reasoning", "id": "r", "summary": ["Visible summary"], "phase": "commentary"], done: true))
        #expect(thinking.kind == .thinking && thinking.text == "Visible summary" && thinking.extra == nil)
        let tool = try #require(ChatItem.codex(["type": "mcpToolCall", "id": "t", "server": "yab-browser", "tool": "open", "arguments": ["url": "https://fixture.invalid"], "phase": "commentary"], done: false))
        #expect(tool.kind == .tool && tool.name == "open" && tool.extra == nil)
        var replies: [[String: Any]] = []
        let server = CodexServer { data in
            if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { replies.append(reply) }
        }
        #expect(server.heard(["id": 1, "method": "item/commandExecution/requestApproval", "params": [:]]).isEmpty)
        #expect((replies.last?["result"] as? [String: Any])?["decision"] as? String == "decline")
    }
}
