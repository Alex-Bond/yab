import Foundation
import Testing
import SyncKit
@testable import Fast

/// Gmail's data never goes to the sync server, even sealed (docs/casa.md,
/// Sync): a chat mail went into, memory mail wrote, mail's splits and
/// snippets, a routine's mail, a sign-in's steps stay on their Mac.
@MainActor
struct SyncMailTests {
    init() { SyncShapes.register() }

    @Test func aChatWithMailInItIsKnown() {
        func chat(_ items: [ChatItem], mail: Bool? = nil) -> Chat {
            Chat(id: "c", title: "T", began: .field, cli: "claude", items: items, state: "done", answer: "",
                 started: Date(), updated: Date(), mail: mail)
        }
        let asked = ChatItem(id: "a", kind: .asked, text: "Book a table", state: .done)
        #expect(!chat([asked]).withMail)
        #expect(chat([asked, ChatItem(id: "t", kind: .tool, name: "mail_read", detail: "", state: .done)]).withMail)
        #expect(chat([asked, ChatItem(id: "t", kind: .tool, name: "mail_search", state: .done)]).withMail)
        var given = asked
        given.detail = "t:github.com|GitHub\nm:Invoice for October"
        #expect(chat([given]).withMail)
        #expect(chat([asked], mail: true).withMail)
        // Another server's tool of that name is not mail's.
        #expect(!chat([asked, ChatItem(id: "t", kind: .tool, name: "other/mail_read", state: .done)]).withMail)
    }

    @Test func memoryMailWroteStaysOffSync() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mem-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        for sub in ["episodic", "people"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "Likes short answers.".write(to: folder.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        let person = MailPeople.render(nil, facts: MailPeople.Facts(name: "Mark Chen", address: "mark@north.test", threads: 5, last: Date(),
                                                                   title: nil, theirLines: 3, theyGreet: true, yourLines: 2, youGreet: "Hi"),
                                       open: [], now: Date())
        try person.write(to: folder.appendingPathComponent("people/mark-chen.md"), atomically: true, encoding: .utf8)
        try "# Ana\n\n- Met at the launch\n\n\(Memory.mailMark)\n".write(to: folder.appendingPathComponent("people/ana.md"), atomically: true, encoding: .utf8)
        try "# Bo\n\n- Plays chess\n".write(to: folder.appendingPathComponent("people/bo.md"), atomically: true, encoding: .utf8)
        try "# 2026-10-07\n\n## 09:00 Booked a table\nAt Noma.\n\n## 10:00 Read the invoice\nTotal 120.\n\(Memory.mailMark)\n"
            .write(to: folder.appendingPathComponent("episodic/2026-10-07.md"), atomically: true, encoding: .utf8)

        let out = SyncShapes.memory(in: folder)
        #expect(out["USER.md"] != nil && out["people/bo.md"] != nil)
        #expect(out["people/mark-chen.md"] == nil && out["people/ana.md"] == nil)
        let days = out.values.compactMap { $0["text"]?.string }.filter { $0.hasPrefix("## ") }
        #expect(days.count == 1 && days[0].contains("Booked a table"))
    }

    @Test func aTaskWithoutMailSeesNoneOfIt() throws {
        let day = "# 2026-10-07\n\n## 09:00 Booked a table\nAt Noma.\n\n## 10:00 Read the invoice\nTotal 120.\n\(Memory.mailMark)\n\n## 11:00 Walked\nIn the park."
        let seen = try #require(Memory.seen("episodic/2026-10-07.md", day, mail: false))
        #expect(seen.contains("Booked a table") && seen.contains("Walked") && !seen.contains("invoice"))
        // The rest stay on their lines, for a hit's line number.
        #expect(seen.components(separatedBy: "\n").count == day.components(separatedBy: "\n").count)
        #expect(Memory.seen("people/ana.md", "# Ana\n\(Memory.mailMark)", mail: false) == nil)
        #expect(Memory.seen("people/ana.md", "# Ana\n\(Memory.mailMark)", mail: true) != nil)
        #expect(Memory.seen("people/bo.md", "# Bo\n- Plays chess", mail: false) != nil)
    }

    @Test func aTaskThatReadMailWritesOnlyWhatStaysHere() {
        #expect(Memory.closedToMail("USER.md", body: ""))
        #expect(Memory.closedToMail("MEMORY.md", body: "# Memory\n\n- Short answers"))
        #expect(Memory.closedToMail("people/bo.md", body: "# Bo\n\n- Plays chess\n"))
        #expect(!Memory.closedToMail("people/new.md", body: ""))
        #expect(!Memory.closedToMail("people/ana.md", body: "# Ana\n\n- Met at the launch\n\n\(Memory.mailMark)\n"))
        #expect(!Memory.closedToMail("episodic/2026-10-07.md", body: "# 2026-10-07\n\n## 09:00 Booked a table\n"))
    }

    @Test func mailSplitsAndSnippetsStayOnTheirMac() {
        let out = SyncShapes.settings(["mail.splits": Data([1]), "mail.order": ["q:from:mark@north.test"], "mail.lists": Data([2]),
                                       "mail.splits.hide": ["q:subject:\"Invoice\""], "mail.motion": true])
        #expect(Set(out.keys) == ["mail.motion"])
        #expect(!SyncShapes.files.contains { $0.hasPrefix("mail/") })
    }

    @Test func aRoutineOnMailKeepsWhatItDidOnItsMac() throws {
        var routine = Routine(id: "r1", when: "on mail needs", prompt: "Draft a reply", last: Date())
        routine.mailSince = Date(timeIntervalSince1970: 100)
        routine.mailDone = ["me@gmail.test|18f0a"]
        let out = SyncShapes.routines([routine], device: "mac-a")
        #expect(out["r1"]?["mailDone"] == nil && out["r1"]?["mailSince"] == nil)
        #expect(out["r1"]?["prompt"] == "Draft a reply")
    }

    @Test func aSignInsStepsStayOutOfHistory() throws {
        func url(_ text: String) throws -> URL { try #require(URL(string: text)) }
        #expect(History.signInStep(try url("http://127.0.0.1:52144/oauth?state=abc&code=4/0Ad&scope=gmail")))
        #expect(History.signInStep(try url("https://accounts.google.com/o/oauth2/v2/auth?client_id=1.apps&redirect_uri=http://127.0.0.1&login_hint=me@gmail.test")))
        #expect(History.signInStep(try url("https://accounts.google.com/signin?login_hint=me@gmail.test")))
        #expect(!History.signInStep(try url("https://github.com/sam?tab=repositories")))
        #expect(!History.signInStep(try url("https://example.test/search?code=swift")))
        let visits = [
            Visit(url: "http://127.0.0.1:52144/oauth?state=abc&code=4/0Ad", key: "127.0.0.1:52144/oauth", title: "", count: 1, last: Date()),
            Visit(url: "https://github.com/", key: "github.com", title: "GitHub", count: 3, last: Date()),
        ]
        #expect(Set(SyncShapes.visits(visits).keys) == ["github.com"])
    }
}
