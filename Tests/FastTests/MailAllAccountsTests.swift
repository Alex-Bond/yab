import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Show in All Accounts (docs/mail.md, All Accounts; feedback #279): an
// account kept apart is out of All Accounts and its counts, keeps its own,
// and the last one in can't leave.
@MainActor
@Suite(.serialized)
struct MailAllAccountsTests {
    let me = "me@example.com", alerts = "alerts@example.com", side = "side@example.com"
    let now = Date()

    @Test func everyAccountIsInUntilTurnedOff() {
        let accounts = [me, alerts]
        #expect(MailAllAccounts.together(accounts, apart: []) == accounts)
        #expect(MailAllAccounts.shows(alerts, in: "all", accounts: accounts, apart: []))
        #expect(MailAllAccounts.together(accounts, apart: [alerts]) == [me])
        #expect(!MailAllAccounts.shows(alerts, in: "all", accounts: accounts, apart: [alerts]))
        // Its own inbox shows it whatever All Accounts does.
        #expect(MailAllAccounts.shows(alerts, in: alerts, accounts: accounts, apart: [alerts]))
        #expect(!MailAllAccounts.shows(me, in: alerts, accounts: accounts, apart: []))
    }

    @Test func allAccountsIsNeverEmpty() {
        let accounts = [me, alerts]
        // Every one kept apart (an older Mac's settings): All Accounts is all of them.
        #expect(MailAllAccounts.together(accounts, apart: [me, alerts]) == accounts)
        // An address no longer here keeps nobody out.
        #expect(MailAllAccounts.together(accounts, apart: ["gone@example.com"]) == accounts)
    }

    @Test func theLastOneInCantLeave() {
        let accounts = [me, alerts, side]
        #expect(MailAllAccounts.canLeave(alerts, accounts: accounts, apart: []))
        #expect(MailAllAccounts.canLeave(alerts, accounts: accounts, apart: [side]))
        #expect(!MailAllAccounts.canLeave(me, accounts: accounts, apart: [alerts, side]))
        #expect(!MailAllAccounts.canLeave(me, accounts: [me], apart: []))
    }

    @Test func keptPerAccountAndReadBack() throws {
        let settings = try #require(UserDefaults(suiteName: "yab-all-accounts-" + UUID().uuidString))
        let accounts = [me, alerts]
        #expect(MailAllAccounts.apart(accounts, in: settings).isEmpty)
        MailAllAccounts.keep(alerts, on: false, in: settings)
        #expect(MailAllAccounts.apart(accounts, in: settings) == [alerts])
        #expect(settings.object(forKey: "mail.all.\(alerts)") as? Bool == false)
        MailAllAccounts.keep(alerts, on: true, in: settings)
        // On is the default: nothing kept.
        #expect(settings.object(forKey: "mail.all.\(alerts)") == nil)
        #expect(MailAllAccounts.apart(accounts, in: settings).isEmpty)
        // Never synced, as an account's notifications aren't.
        #expect(!SyncShapes.syncs(MailAllAccounts.key(alerts)))
    }

    @Test func allAccountsCountsOnlyTheAccountsInIt() {
        let accounts = [me, alerts]
        let needs = [me: 3, alerts: 5]
        #expect(MailAllAccounts.total(needs, accounts: accounts, apart: []) == 8)
        #expect(MailAllAccounts.total(needs, accounts: accounts, apart: [alerts]) == 3)
        #expect(MailAllAccounts.total(needs, accounts: accounts, apart: [me]) == 5)
    }

    func mail(_ id: String, thread: String, from: String, to: String, subject: String, _ text: String, ago: TimeInterval = 600) -> MailMessage {
        MailMessage(id: id, thread: thread, from: MailPerson.one(from)!, to: [MailPerson(name: "", address: to)],
                    subject: subject, snippet: String(text.prefix(80)), date: now.addingTimeInterval(-ago), labels: ["INBOX", "UNREAD"],
                    text: text)
    }

    func store(_ me: String, _ mails: [MailMessage]) async -> MailStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("all-accounts-\(UUID().uuidString).sqlite")
        let store = MailStore(file: file)
        store.set("me", me)
        store.put(mails)
        await MailSense.run(store, now: now, model: false) {}
        return store
    }

    @Test func thePinAndTheDockLeaveAnAccountKeptApart() async {
        let mine = await store(me, [
            mail("a1", thread: "anna", from: "Anna Lindqvist <anna@fold.studio>", to: me, subject: "Thursday works?",
                 "Can we do the review Thursday? The deck is attached."),
        ])
        let theirs = await store(alerts, [
            mail("d1", thread: "dana", from: "Dana Reyes <dana@status.io>", to: alerts, subject: "Maintenance window",
                 "Could you confirm Saturday 02:00 works for the database maintenance?"),
            mail("j1", thread: "jordan", from: "Jordan Park <jordan@park.dev>", to: alerts, subject: "Alert thresholds",
                 "Can you review the new thresholds before Friday?", ago: 900),
        ])
        let accounts = [me, alerts]
        let stores = [(account: me, store: mine), (account: alerts, store: theirs)]
        let own = MailDesk.needYou(in: mine, now: now), other = MailDesk.needYou(in: theirs, now: now)
        #expect(own > 0 && other > 0)
        let both = MailAllAccounts.needing(stores, accounts: accounts, apart: [], now: now)
        #expect(both.all == own + other)
        let apart = MailAllAccounts.needing(stores, accounts: accounts, apart: [alerts], now: now)
        #expect(apart.all == own)
        #expect(apart.unread <= apart.all)
        // The badge's number, as Count says it, follows.
        #expect(MailNotify.number(.needs, needs: apart.all, unreadNeeds: apart.unread, unread: 0) == own)
    }
}
