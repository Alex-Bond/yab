import Foundation
import Testing
@testable import Fast

// A routine on a split's mail (docs/mail.md, Routines on a split's mail): `on mail <split>`,
// one mail a run, the oldest come since it was set that it hasn't done;
// told the email, and that paying and sending wait for the person.
struct MailRoutineTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func itsWhen() {
        #expect(Routines.schedule("on mail receipts") == .mail("receipts"))
        #expect(Routines.schedule(Routines.mailWhen("q:from:billing@vercel.com")) == .mail("q:from:billing@vercel.com"))
        #expect(Routines.schedule("on mail") == nil)
        #expect(Routines.say("on mail receipts") == "When mail comes to Receipts")
        // Never on a clock.
        let routine = Routine(id: "r", when: "on mail receipts", prompt: "Save the PDF.", last: Self.now)
        #expect(Routines.next(routine, after: Self.now) == nil)
        #expect(Routines.due(.mail("receipts"), before: Self.now) == .distantPast)
    }

    @Test func oneMailARunTheOldestNewFirst() {
        let since = Self.now.addingTimeInterval(-3600)
        let rows: [(id: String, at: Date, real: Bool)] = [
            ("a|new", Self.now.addingTimeInterval(-60), true),
            ("a|older", Self.now.addingTimeInterval(-600), true),
            ("a|before", Self.now.addingTimeInterval(-7200), true),
            ("a|draft", Self.now.addingTimeInterval(-900), false),
        ]
        #expect(Routines.nextMail(rows, since: since, done: []) == "a|older")
        #expect(Routines.nextMail(rows, since: since, done: ["a|older"]) == "a|new")
        #expect(Routines.nextMail(rows, since: since, done: ["a|older", "a|new"]) == nil)
    }

    @MainActor @Test func toldTheEmailAndThatPayAndSendWait() {
        var routine = Routine(id: "r", when: "on mail receipts", prompt: "Save the PDF to Finance/2026 and add a row to Expenses.",
                              last: Self.now, title: "Receipts routine")
        routine.may = "agents"
        let ref = MailRef(kind: .thread(account: "me@acme.io", thread: "t1"), title: "Your receipt from Vercel", detail: "Vercel")
        let said = Routines.shared.prompt(for: routine, mail: ref)
        #expect(said.contains("set to run when mail comes to receipts"))
        #expect(said.contains("thread me@acme.io|t1"))
        #expect(said.contains("Before anything that pays or sends, stop and ask with `ask`"))
        // On a clock, no email and no such line.
        let daily = Routine(id: "d", when: "daily 9:00", prompt: "Look.", last: Self.now)
        #expect(!Routines.shared.prompt(for: daily).contains("pays or sends"))
    }
}
