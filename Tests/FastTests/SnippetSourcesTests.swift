import Foundation
import SQLite3
import Testing
@testable import Fast

// Bring In on Settings › Snippets (SnippetSources.swift): each app's
// snippets read as they keep or export them, their placeholders made
// Yab's, names that ";" takes, and a name already here numbered rather
// than written over.

struct SnippetSourcesTests {
    @Test func raycastsExportComesInWithItsPlaceholdersMadeYabs() throws {
        // The file Raycast 1.x's Export Snippets writes (its own exporter: name, text, keyword, tags).
        let json = """
        [
          {"name": "Thanks", "text": "Thanks, I'll take a look today.", "keyword": ";thx"},
          {"name": "Bug report", "text": "Steps: {cursor}\\nSeen on {date}", "keyword": "!bug", "tags": ["work"]},
          {"name": "Meet", "text": "Pick a time: {argument name=\\"time\\" default=\\"3pm\\"} {clipboard}"},
          {"name": "Ask", "text": "{selection} at {time}", "keyword": "q"},
          {"name": "Empty", "text": "  "}
        ]
        """
        let found = try #require(SnippetSource.raycast(json: Data(json.utf8)))
        #expect(found.map(\.name) == ["thx", "bug", "meet", "q"])
        #expect(found[1].body == "Steps: {{…}}\nSeen on {date}")
        #expect(found[1].note == "{cursor} is a place to type over")
        #expect(found[2].body == "Pick a time: {{time}} {clipboard}")
        #expect(found[3].body == "{selection} at {time}")
        #expect(found[3].odd)
        #expect(found[3].note == "{selection}, {time} stay as written")
        // Not Raycast's shape: nothing.
        #expect(SnippetSource.raycast(json: Data(#"{"commands": []}"#.utf8)) == nil)
    }

    @Test func alfredsSnippetFilesAndFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("alfred-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let collection = support.appendingPathComponent("Alfred/Alfred.alfredpreferences/snippets/Work", isDirectory: true)
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        let one = #"{"alfredsnippet":{"snippet":"Best,\nSam{cursor}","uid":"A1","name":"Sign-off","keyword":"sig"}}"#
        try Data(one.utf8).write(to: collection.appendingPathComponent("Sign-off [A1].json"))
        try Data(#"{"alfredsnippet":{"snippet":"On {date:short}","uid":"B2","name":"Day","keyword":""}}"#.utf8)
            .write(to: collection.appendingPathComponent("Day [B2].json"))
        let found = try #require(SnippetSource.alfred.onThisMac(home: home))
        #expect(found.map(\.name).sorted() == ["day", "sig"])
        #expect(found.first { $0.name == "sig" }?.body == "Best,\nSam{{…}}")
        #expect(found.first { $0.name == "day" }?.odd == true)
        #expect(SnippetSource.found(home: home).map(\.source) == [.alfred])
    }

    @Test func espansosMatchesInTheirFormsOfYAML() {
        let yaml = """
        # espanso match file
        matches:
          - trigger: ":sig"
            replace: "Best,\\nSam"

          - trigger: ':omw'
            replace: 'On my way, it''s close'
          - triggers: [":hi", ":hello"]
            replace: Hello there
          - trigger: ":addr"
            replace: |
              Acme Labs
              Market St
          - triggers:
              - ":br"
              - ":brb"
            replace: "Back in $|$ minutes"
          - trigger: ":now"
            replace: "It is {{time}}"
            vars:
              - name: time
                type: date
          - trigger: ":form"
            form: "Hi [[name]]"
        """
        let found = SnippetSource.espanso(yaml: yaml)
        #expect(found.map(\.name) == ["sig", "omw", "hi", "addr", "br", "now"])
        #expect(found[0].body == "Best,\nSam")
        #expect(found[1].body == "On my way, it's close")
        #expect(found[2].body == "Hello there")
        #expect(found[3].body == "Acme Labs\nMarket St")
        #expect(found[4].body == "Back in {{…}} minutes")
        #expect(found[5].odd)
    }

    @Test func textExpandersCSVWithQuotesAndLines() {
        let csv = "sig,\"Best,\nSam\",Sign-off\r\nty,Thank you %| so much,\n\"addr\",\"Say \"\"hi\"\" %clipboard\",Address\nfill,Dear %filltext:name=who%,\n"
        let found = SnippetSource.textExpander(csv: csv)
        #expect(found.map(\.name) == ["sig", "ty", "addr", "fill"])
        #expect(found[0].body == "Best,\nSam")
        #expect(found[1].body == "Thank you {{…}} so much")
        #expect(found[2].body == "Say \"hi\" {clipboard}")
        #expect(found[3].odd)
    }

    @Test func textReplacementsFromTheirDatabaseLeavingTheDeleted() throws {
        let folder = MailSnippetTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("TextReplacements.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE ZTEXTREPLACEMENTENTRY (Z_PK INTEGER PRIMARY KEY, ZWASDELETED INTEGER, ZTIMESTAMP TIMESTAMP, ZPHRASE VARCHAR, ZSHORTCUT VARCHAR);
        INSERT INTO ZTEXTREPLACEMENTENTRY VALUES (1, 0, 2, 'On my way!', 'omw');
        INSERT INTO ZTEXTREPLACEMENTENTRY VALUES (2, 1, 3, 'Gone', 'gone');
        INSERT INTO ZTEXTREPLACEMENTENTRY VALUES (3, NULL, 1, 'sam@example.com', '@@');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let found = try #require(SnippetSource.textReplacements(db: file))
        #expect(found.map(\.name) == ["sam-example-com", "omw"])
        #expect(found.map(\.body) == ["sam@example.com", "On my way!"])
    }

    @Test func namesAreWhatSemicolonTakes() {
        #expect(SnippetSource.name(keyword: ";sig", else: "x") == "sig")
        #expect(SnippetSource.name(keyword: "::my addr", else: "x") == "myaddr")
        #expect(SnippetSource.name(keyword: "", else: "Weekly status: done") == "weekly-status-done")
        #expect(SnippetSource.name(keyword: nil, else: "!!!") == "snippet")
        #expect(SnippetSource.name(keyword: "café", else: "x") == "café")
    }

    @MainActor @Test func aTakenNameIsNumberedAndTheSameOneLeftOut() throws {
        let folder = MailSnippetTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snippets = MailSnippets(file: folder.appendingPathComponent("snippets.json"))
        snippets.add(name: "sig", body: "Best, S")
        snippets.add(name: "omw", body: "On my way!")
        let planned = snippets.planned([
            FoundSnippet(name: "omw", body: "On my way!"),
            FoundSnippet(name: "sig", body: "Cheers"),
            FoundSnippet(name: "sig", body: "Thanks"),
            FoundSnippet(name: "new", body: "Fresh"),
        ])
        #expect(planned.map(\.name) == ["omw", "sig2", "sig3", "new"])
        #expect(planned.map(\.take) == [false, true, true, true])
        #expect(planned[0].note == "Already here")
        #expect(planned[1].note == ";sig is taken")
        var chosen = planned
        chosen[3].take = false
        let ids = snippets.bringIn(chosen)
        #expect(ids.count == 2)
        #expect(snippets.all.map(\.name) == ["sig", "omw", "sig2", "sig3"])
        // Written once, and read back.
        #expect(MailSnippets(file: folder.appendingPathComponent("snippets.json")).all.count == 4)
    }

    @Test func superhumansAnswerFromTheAgent() throws {
        // As an agent answers: a word before it is let be.
        let answer = """
        Here they are:
        [{"name": "Intro", "body": "Hi {first_name},\\r\\nmeet Anna.\\n{my_first_name}", "to": "", "cc": "", "bcc": "", "subject": "Intro"},
         {"name": "Follow up", "body": "Does {calendar_link} work?", "to": "", "subject": ""},
         {"name": "Weekly", "body": "This week:", "to": "team@fold.studio", "cc": "anna@fold.studio", "subject": "Weekly update"},
         {"name": "Empty", "body": " "}]
        """
        let found = try #require(SnippetSource.superhuman(answer: answer))
        #expect(found.map(\.name) == ["intro", "follow-up", "weekly"])
        #expect(found[0].body == "Hi {first_name},\nmeet Anna.\n{my_name}")
        #expect(found[0].subject == "Intro")
        #expect(found[1].odd)
        #expect(found[1].note == "{calendar_link} stays as written")
        #expect(found[2].to == "team@fold.studio")
        #expect(found[2].cc == "anna@fold.studio")
        #expect(SnippetSource.superhuman(answer: #"{"error": "signin"}"#) == nil)
        #expect(SnippetSource.superhuman(answer: "[]")?.isEmpty == true)
    }

    @MainActor @Test func aMailSnippetComesInMailOnly() {
        let folder = MailSnippetTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snippets = MailSnippets(file: folder.appendingPathComponent("snippets.json"))
        var weekly = FoundSnippet(name: "weekly", body: "This week:")
        weekly.to = "team@fold.studio"
        weekly.subject = "Weekly update"
        snippets.bringIn([weekly, FoundSnippet(name: "thx", body: "Thanks!")])
        #expect(snippets.named("weekly")?.mailOnly == true)
        #expect(snippets.named("weekly")?.subject == "Weekly update")
        #expect(snippets.named("thx")?.mailOnly == false)
    }

    @Test func aFileIsToldApartByWhatIsInIt() throws {
        let folder = MailSnippetTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let raycast = folder.appendingPathComponent("Snippets 2026-10-19.json")
        try Data(#"[{"name":"A","text":"a","keyword":"a"}]"#.utf8).write(to: raycast)
        #expect(SnippetSource.read(file: raycast)?.source == .raycast)
        let alfred = folder.appendingPathComponent("one.json")
        try Data(#"{"alfredsnippet":{"snippet":"b","keyword":"b"}}"#.utf8).write(to: alfred)
        #expect(SnippetSource.read(file: alfred)?.source == .alfred)
        let espanso = folder.appendingPathComponent("base.yml")
        try Data("matches:\n  - trigger: \":c\"\n    replace: c\n".utf8).write(to: espanso)
        #expect(SnippetSource.read(file: espanso)?.found.map(\.name) == ["c"])
        let other = folder.appendingPathComponent("other.json")
        try Data(#"{"hello": 1}"#.utf8).write(to: other)
        #expect(SnippetSource.read(file: other) == nil)
    }
}
