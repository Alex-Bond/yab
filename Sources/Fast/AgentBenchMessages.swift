import AppKit
import WebKit

// Bench.agentCommand's verbs (AgentBench). Messages: chats read, texts sent,
// codes texted.

extension Bench {
    static let messagesVerbs: [String: AgentHandler] = [
        "agent-messages": { $0.handleAgentMessages($1) },
        "agent-message-send": { $0.handleAgentMessages($1) },
        "agent-sms": { $0.handleAgentSms($1) },
        "agent-sms-fake": { $0.handleAgentSmsFake($1) },
    ]

    func handleAgentMessages(_ c: AgentCall) {
        let verb = c.verb
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // Your chats, read; a message, sent with your yes (AgentMessages).
        guard browser.prefs.agentsMessages else {
            answer(["error": "Messages is off; the person can turn it on in Settings › Agents › Messages"])
            return
        }
        guard agents.session(session)?.full ?? true else { answer(["error": "a task kept to the browser can't use Messages"]); return }
        if verb == "agent-messages" {
            agents.touch(session, "messages")
            let chat = (request["chat"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = min(max(request["limit"] as? Int ?? (chat.isEmpty ? 20 : 40), 1), 200)
            DispatchQueue.global(qos: .userInitiated).async {
                let found = chat.isEmpty ? AgentMessages.chats(limit: limit) : AgentMessages.thread(chat, limit: limit)
                DispatchQueue.main.async {
                    switch found {
                    case .success(let lines): answer(["text": lines.isEmpty ? (chat.isEmpty ? "No chats." : "No messages in a chat like \(chat).") : lines.joined(separator: "\n")])
                    case .failure(let trouble): answer(["error": trouble.said])
                    }
                }
            }
            return
        }
        let to = (request["to"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, !text.isEmpty else { answer(["error": "send_message needs to (a phone number or an address) and text"]); return }
        guard let session else { answer(["error": "no task to send for"]); return }
        // As mail_send: a message goes only from a chat the person is in,
        // Bypass or not; a subagent or a routine nobody watches says it.
        if let why = Bench.sendRefusal(agents.session(session), what: "a message") { answer(["error": why]); return }
        // The card stands on the task's own latest tab, the one it asked on
        // already, or the one in front (Agents.askTab).
        guard let tab = agents.askTab(for: session, in: browser) else { answer(["error": "no tab to ask in"]); return }
        let key = "imessage:" + to
        let yes = tab.approved.flatMap { $0.session == session && $0.ref == key && Date().timeIntervalSince($0.at) < 120 ? $0 : nil }
        guard yes != nil || browser.prefs.asking(session) == .bypass else {
            if tab.declined.remove(session) != nil { answer(["error": "the person said not now to that message: don't send it another way; say so in your answer"]); return }
            agents.ask(tab, AgentPermit(kind: .sendMessage(to: to), session: session, detail: "Messages", draft: text))
            agents.showAsk(tab, session: session, in: browser)
            answer(["error": "sending waits for the person's yes; asking them now", "asking": true, "tab": Bench.short(tab)])
            return
        }
        tab.approved = nil
        agents.touch(session, "message · \(to)")
        let trouble = AgentMessages.send(text, to: to)
        agents.sent(tab, trouble: trouble) { AgentMessages.send(text, to: to) }
        if let trouble { answer(["error": trouble]) } else { answer(["ok": true]) }
    }

    func handleAgentSms(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        guard browser.prefs.agentsMessages else {
            answer(["error": "reading codes from Messages is off; the person can turn it on in Settings › Agents, or call handoff"])
            return
        }
        guard let tab = own(), let session else { return }
        guard agents.session(session)?.full ?? true else { answer(["error": "a task kept to the browser can't read Messages; call handoff"]); return }
        let yes = tab.approved.flatMap { $0.session == session && $0.ref == "messages" && Date().timeIntervalSince($0.at) < 120 ? $0 : nil }
        guard yes != nil || browser.prefs.asking(session) == .bypass else {
            if tab.declined.remove(session) != nil { answer(["error": "the person said not now to reading Messages: call handoff"]); return }
            agents.ask(tab, AgentPermit(kind: .messages, session: session, detail: "the latest code, for \(tab.address?.host ?? "this page")"))
            answer(["error": "reading Messages waits for the person's yes; asking them now", "asking": true])
            return
        }
        tab.approved = nil
        agents.touch(session, "messages")
        let minutes = request["minutes"] as? Double ?? 10
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AgentFiles.codes(minutes: minutes)
            DispatchQueue.main.async {
                switch found {
                case .success(let lines): answer(["text": lines.isEmpty ? "No code in Messages in the last \(Int(minutes)) minutes." : lines.joined(separator: "\n")])
                case .failure(let trouble): answer(["error": trouble.said])
                }
            }
        }
    }

    func handleAgentSmsFake(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        // A test world's phone: texts that messages_code reads in place
        // of Messages, a --test run only.
        guard Store.testing else { answer(["error": "agent-sms-fake only works on a --test run"]); return }
        let texts = (request["texts"] as? [[String: Any]] ?? []).map { row in
            (text: row["text"] as? String ?? "", at: Date(timeIntervalSince1970: row["ts"] as? Double ?? Date().timeIntervalSince1970), from: row["from"] as? String ?? "?")
        }
        AgentFiles.fakeTexts.withLock { $0 = texts }
        answer(["ok": true])
    }
}
