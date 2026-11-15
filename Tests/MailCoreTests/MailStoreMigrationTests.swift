import Foundation
import SQLite3
import Testing
@testable import MailCore
import MailCoreFakes

// A store kept by an older Yab, opened by this one (docs/mail.md, Store):
// brought up to date in place, its mail, drafts, snoozes and journal kept,
// never synced again for it; a migration that fails leaves it as it was; a
// reset empties what came from Gmail and nothing of the person's.

@Suite(.serialized)
struct MailStoreMigrationTests {
    func fresh() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mail-migrate-\(UUID().uuidString).sqlite")
    }

    static var latest: String { String(MailStore.migrations.map(\.0).max() ?? MailStore.base) }

    @Test func oldStoreKeepsMail() throws {
        let file = fresh()
        MailStoreV5.write(file)
        let store = MailStore(file: file)

        #expect(store.value("schema") == Self.latest)
        // An older Yab still reads it as its own.
        #expect(store.value("version") == "5")
        #expect(store.messageIDs().count == 50)
        #expect(store.messageIDs(withBodies: true).count == 25)
        // Not synced again: where Gmail's history stood is kept.
        #expect(store.value("history") == "4242")
        #expect(store.value("me") == "me@example.com")
        #expect(store.allOps().map(\.kind) == [.archive, .send])
        #expect(store.draft("d1")?.body == "Sending them Friday.")
        #expect(store.snoozes().map(\.thread) == ["t2"])
        #expect(store.sensed("t0")?.gist == "Wants the numbers")
        #expect(store.ahead("t0", message: "m0") == ["Friday works."])
        let thread = try #require(store.thread("t0"))
        #expect(thread.count == 2 && thread.lastIsMine && thread.unread)
        #expect(store.messages(thread: "t0").first?.text == "Revenue for t0 is in the deck, page 0.")
        // The word index, keyed anew, finds bodies and snippets alike.
        #expect(store.search("revenue t4").map(\.id) == ["t4"])
        #expect(store.search("snippet m7").map(\.id) == ["t3"])
        // Headers the old store had no column for are not known yet.
        #expect(store.message("m0")?.replyTo == nil)
        #expect(store.unknownHeaders(limit: 100).count == 50)
        #expect(store.unknownHeaders(limit: 3) == ["m49", "m48", "m47"])
    }

    @Test func aMessagePutAgainKeepsItsWordsRight() throws {
        let file = fresh()
        MailStoreV5.write(file, count: 6)
        let store = MailStore(file: file)
        var m = try #require(store.message("m2"))
        m.text = "Invoice attached, due Friday."
        m.replyTo = [MailPerson(name: "Billing", address: "billing@fold.studio")]
        store.put([m])
        #expect(store.search("invoice").map(\.id) == ["t1"])
        #expect(store.search("revenue").map(\.id).contains("t1") == false)
        #expect(store.message("m2")?.replyTo == [MailPerson(name: "Billing", address: "billing@fold.studio")])
        // A put that doesn't know the header keeps what is known.
        m.replyTo = nil
        store.put([m])
        #expect(store.message("m2")?.replyTo?.first?.address == "billing@fold.studio")
        store.remove(messages: ["m2"])
        #expect(store.search("invoice").isEmpty)
        #expect(store.search("revenue").count == 2)
    }

    @Test func migrationIsIdempotent() {
        let file = fresh()
        MailStoreV5.write(file)
        _ = MailStore(file: file)
        let once = SQL.snapshot(file)
        _ = MailStore(file: file)
        let twice = SQL.snapshot(file)
        #expect(once == twice)
        #expect(once.contains("meta: schema|" + Self.latest))
        // A store made new is the same shape as one migrated.
        let made = fresh()
        _ = MailStore(file: made)
        #expect(SQL.shape(made) == SQL.shape(file))
    }

    @Test func failedMigrationRollsBack() throws {
        let file = fresh()
        MailStoreV5.write(file)
        let broken = MailStore.migrations + [(99, "ALTER TABLE messages ADD COLUMN broken TEXT; CREATE TABLE half(x); NOT SQL AT ALL;")]
        do {
            let store = MailStore(file: file, migrations: broken)
            // Up to the last one that worked, nothing of the one that didn't.
            #expect(store.value("schema") == Self.latest)
            #expect(!SQL.columns(file, "messages").contains("broken"))
            #expect(SQL.columns(file, "half").isEmpty)
            // And it reads.
            #expect(store.messageIDs().count == 50)
            #expect(store.threads(label: "INBOX").count == 25)
            #expect(store.search("revenue").count == 25)
        }
        // Failing from the base too: the file stays at 5 and keeps its mail.
        let other = fresh()
        MailStoreV5.write(other)
        do {
            let store = MailStore(file: other, migrations: [(6, "CREATE TABLE half(x); NOT SQL AT ALL;")])
            #expect(store.value("schema") == "5")
            #expect(SQL.columns(other, "half").isEmpty)
            #expect(store.value("history") == "4242")
            #expect(store.draft("d1") != nil)
        }
        // Fixed, the next launch brings it up to date.
        let store = MailStore(file: other)
        #expect(store.value("schema") == Self.latest)
        #expect(store.messageIDs().count == 50)
        #expect(store.search("revenue").count == 25)
    }

    @Test func resetDropsCache() throws {
        let file = fresh()
        MailStoreV5.write(file)
        do {
            let store = MailStore(file: file)
            #expect(store.value("reset") == String(MailStore.reset))
            #expect(store.messageIDs().count == 50)
        }
        do {
            let store = MailStore(file: file, reset: MailStore.reset + 1)
            #expect(store.messageIDs().isEmpty)
            #expect(store.search("revenue").isEmpty)
            #expect(store.value("history") == nil && store.value("synced") == nil)
            // The person's work stays: drafts, snoozes, the journal, and who the account is.
            #expect(store.draft("d1")?.body == "Sending them Friday.")
            #expect(store.snoozes().map(\.thread) == ["t2"])
            #expect(store.allOps().count == 2)
            #expect(store.value("me") == "me@example.com")
            #expect(store.value("reset") == String(MailStore.reset + 1))
            store.put([MailMessage(id: "n1", thread: "tn", from: MailPerson(name: "", address: "x@y.z"), subject: "After", date: Date(),
                                   labels: ["INBOX"], text: "Came after the reset.")])
        }
        // Once: the same reset again leaves the mail that came since.
        let store = MailStore(file: file, reset: MailStore.reset + 1)
        #expect(store.messageIDs() == ["n1"])
        #expect(store.search("reset").map(\.id) == ["tn"])
    }

    @Test func olderStoresStartOver() {
        let file = fresh()
        MailStoreV5.write(file)
        SQL.on(file, "UPDATE meta SET v = '4' WHERE k = 'version'")
        let store = MailStore(file: file)
        #expect(store.messageIDs().isEmpty)
        #expect(store.value("schema") == Self.latest)
        #expect(store.value("history") == nil)
    }

    @Test func aStoreInMemory() {
        let store = MailStore(file: MailStore.memory)
        store.put([MailMessage(id: "a", thread: "t", from: MailPerson(name: "", address: "x@y.z"), subject: "Hello", date: Date(),
                               labels: ["INBOX"], replyTo: [], text: "In memory.")])
        #expect(store.search("memory").map(\.id) == ["t"])
        #expect(store.value("schema") == Self.latest)
        #expect(store.unknownHeaders(limit: 5).isEmpty)
    }
}
