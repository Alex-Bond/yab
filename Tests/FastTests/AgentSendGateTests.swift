import Testing
@testable import Fast

/// Sending in the person's name (mail_send, send_message): only from a chat
/// they are in, never from a subagent or a task nobody watches, in Bypass too.
@MainActor
struct AgentSendGateTests {
    private func session(_ id: String) -> Agents.Session {
        Agents.Session(id: id, cli: "claude", name: "Claude", prompt: "Send it", state: .starting)
    }

    @Test func aChatThePersonIsInMaySend() {
        #expect(Bench.sendRefusal(session("chat"), what: "a message") == nil)
    }

    @Test func aSubagentOrAnUnwatchedTaskNeverSends() {
        let sub = session("sub")
        sub.parent = "chat"
        #expect(Bench.sendRefusal(sub, what: "a message")?.hasPrefix("a message goes only from a chat") == true)
        let sealed = session("sealed")
        sealed.sealed = true
        #expect(Bench.sendRefusal(sealed, what: "a mail")?.hasPrefix("a mail goes only from a chat") == true)
        #expect(Bench.sendRefusal(nil, what: "a mail") == "no task to send for")
    }
}
