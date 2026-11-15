import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Done in Waiting stays done (docs/mail.md, Inbox): E on a thread you wait
// on keeps it out of Waiting, and out of the new tab's "hasn't answered"
// rows, though Sent still holds it, until a new message comes in it; ⌘Z
// puts it back.
struct MailWaitingTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let me = MailPerson(name: "Me", address: "me@example.com")
    static let tim = MailPerson(name: "Tim Okafor", address: "tim@okafor.co")

    /// A store holding your ask to Tim five days ago, out of the inbox,
    /// in Sent only: what Waiting is made of.
    func store() -> MailStore {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        store.put([mail("t1", from: Self.me, to: Self.tim, days: 5, labels: ["SENT"])])
        return store
    }

    func mail(_ id: String, thread: String = "tim", from: MailPerson, to: MailPerson, days: Double, labels: Set<String>) -> MailMessage {
        MailMessage(id: id, thread: thread, from: from, to: [to], subject: "Logo files for the launch", snippet: "Could you send the SVGs?",
                    date: Self.now.addingTimeInterval(-days * 86_400), labels: labels, text: "Could you send the SVGs?")
    }

    func waiting(_ store: MailStore, now: Date = Self.now) -> [String] { MailSplit.threads(.waiting, in: store, now: now).map(\.0.id) }

    @Test func doneInWaitingStaysOut() throws {
        let store = store()
        #expect(waiting(store) == ["tim"])
        #expect(MailOps.stopWaiting("tim", in: store, now: Self.now))
        #expect(waiting(store).isEmpty)
        let thread = try #require(store.thread("tim"))
        #expect(thread.doneWaiting)
        #expect(MailSplit.of(thread, now: Self.now) == nil)
        // The sync writing the same mail again leaves it out, and so does
        // one from nothing: Gmail's ids stay the same.
        store.put([mail("t1", from: Self.me, to: Self.tim, days: 5, labels: ["SENT"])])
        #expect(waiting(store).isEmpty)
        store.forgetMail()
        store.put([mail("t1", from: Self.me, to: Self.tim, days: 5, labels: ["SENT"])])
        #expect(waiting(store).isEmpty)
    }

    @Test func undoPutsItBackInWaiting() {
        let store = store()
        MailOps.stopWaiting("tim", in: store, now: Self.now)
        store.waitAgain("tim")
        #expect(waiting(store) == ["tim"])
        #expect(store.thread("tim")?.doneWaiting == false)
    }

    @Test func theirReplyBringsItToNeedsYou() throws {
        let store = store()
        MailOps.stopWaiting("tim", in: store, now: Self.now)
        store.put([mail("t2", from: Self.tim, to: Self.me, days: 1, labels: ["INBOX", "UNREAD"])])
        let thread = try #require(store.thread("tim"))
        #expect(!thread.doneWaiting)
        #expect(MailSplit.of(thread, now: Self.now) == .needs)
        #expect(MailSplit.threads(.needs, in: store, now: Self.now).map(\.0.id) == ["tim"])
        #expect(waiting(store).isEmpty)
    }

    @Test func anotherWordOfYoursWaitsAgain() {
        let store = store()
        MailOps.stopWaiting("tim", in: store, now: Self.now)
        store.put([mail("t3", from: Self.me, to: Self.tim, days: 3, labels: ["SENT"])])
        #expect(waiting(store) == ["tim"])
    }

    @Test func onlyAThreadInWaitingIsDoneWaiting() {
        let store = store()
        // Asked yesterday: not Waiting yet, so E leaves no mark, and it
        // comes to Waiting once two days have gone.
        store.put([mail("a1", thread: "anna", from: Self.me, to: Self.tim, days: 1, labels: ["SENT"])])
        #expect(!MailOps.stopWaiting("anna", in: store, now: Self.now))
        #expect(waiting(store, now: Self.now.addingTimeInterval(2 * 86_400)).contains("anna"))
        #expect(!MailOps.stopWaiting("nothing", in: store, now: Self.now))
    }

    @Test func doneFromTheInboxAndTakenBack() {
        let store = store()
        // Their ask, your answer three days ago, the thread still in the
        // inbox: Waiting. E archives it as well; ⌘Z before Gmail heard
        // it, in the inbox and Waiting again.
        store.put([mail("p1", thread: "priya", from: Self.tim, to: Self.me, days: 4, labels: ["INBOX"]),
                   mail("p2", thread: "priya", from: Self.me, to: Self.tim, days: 3, labels: ["SENT"])])
        #expect(waiting(store).contains("priya"))
        #expect(MailOps.stopWaiting("priya", in: store, now: Self.now))
        let seq = MailOps.act(.archive, thread: "priya", after: 4, in: store)
        #expect(!waiting(store).contains("priya"))
        #expect(!MailSplit.threads(.needs, in: store, now: Self.now).map(\.0.id).contains("priya"))
        #expect(MailOps.undo(seq, in: store))
        store.waitAgain("priya")
        #expect(store.thread("priya")?.labels.contains("INBOX") == true)
        #expect(waiting(store).contains("priya"))
    }

    @MainActor @Test func readMailWaitsOnNoOne() {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        let labels: Set<String> = ["INBOX", "UNREAD"]
        store.put([mail("c1", thread: "chase", from: Self.tim, to: Self.me, days: 2, labels: labels)])
        store.keep(MailSensed(thread: "chase", message: "c1", needs: true, gist: "Could you send the SVGs?", kind: .person, byModel: true))
        let rows = { MailCenter.noticed(in: store, account: Self.me.address, now: Self.now).map(\.why) }
        #expect(rows() == [.waitingOnYou])
        store.put([mail("c1", thread: "chase", from: Self.tim, to: Self.me, days: 2, labels: ["INBOX"])])
        #expect(rows().isEmpty)
    }

    // An answer in a thread you wrote in is said at once; a stranger's
    // ask after four hours unread.
    @MainActor @Test func anAnswerToYouAtOnceSomeoneNewAfterFourHours() {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        let ana = MailPerson(name: "Ana Ruiz", address: "ana@ruiz.co")
        store.put([mail("d1", thread: "danny", from: Self.me, to: Self.tim, days: 2, labels: ["SENT"]),
                   mail("d2", thread: "danny", from: Self.tim, to: Self.me, days: 1 / 24, labels: ["INBOX", "UNREAD"]),
                   mail("a1", thread: "ana", from: ana, to: Self.me, days: 1 / 24, labels: ["INBOX", "UNREAD"])])
        for (thread, message) in [("danny", "d2"), ("ana", "a1")] {
            store.keep(MailSensed(thread: thread, message: message, needs: true, gist: "Asks for the SVGs", kind: .person, byModel: true))
        }
        let rows = { (now: Date) in MailCenter.noticed(in: store, account: Self.me.address, now: now) }
        #expect(rows(Self.now).map(\.thread) == ["danny"])
        #expect(rows(Self.now).first?.conversation == true)
        #expect(Set(rows(Self.now.addingTimeInterval(4 * 3600)).map(\.thread)) == ["danny", "ana"])
        // Yet unread by the Mac's model: no row until it has read the thread.
        store.keep(MailSensed(thread: "danny", message: "d2", needs: true, gist: "", kind: .person, byModel: false))
        if MailSense.ready && MailSense.wanted { #expect(!rows(Self.now).map(\.thread).contains("danny")) }
    }

    @MainActor @Test func noHasntAnsweredRowOnTheNewTab() {
        let store = store()
        let rows = { MailCenter.noticed(in: store, account: Self.me.address, now: Self.now) }
        #expect(rows().map(\.why) == [.noAnswer])
        #expect(Noticing.mail(rows(), now: Self.now).map(\.title) == ["Tim hasn’t answered"])
        MailOps.stopWaiting("tim", in: store, now: Self.now)
        #expect(rows().isEmpty)
        store.waitAgain("tim")
        #expect(rows().map(\.who) == ["Tim"])
    }
}
