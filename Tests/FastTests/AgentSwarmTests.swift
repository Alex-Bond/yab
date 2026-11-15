import Foundation
import Testing
@testable import Fast

// What keeps three agents at once (Claude Code's subagents, sharing one
// `yab mcp`) from swamping Yab: a call cancelled while it waited in line is
// never made, and a script's huge value comes back cut. The rest, tabs and
// memory under real pages, is evals/agent-swarm/run.py.
@Suite struct AgentSwarmTests {
    static func line(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    @Test func aCancelledCallStillWaitingIsNeverMade() {
        var lines = [
            Self.line(["jsonrpc": "2.0", "id": 1, "method": "tools/call"]),
            Self.line(["jsonrpc": "2.0", "id": 2, "method": "tools/call"]),
            Self.line(["jsonrpc": "2.0", "id": 3, "method": "tools/call"]),
            Self.line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]),
        ]
        let inbox = Inbox()
        inbox.read { lines.isEmpty ? nil : lines.removeFirst() }
        var made: [Int] = []
        while let message = inbox.next() { made.append(message["id"] as? Int ?? -1) }
        #expect(made == [1, 3])
    }

    @Test func otherNotificationsStillReachTheServer() {
        var lines = [
            Self.line(["jsonrpc": "2.0", "method": "notifications/initialized"]),
            "not json",
            Self.line(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]),
            Self.line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "a"]]),
        ]
        let inbox = Inbox()
        inbox.read { lines.isEmpty ? nil : lines.removeFirst() }
        #expect(inbox.next()?["method"] as? String == "notifications/initialized")
        #expect(inbox.next() == nil)
    }

    @Test func aHugeValueComesBackCut() {
        let text = String(repeating: "x", count: 2_000_000)
        let cut = Bench.capped(text) as? String ?? ""
        #expect(cut.utf8.count < 401_000)
        #expect(cut.contains("cut: the value was 2000 KB"))
        let list = Array(repeating: "row of a long list", count: 100_000)
        #expect((Bench.capped(list) as? String)?.contains("KB of JSON") == true)
        #expect(Bench.capped("small") as? String == "small")
        #expect((Bench.capped([1, 2, 3]) as? [Int]) == [1, 2, 3])
    }
}
