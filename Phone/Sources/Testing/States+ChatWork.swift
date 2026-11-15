import Foundation
import SyncKit

/// Chats from a Mac with what their turns did (TurnWork): each made of the
/// records a Mac syncs (a `chat` head and its `chatitem`s) and read through
/// SyncMapping, as a real chat is. chat.11 a finished research, nothing
/// under the answer; chat.12 at work with two subagents; chat.13 failed
/// partway; chat.14 stopped by you; chat.15 an answer after a long turn of
/// steps, none of them shown; chat.17 waiting on a pick, chat.18 the pick answered.
extension StateCatalog {
    static let chatWork: [NamedState] = [
        NamedState("chat.11", "Answer with work", "Nothing under the answer, as in Messages: Copy and Ask Again in the long-press menu, no steps.") { app in
            open(research(), in: app)
        },
        NamedState("chat.12", "Subagents working", "Two subagent cards with clocks over the dots.") { app in
            open(subagents(), in: app)
        },
        NamedState("chat.13", "Couldn't finish", "Claude's server went down: the reason and Try Again, no steps.") { app in
            open(failed(), in: app)
        },
        NamedState("chat.14", "Stopped", "“You stopped after 38s” in a quiet note, its steps never shown.") { app in
            open(stopped(), in: app)
        },
        NamedState("chat.15", "Long turn", "An answer after a thought, retries, a failed command and a subagent: only its thought fold and the answer.") { app in
            open(build(), in: app)
        },
        NamedState("chat.18", "Question and pick", "The agent's question as its message, my pick in blue under it, then the answer.") { app in
            open(picked(), in: app)
        },
        NamedState("chat.17", "Waiting for a pick", "The agent's question as the last message, numbered choices over the field, no dots.") { app in
            open(asking(), in: app)
        },
        NamedState("chat.30", "Do It from Now", "The Now row as a card over “Do It”, as on the Mac; the question and choices over the field.") { app in
            open(handed(), in: app)
        },
    ]

    // MARK: - the chats

    /// The records of one chat as a Mac writes them, a minute and a half
    /// ago, read through the real mapping.
    private struct Script {
        let id: String
        let title: String
        var state = "done"
        var answer = ""
        /// Seconds before now the turn began.
        var start: Double = 120
        /// What it waits for you to pick from, while it runs.
        var choices: [String] = []
        var items: [(kind: String, name: String, detail: String, text: String, state: String, from: Double, to: Double?)] = []

        mutating func add(_ kind: String, _ name: String = "", _ detail: String = "", text: String = "", state: String = "done",
                          at from: Double, to: Double? = nil) {
            items.append((kind, name, detail, text, state, from, to))
        }

        @MainActor func chat() -> Chat {
            let now = Date().timeIntervalSince1970
            let t0 = now - start
            var fields: [String: Value] = [
                "kind": "agent", "device": "mac-a", "title": .string(title), "state": .string(state), "answer": .string(answer),
                "cli": "claude", "started": .number(t0), "updated": .number(now - 5),
            ]
            if !choices.isEmpty { fields["choices"] = .array(choices.map(Value.string)) }
            let head = SyncChat(Record(collection: SyncCollection.chat, id: id, fields: fields))!
            let records = items.enumerated().compactMap { n, item -> SyncChatItem? in
                var fields: [String: Value] = ["chat": .string(id), "n": .number(Double(n + 1)), "kind": .string(item.kind),
                                               "name": .string(item.name), "detail": .string(item.detail), "text": .string(item.text),
                                               "state": .string(item.state), "began": .number(t0 + item.from)]
                if let to = item.to { fields["ended"] = .number(t0 + to) }
                return SyncChatItem(Record(collection: SyncCollection.chatItem, id: "\(id)/\(n + 1)", fields: fields))
            }
            return SyncMapping.chat(head, items: records, sends: [], macAsleep: false, old: nil)
        }
    }

    @MainActor private static func open(_ chat: Chat, in app: AppModel) {
        app.chats.add(chat)
        app.openChat(chat.id)
    }

    /// A pick asked on the Mac (ChatItem.question) and answered there (.chose).
    @MainActor private static func picked() -> Chat {
        var s = Script(id: "a:pick", title: "Avengers extra scenes", start: 200)
        s.add("asked", text: "where can i watch avengers endgame with the new extended scenes? check youtube, disney+ and reddit", at: 0)
        s.add("message", text: "I'll check YouTube, Disney+ and Reddit and find out which extra scenes this version has.", at: 2, to: 3)
        s.add("tool", "ask", "Which extra scenes do you mean?", at: 17, to: 22)
        s.add("message", "question", text: "Which extra scenes do you mean?", at: 17, to: 17)
        s.add("chose", text: "New scenes from the 2026 re-release", at: 22, to: 22)
        s.add("tool", "open", "youtube.com, disneyplus.com, reddit.com", at: 28, to: 51)
        s.add("tool", "open", "youtube.com", at: 60, to: 70)
        s.add("message", text: "Found the new scenes, not the full movie. Clips of the new scenes are on IGN, a breakdown of every scene on YouTube (16:18), Reddit wants a sign-in.", at: 186, to: 195)
        return s.chat()
    }

    /// The same chat while the Mac waits for the pick: SyncChat.choices.
    @MainActor private static func asking() -> Chat {
        var s = Script(id: "a:asks", title: "Avengers extra scenes", state: "waiting", start: 30)
        s.choices = ["New scenes from the 2026 re-release", "Deleted scenes from the Blu-ray", "Both, compared"]
        s.add("asked", text: "where can i watch avengers endgame with the new extended scenes? check youtube, disney+ and reddit", at: 0)
        s.add("message", text: "I'll check YouTube, Disney+ and Reddit and find out which extra scenes this version has.", at: 2, to: 3)
        s.add("tool", "ask", "Which extra scenes do you mean?", state: "running", at: 17)
        s.add("message", "question", text: "Which extra scenes do you mean?", at: 17, to: 17)
        return s.chat()
    }

    /// A row of Now handed to the agent on the Mac (Do It): its card goes
    /// with "Do It" as a "w:" line of the message's detail (SyncHanded).
    @MainActor private static func handed() -> Chat {
        var s = Script(id: "a:doit", title: "Builder cancellations", state: "waiting", start: 40)
        s.choices = ["Send", "Show the mail first"]
        let card = SyncHanded(host: "mail.google.com", title: "3 more Builder cancellations to pass to support",
                              detail: "Graham Muir (Amex 1032, failed Oct 14), Yatong Wen (A$35.62 Oct 14), Megaprompt (remove card, delete Stripe customer)",
                              from: "Gmail · From Now")
        s.add("asked", "", card.label, text: "Do It", at: 0)
        s.add("message", text: "On it: reading the three threads and checking each in Stripe.", at: 2, to: 3)
        s.add("tool", "ask", "I wrote one mail to support@example.com with all three. Send it?", state: "running", at: 30)
        s.add("message", "question", text: "I wrote one mail to support@example.com with all three. Send it?", at: 30, to: 30)
        return s.chat()
    }

    @MainActor private static func research() -> Chat {
        var s = Script(id: "a:cafe", title: "Quiet café in Alfama", start: 140)
        s.add("asked", text: "Find a quiet café in Alfama with good wifi for working tomorrow morning", at: 0)
        s.add("tool", "WebSearch", "\u{201C}quiet cafe Alfama wifi laptop\u{201D}", at: 3, to: 6)
        s.add("tool", "open", "timeout.com", at: 7, to: 15)
        s.add("tool", "memory_search", at: 16, to: 17)
        s.add("tool", "fetch", "wikipedia.org", at: 18, to: 24)
        s.add("tool", "open", "google.com", at: 25, to: 40)
        s.add("tool", "snapshot", "tab:a1b2", at: 41, to: 52)
        s.add("tool", "scroll", "down", at: 53, to: 55)
        s.add("message", text: """
            **Café da Garagem** is the one: a big quiet room over the river, long tables, \
            fast wifi and plugs along the wall. It opens at 9 and stays calm until lunch.

            If it is full, **Fábulas** two streets up has a back room that stays quiet all morning.
            """, at: 70, to: 72)
        return s.chat()
    }

    @MainActor private static func subagents() -> Chat {
        var s = Script(id: "a:flights", title: "Flights to Lisbon in May", state: "running", start: 96)
        s.add("asked", text: "Compare flights to Lisbon for the second week of May, TAP and Ryanair", at: 0)
        s.add("tool", "WebSearch", "\u{201C}Stockholm Lisbon May flights\u{201D}", at: 2, to: 6)
        s.add("message", text: "I\u{2019}ll check both airlines at once.", at: 7, to: 8)
        s.add("subagent", "spawnAgent", "Check TAP fares for May 11 to 15", state: "running", at: 10)
        s.add("subagent", "spawnAgent", "Check Ryanair fares for May 11 to 15", state: "running", at: 44)
        return s.chat()
    }

    @MainActor private static func failed() -> Chat {
        let error = #"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        var s = Script(id: "a:prs", title: "Open pull requests", state: "failed", answer: error, start: 80)
        s.add("asked", text: "Summarize the open pull requests on the tern repo", at: 0)
        s.add("tool", "open", "github.com", at: 2, to: 9)
        s.add("command", "command", "gh pr list --state open", text: "error: HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login",
              state: "failed", at: 10, to: 13)
        s.add("tool", "snapshot", "tab:c3d4", at: 14, to: 40)
        s.add("message", "error", text: error, at: 41)
        return s.chat()
    }

    @MainActor private static func stopped() -> Chat {
        var s = Script(id: "a:stop", title: "Table for two", start: 60)
        s.add("asked", text: "Book a table for two at a fado place in Alfama on Friday at 8", at: 0)
        s.add("tool", "WebSearch", "\u{201C}fado restaurant Alfama\u{201D}", at: 2, to: 5)
        s.add("tool", "open", "timeout.com", at: 6, to: 14)
        s.add("tool", "open", "airbnb.com", at: 15, to: 24)
        s.add("tool", "click", "\u{201C}Reserve\u{201D}", state: "running", at: 30)
        s.add("message", "stopped", at: 38)
        return s.chat()
    }

    @MainActor private static func build() -> Chat {
        var s = Script(id: "a:build", title: "Why CI fails", start: 260)
        s.add("asked", text: "Why does the build fail on CI but not on my Mac?", at: 0)
        s.add("thinking", "thought", text: "CI builds from a clean checkout, so anything only on this Mac is missing there.", at: 1, to: 9)
        s.add("tool", "Read", "Package.swift", at: 10, to: 11)
        s.add("tool", "Read", "Package.swift", at: 12, to: 13)
        s.add("tool", "Read", "Package.swift", at: 14, to: 15)
        s.add("tool", "Grep", "\u{201C}SyncKit\u{201D} in Sources", at: 16, to: 18)
        s.add("command", "command", "swift build", text: "Compiling Fast\nSources/Fast/Sync.swift:3:8: error: no such module 'SyncKit'\nCompiling failed", state: "failed", at: 19, to: 27)
        s.add("edit", "edit", "Package.swift", at: 30, to: 32)
        s.add("command", "command", "swift build", text: "Compiling Fast\nBuild complete! (48.12s)", at: 33, to: 81)
        s.add("subagent", "spawnAgent", "Read the last CI run\u{2019}s log", text: """
            The CI log fails at the same line: no such module 'SyncKit'.
            The runner checks out without submodules.
            Sources/SyncKit is a submodule since September.
            The fix is actions/checkout with submodules: recursive.
            Nothing else in the log is new.
            Its cache was cold, so the build took 9 minutes.
            The tests never ran.
            """, at: 82, to: 190)
        s.add("message", text: "CI checks out without submodules, and **SyncKit** became one in September. Add `submodules: recursive` to the checkout step.", at: 195, to: 197)
        return s.chat()
    }
}
