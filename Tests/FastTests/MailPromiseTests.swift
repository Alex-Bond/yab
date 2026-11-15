import Foundation
import SwiftUI
import Testing
@testable import Fast
@testable import MailCore

// Promised (docs/mail.md, Promised): what you promised in your own mail,
// read by rules on this Mac, kept against the mail that said it, closed by
// what you wrote after, and the list's words for it.
struct MailPromiseTests {
    static let me = MailPerson(name: "Me", address: "me@acme.io")
    static let mark = MailPerson(name: "Mark Chen", address: "mark@north.vc")
    /// A Wednesday at noon.
    static let wednesday = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!

    // MARK: - a sentence

    @Test func whatPromisesAndWhatDoesnt() {
        let promises = ["Sure, I’ll send them by Friday once the close is done.", "Will intro you to Kenji tomorrow.",
                        "I will share the deck tonight.", "Let me check with the team and follow up."]
        for sentence in promises { #expect(MailPromise.reading(sentence) != nil, "\(sentence)") }
        let not = ["We should grab coffee sometime!", "I’ll be in Berlin next week.", "Can you send the deck?",
                   "Let me know if Friday works.", "Would you share the numbers?", "Thanks, got it."]
        for sentence in not { #expect(MailPromise.reading(sentence) == nil, "\(sentence)") }
        // No thing and no day: a judgment call.
        #expect(MailPromise.reading("Let me think about it and get back to you.")?.judgment == true)
    }

    @Test func whatWasPromised() {
        #expect(MailPromise.reading("I’ll send the Q3 numbers by Friday.")?.kind == .file)
        #expect(MailPromise.reading("Will intro you to Kenji tomorrow.")?.kind == .intro)
        #expect(MailPromise.reading("I’ll reply properly tomorrow.")?.kind == .word)
    }

    @Test func theDayFromTheMailsOwnDate() throws {
        let calendar = Calendar.current
        let friday = try #require(MailPromise.due(in: "I’ll send them by Friday", at: Self.wednesday))
        #expect(calendar.component(.weekday, from: friday) == 6)
        #expect(friday > Self.wednesday && friday.timeIntervalSince(Self.wednesday) < 3 * 86_400)
        let tomorrow = try #require(MailPromise.due(in: "numbers tomorrow", at: Self.wednesday))
        #expect(calendar.isDate(tomorrow, inSameDayAs: Self.wednesday.addingTimeInterval(86_400)))
        let tonight = try #require(MailPromise.due(in: "notes tonight", at: Self.wednesday))
        #expect(calendar.isDate(tonight, inSameDayAs: Self.wednesday) && calendar.component(.hour, from: tonight) == 21)
        #expect(MailPromise.due(in: "I’ll send them soon", at: Self.wednesday) == nil)
    }

    /// The detector reads "before Oct 20" as a span starting now: the day
    /// is its end, not the day the mail was read ("6d late" the next week).
    @Test func beforeADayIsThatDay() throws {
        let now = Date()
        let day = Calendar.current.date(byAdding: .day, value: 20, to: now)!
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMMM d, yyyy"
        let due = try #require(MailPromise.due(in: "I'll complete it with a lab before \(format.string(from: day)).", at: now))
        #expect(Calendar.current.isDate(due, inSameDayAs: day))
    }

    // MARK: - a store

    func mail(_ id: String, _ thread: String, from: MailPerson, to: [MailPerson], text: String, hours: Double,
              now: Date, labels: Set<String>, files: [MailFile]? = nil) -> MailMessage {
        MailMessage(id: id, thread: thread, from: from, to: to, subject: "Q3 numbers", snippet: text,
                    date: now.addingTimeInterval(-hours * 3600), labels: labels, text: text, files: files)
    }

    func store(now: Date) -> MailStore {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        store.put([
            mail("a", "q3", from: Self.mark, to: [Self.me], text: "Can you send Sep MAU and revenue before Thursday?", hours: 50,
                 now: now, labels: ["INBOX"]),
            mail("b", "q3", from: Self.me, to: [Self.mark], text: "Sure, I’ll send them by Friday once the close is done.", hours: 48,
                 now: now, labels: ["SENT"]),
        ])
        return store
    }

    @Test func aPromiseIsKeptAndClosedByTheFile() throws {
        let now = Date()
        let store = store(now: now)
        #expect(MailPromise.run(store, now: now))
        let open = MailPromise.open(in: store, now: now)
        #expect(open.count == 1)
        let one = try #require(open.first)
        #expect(one.thread == "q3" && one.kind == .file && one.person == "Mark Chen" && one.address == "mark@north.vc")
        #expect(one.quote == "Sure, I’ll send them by Friday once the close is done.")
        // Words alone don't keep a promise of a file.
        store.put([mail("c", "q3", from: Self.me, to: [Self.mark], text: "Working on it.", hours: 10, now: now, labels: ["SENT"])])
        MailPromise.run(store, now: now)
        #expect(MailPromise.open(in: store, now: now).count == 1)
        // The file does.
        let file = MailFile(part: "1", name: "Q3 metrics.pdf", mime: "application/pdf", size: 240_000, attachmentID: "x", contentID: "",
                            inline: false)
        store.put([mail("d", "q3", from: Self.me, to: [Self.mark], text: "Here they are.", hours: 1, now: now, labels: ["SENT"],
                        files: [file])])
        MailPromise.run(store, now: now)
        #expect(MailPromise.open(in: store, now: now).isEmpty)
    }

    @Test func numbersInTheWordsKeepAPromiseOfNumbers() {
        let now = Date()
        let store = store(now: now)
        MailPromise.run(store, now: now)
        store.put([mail("c", "q3", from: Self.me, to: [Self.mark], text: "Back by 10, then I'm on it.", hours: 10, now: now, labels: ["SENT"])])
        MailPromise.run(store, now: now)
        #expect(MailPromise.open(in: store, now: now).count == 1)
        store.put([mail("d", "q3", from: Self.me, to: [Self.mark], text: "September: 48,210 monthly users, $61.4k revenue.", hours: 1,
                        now: now, labels: ["SENT"])])
        MailPromise.run(store, now: now)
        #expect(MailPromise.open(in: store, now: now).isEmpty)
    }

    @Test func aLaterPromiseMovesTheOneBefore() throws {
        let now = Date()
        let store = store(now: now)
        MailPromise.run(store, now: now)
        store.put([mail("c", "q3", from: Self.me, to: [Self.mark], text: "The close slipped. I’ll send the numbers Monday morning.",
                        hours: 5, now: now, labels: ["SENT"])])
        MailPromise.run(store, now: now)
        let open = MailPromise.open(in: store, now: now)
        #expect(open.map(\.message) == ["c"])
        #expect(store.promises(states: [.moved]).map(\.message) == ["b"])
    }

    @Test func eKeepsItByHandAndUndoOpensIt() {
        let now = Date()
        let store = store(now: now)
        MailPromise.run(store, now: now)
        let kept = store.keepPromises(inThread: "q3")
        #expect(kept.count == 1 && MailPromise.open(in: store, now: now).isEmpty)
        // Read again, a promise kept by hand stays kept.
        MailPromise.run(store, now: now)
        #expect(MailPromise.open(in: store, now: now).isEmpty)
        for one in kept { store.setPromise(one, state: one.state) }
        #expect(MailPromise.open(in: store, now: now).count == 1)
    }

    /// Replies written ahead for a promise: a prompt of their own, your
    /// sentence and its day in it, and the first reply's places for what
    /// only you know.
    @MainActor @Test func aPromiseHasRepliesOfItsOwn() throws {
        let now = Date()
        let store = store(now: now)
        MailPromise.run(store, now: now)
        let asks = MailDrafts.promising(store, now: now)
        let one = try #require(asks.first)
        #expect(asks.count == 1 && one.thread == "q3")
        #expect(one.text.contains("You promised Mark Chen: \"Sure, I’ll send them by Friday once the close is done.\""))
        #expect(one.text.contains("\nDue: "))
        #expect(MailDrafts.promiseSystem.contains("{{Q3 revenue}}"))
        // Written: not asked again.
        store.keepAhead("q3", message: one.message, replies: ["Send them\u{1F}Hi Mark, Sep MAU {{MAU}}."])
        #expect(MailDrafts.promising(store, now: now).isEmpty)
    }

    // MARK: - lit in the mail

    @Test func aPromiseIsLitWhereYouWroteIt() {
        let mark = "<mark style=\"" + MailHTML.markStyle + "\">"
        // As written, and as Gmail's HTML writes the apostrophe.
        #expect(MailHTML.lit("<div>Sure, I'll send them by Friday.</div>", promised: ["Sure, I'll send them by Friday."])
                == "<div>" + mark + "Sure, I'll send them by Friday.</mark></div>")
        #expect(MailHTML.lit("<div>Sure, I&#39;ll send them.</div>", promised: ["Sure, I'll send them."])
                == "<div>" + mark + "Sure, I&#39;ll send them.</mark></div>")
        #expect(MailHTML.lit("<div>Sure, I’ll send them.</div>", promised: ["Sure, I'll send them."])
                == "<div>" + mark + "Sure, I’ll send them.</mark></div>")
        // Not there as it is: left as it was.
        #expect(MailHTML.lit("<div>Sure, I <b>will</b> send them.</div>", promised: ["Sure, I will send them."])
                == "<div>Sure, I <b>will</b> send them.</div>")
        // In text mail, across a line end, its apostrophe however it is written.
        let text = "Hi Mark,\nSure, I’ll send them\nby Friday once the close is done.\nSam"
        let lit = MailHTML.litText(text, promised: ["Sure, I'll send them by Friday once the close is done."])
        let marked = lit.runs.filter { $0.attributes.swiftUI.backgroundColor != nil }.map { String(lit[$0.range].characters) }
        #expect(marked == ["Sure, I’ll send them\nby Friday once the close is done."])
        #expect(MailHTML.litText(text, promised: []).runs.allSatisfy { $0.attributes.swiftUI.backgroundColor == nil })
    }

    @MainActor @Test func theLetterKnowsItsOpenPromises() {
        let now = Date()
        let store = store(now: now)
        MailPromise.run(store, now: now)
        let promised = MailDesk.promised(store.messages(thread: "q3"), in: store)
        #expect(promised == ["b": ["Sure, I’ll send them by Friday once the close is done."]])
        _ = store.keepPromises(inThread: "q3")
        #expect(MailDesk.promised(store.messages(thread: "q3"), in: store).isEmpty)
    }

    @Test func aColdPitchSaysWhy() {
        #expect(MailDrafts.cold("We run a launch agency.", address: "dana@acmeleads.io")
                == "We run a launch agency. You have never written to acmeleads.io.")
        #expect(MailDrafts.cold("", address: "dana@acmeleads.io") == "You have never written to acmeleads.io.")
    }

    // MARK: - in words

    @Test func theRowsWords() {
        let now = Self.wednesday
        func promise(due: Date?, at: Date = now.addingTimeInterval(-5 * 86_400)) -> MailPromised {
            MailPromised(message: "m", thread: "t", quote: "", person: "", address: "", kind: .word, due: due, at: at)
        }
        #expect(MailPromise.when(promise(due: nil), now: now) == "5d")
        #expect(MailPromise.when(promise(due: now.addingTimeInterval(-2 * 86_400)), now: now) == "2d late")
        #expect(MailPromise.late(promise(due: now.addingTimeInterval(-2 * 86_400)), now: now))
        #expect(MailPromise.when(promise(due: now.addingTimeInterval(86_400)), now: now) == "by tomorrow")
        #expect(MailPromise.when(promise(due: now.addingTimeInterval(2 * 86_400)), now: now) == "by Fri")
    }
}
