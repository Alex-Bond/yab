import Foundation
import SQLite3
import Testing
@testable import MailCore

/// A page of mail lands whole or not at all, and says so: a failed insert
/// used to be dropped silently and the rest of the page committed anyway.
struct MailStoreWriteTests {
    private func mail(_ id: String, text: String? = "Words.") -> MailMessage {
        MailMessage(id: id, thread: "t-" + id, from: MailPerson(name: "Anna", address: "anna@fold.studio"),
                    to: [MailPerson(name: "", address: "me@acme.io")], subject: "Hi", snippet: "Words.",
                    date: Date(timeIntervalSince1970: 1_800_000_000), labels: ["INBOX"], text: text)
    }

    @Test func aPageThatFailsLeavesNothingBehindAndTheNextOneLands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("me@acme.io.sqlite")
        let store = MailStore(file: file)
        #expect(store.put([mail("one")]))
        #expect(store.put([mail("one"), mail("one")]), "the same message again, body and words replaced")

        // Another connection makes one message refuse to go in.
        var other: OpaquePointer?
        #expect(sqlite3_open(file.path, &other) == SQLITE_OK)
        defer { sqlite3_close(other) }
        #expect(sqlite3_exec(other, """
            CREATE TRIGGER refuse BEFORE INSERT ON messages WHEN NEW.id = 'bad'
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """, nil, nil, nil) == SQLITE_OK)

        #expect(!store.put([mail("two"), mail("bad"), mail("three")]))
        #expect(store.message("two") == nil, "rolled back with the rest of its page")
        #expect(store.message("three") == nil)
        #expect(store.message("one") != nil)
        #expect(store.put([mail("four")]), "the store goes on after a failed page")
        #expect(store.message("four") != nil)
    }

    @Test func itsOwnAddressReadsWhileTheQueueWrites() async {
        let store = MailStore(file: MailStore.memory)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for n in 0..<200 { store.set("me", "me\(n % 3)@acme.io") } }
            group.addTask { for _ in 0..<2000 { _ = store.me.count } }
        }
        #expect(store.me.hasPrefix("me") && store.me.hasSuffix("@acme.io"))
    }
}
