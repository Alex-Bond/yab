import Foundation
import Testing
@testable import Fast

// A chat: its turns, how long each worked, what is kept on disk and for
// how long, and the words of a message put together as they come.
struct ChatTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func chat(_ items: [ChatItem], updated: Date = t0, pinned: Bool = false) -> Chat {
        Chat(id: "c1", title: "Find flights", began: .newTabs, cli: "codex", model: nil, thread: "T1", items: items,
             pinned: pinned, state: "done", answer: "Found three.", started: t0, updated: updated)
    }

    @Test func turnsSplitAtEachQuestion() {
        let chat = Self.chat([
            ChatItem(id: "a1", kind: .asked, text: "find", state: .done),
            ChatItem(id: "t1", kind: .tool, name: "open"),
            ChatItem(id: "m1", kind: .message, text: "Found."),
            ChatItem(id: "a2", kind: .asked, text: "cheaper?", state: .done),
            ChatItem(id: "m2", kind: .message, text: "This one."),
        ])
        #expect(chat.turns.map { $0.map(\.id) } == [["a1", "t1", "m1"], ["a2", "m2"]])
    }

    @Test func steeredWordsStayInTheirTurn() {
        var steer = ChatItem(id: "s", kind: .asked, text: "also this", state: .done)
        steer.name = "steer"
        let chat = Self.chat([
            ChatItem(id: "a1", kind: .asked, text: "find", state: .done),
            ChatItem(id: "m1", kind: .message, text: "On it."),
            steer,
            ChatItem(id: "m2", kind: .message, text: "Found."),
        ])
        #expect(chat.turns.count == 1)
    }

    @Test func macAccessRestartContinuesTheSameVisibleTurn() throws {
        // Use the old literal, including the wrapped task prompt, so saved
        // chats keep working even if the new producer changes its wording.
        let continuation = ChatItem(id: "restart", kind: .asked,
            text: "Mac access was allowed for this task. Continue the original request: Find the update. Do it in tabs of your own.", state: .done)
        let chat = Self.chat([
            ChatItem(id: "a1", kind: .asked, text: "Find the update", state: .done),
            ChatItem(id: "m1", kind: .message, text: "Finding the file needs access to this Mac."),
            continuation,
            ChatItem(id: "t1", kind: .command, detail: "find document", state: .done),
            ChatItem(id: "m2", kind: .message, text: "Found the update."),
            ChatItem(id: "a2", kind: .asked, text: "Prepare a draft", state: .done),
        ])
        #expect(chat.turns.map { $0.map(\.id) } == [["a1", "m1", "t1", "m2"], ["a2"]])
        #expect(!chat.words.contains("Do it in tabs"))
        #expect(chat.words.contains("Prepare a draft"))
        // Preserve the raw transcript, and apply the same presentation on reload.
        let loaded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
        #expect(loaded.items.contains(continuation))
        #expect(loaded.turns == chat.turns)
    }

    @Test func restartFilterKeepsAssistantWordsAndRealQuestions() {
        let words = ChatItem.macAccessContinuationPrefix + "Find the update"
        let chat = Self.chat([
            ChatItem(id: "a", kind: .asked, text: "Mac access was allowed. What happens next?", state: .done),
            ChatItem(id: "m", kind: .message, text: words, state: .done),
        ])
        #expect(chat.turns.map { $0.map(\.id) } == [["a", "m"]])
    }

    @Test func workedFromFirstStepToLast() {
        var items: [ChatItem] = []
        items.put(ChatItem(id: "a", kind: .asked, state: .done), at: Self.t0)
        items.put(ChatItem(id: "t", kind: .tool, name: "open"), at: Self.t0.addingTimeInterval(2))
        items.put(ChatItem(id: "t", kind: .tool, name: "open", state: .done), at: Self.t0.addingTimeInterval(72))
        #expect(items[1].began == Self.t0.addingTimeInterval(2))
        #expect(items[1].ended == Self.t0.addingTimeInterval(72))
        #expect(Chat.worked(items) == 72)
        #expect(Chat.span(72) == "1m 12s")
        #expect(Chat.span(40) == "40s")
        #expect(Chat.span(120) == "2m")
    }

    @Test func wordsGrowOntoTheirStep() {
        var items: [ChatItem] = []
        items.grow("m", by: "Hi", at: Self.t0)
        items.grow("m", by: " there", at: Self.t0)
        items.grow("r", by: "hmm", kind: .thinking, at: Self.t0)
        #expect(items.map(\.text) == ["Hi there", "hmm"])
        #expect(items[1].kind == .thinking)
        // The whole message, once over, stands for what came in pieces.
        items.put(ChatItem(id: "m", kind: .message, text: "Hi there.", state: .done), at: Self.t0.addingTimeInterval(1))
        #expect(items[0].text == "Hi there.")
        #expect(items[0].began == Self.t0)
    }

    @Test func titleFromWhatWasAsked() {
        #expect(Chat.title(from: "Book a table\nfor two") == "Book a table")
        #expect(Chat.title(from: String(repeating: "a", count: 80)).count == 60)
    }

    @Test func apiErrorsAreNotRepeatedAsAssistantAnswers() {
        let raw = ChatProblemTests.unsupported
        let diagnostic = ChatItem(id: "error", kind: .message, text: raw, state: .done)
        #expect(!Chat.visibleMessage(diagnostic, failed: true, failure: raw))
        #expect(Chat.visibleMessage(diagnostic, failed: false, failure: raw))
        let prefix = "API Error: 503 service unavailable"
        #expect(!Chat.visibleMessage(ChatItem(id: "claude", kind: .message, text: prefix, state: .done), failed: true, failure: prefix))
        #expect(!Chat.visibleMessage(ChatItem(id: "broken", kind: .message, text: "{broken JSON", state: .done), failed: true, failure: "{broken JSON"))
    }

    @Test func failedTurnsKeepTheirPartialAnswers() {
        let partial = ChatItem(id: "partial", kind: .message, text: "I found the document.", state: .done)
        #expect(Chat.visibleMessage(partial, failed: true, failure: ChatProblemTests.unsupported))
        #expect(Chat.visibleMessage(partial, failed: true, failure: partial.text))
        let json = ChatItem(id: "json", kind: .message, text: #"{"result":"found"}"#, state: .done)
        #expect(Chat.visibleMessage(json, failed: true, failure: json.text))
    }

    @Test func historyAndCopiedErrorsAreReadableWithoutChangingLogs() {
        var chat = Self.chat([])
        chat.state = "failed"
        chat.answer = ChatProblemTests.unsupported
        #expect(chat.preview == "This model isn’t available")
        #expect(chat.copyTitle == "Copy Error")
        #expect(chat.copiedAnswer.contains("HTTP 400 · MODEL_UNAVAILABLE"))
        #expect(chat.copiedAnswer.contains("invalid_request_error"))
        #expect(!chat.copiedAnswer.contains("{\""))
        #expect(chat.answer == ChatProblemTests.unsupported)
        chat.state = "done"
        chat.answer = "Found **three** documents."
        #expect(chat.preview == "Found three documents.")
        #expect(chat.copiedAnswer == "Found three documents.")
        #expect(chat.copyTitle == "Copy Answer")
    }

    /// A short name in the head's glass: a few words, no sentence.
    @Test func shortNamesFitTheHead() {
        #expect(ChatTitles.fits("Lisbon flight"))
        #expect(ChatTitles.fits("Anna's venue email"))
        #expect(!ChatTitles.fits("What needs me on Tern today and tomorrow"))
        #expect(!ChatTitles.fits("Tern today."))
        #expect(!ChatTitles.fits(""))
        #expect(ChatTitles.fits("Lisbon flight", asked: "Find me a cheap flight to Lisbon"))
    }

    @Test func sectionsKeptThenByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Self.t0
        #expect(Self.chat([], updated: now.addingTimeInterval(-60)).section(now: now, calendar: calendar) == "Today")
        #expect(Self.chat([], updated: now.addingTimeInterval(-86400)).section(now: now, calendar: calendar) == "Yesterday")
        #expect(Self.chat([], updated: now.addingTimeInterval(-3 * 86400)).section(now: now, calendar: calendar) == "Earlier")
        #expect(Self.chat([], updated: now.addingTimeInterval(-3 * 86400), pinned: true).section(now: now, calendar: calendar) == "Pinned")
        // Kept for good first, however old, then the newest.
        let old = Chat(id: "kept", title: "Old", began: .here, cli: "claude", model: nil, thread: nil, items: [],
                       pinned: true, state: "done", answer: "", started: now, updated: now.addingTimeInterval(-3 * 86400))
        let new = Self.chat([], updated: now)
        #expect(Chat.listed([new, old]).map(\.id) == ["kept", "c1"])
    }

    @Test func answerInOnePlainLine() {
        #expect(Chat.plain("I opened both tabs: [RFC 2606](https://x.org/a) says **so**.\nDone.") == "I opened both tabs: RFC 2606 says so. Done.")
    }

    @Test func oldChatsStayOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Self.chat([ChatItem(id: "a", kind: .asked, text: "x", state: .done)], updated: Self.t0)
        Chats.write([old], to: folder)
        let later = Chats.read(folder, now: Self.t0.addingTimeInterval(60 * 24 * 3600))
        #expect(later == [old])
    }

    @Test func staleAfterTheWaitUnlessPinnedOrArchived() {
        var chat = Self.chat([], updated: Self.t0)
        let month = Tidy.month.seconds
        #expect(!chat.stale(now: Self.t0.addingTimeInterval(29 * 24 * 3600), after: month))
        #expect(chat.stale(now: Self.t0.addingTimeInterval(31 * 24 * 3600), after: month))
        #expect(!chat.stale(now: Self.t0.addingTimeInterval(365 * 24 * 3600), after: Tidy.never.seconds))
        chat.pinned = true
        #expect(!chat.stale(now: Self.t0.addingTimeInterval(31 * 24 * 3600), after: month))
        chat.pinned = false
        chat.archived = true
        #expect(!chat.stale(now: Self.t0.addingTimeInterval(31 * 24 * 3600), after: month))
    }
}
