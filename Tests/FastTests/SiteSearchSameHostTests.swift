import Foundation
import Testing
@testable import Fast

/// Feedback #2027 (register R2580): several searches of your own on one
/// host. Internal tools often live under one host on different paths, so a
/// search is known by its own identity, not by its host, as Chromium keeps one
/// TemplateURL per keyword on the same host.
@MainActor @Suite(.serialized)
struct SiteSearchSameHostTests {
    private func isolated(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "site-search-same-host-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = UUID().uuidString.lowercased().prefix(8).description
        try Scopes.withSitesForTesting(defaults) { try body(defaults, token) }
    }

    private func own(on host: String) -> [Scope] {
        Scopes.all.filter { $0.own == true && $0.allHosts.contains(host) }
    }

    /// The reporter's steps: Log ID lookup, then Service monitor, on one host.
    @Test func twoSearchesOnOneHostBothStay() throws {
        try isolated { _, token in
            let host = "tools-\(token).invalid"
            let logs = try #require(Scopes.add(name: "Log ID lookup",
                                               template: "https://\(host)/logs/search?logId=%s", keyword: "log-" + token))
            let monitor = try #require(Scopes.add(name: "Service monitor",
                                                  template: "https://\(host)/monitor/overview?service=%s", keyword: "svc-" + token))
            #expect(logs.id != monitor.id, "each search has its own identity")

            let saved = own(on: host)
            #expect(saved.map(\.name).sorted() == ["Log ID lookup", "Service monitor"])
            #expect(Set(saved.map(\.id)).count == saved.count)
            let log = try #require(saved.first { $0.name == "Log ID lookup" })
            let svc = try #require(saved.first { $0.name == "Service monitor" })
            #expect(log.aliases == ["log-" + token])
            #expect(svc.aliases == ["svc-" + token])
            #expect(log.url(for: "abc 1")?.absoluteString == "https://\(host)/logs/search?logId=abc%201")
            #expect(svc.url(for: "api")?.absoluteString == "https://\(host)/monitor/overview?service=api")
            // Both are on, each a row of its own in Settings › Field.
            #expect(Scopes.on.filter { $0.own == true && $0.allHosts.contains(host) }.count == 2)
        }
    }

    /// A third search on the host, then editing one's address and keyword,
    /// touches only that one.
    @Test func editingOneSearchLeavesItsNeighboursAlone() throws {
        try isolated { _, token in
            let host = "tools-\(token).invalid"
            let a = try #require(Scopes.add(name: "A", template: "https://\(host)/a?q=%s", keyword: "a-" + token))
            let b = try #require(Scopes.add(name: "B", template: "https://\(host)/b?q=%s", keyword: "b-" + token))
            let c = try #require(Scopes.add(name: "C", template: "https://www.\(host)/c?x=%s", keyword: ""))
            Scopes.setTemplate("https://\(host)/b2?q=%s", for: b)
            Scopes.setKeyword("bee-" + token, for: b)
            Scopes.set(c, on: false)
            defer { Scopes.set(c, on: true) }

            let saved = own(on: host)
            #expect(saved.count == 3)
            let byName = Dictionary(uniqueKeysWithValues: saved.map { ($0.name, $0) })
            #expect(byName["A"]?.template == a.template && byName["A"]?.aliases == ["a-" + token])
            #expect(byName["B"]?.template == "https://\(host)/b2?q=%s" && byName["B"]?.aliases == ["bee-" + token])
            #expect(byName["C"]?.template == c.template && byName["C"]?.aliases == [])
            #expect(Scopes.isOn(a) && Scopes.isOn(b) && !Scopes.isOn(c))
        }
    }

    /// Adding the very same address again is the same search: its name and
    /// keyword change, no second row appears. The card's keyword check
    /// judges the draft as the search it would replace.
    @Test func theSameAddressAgainReplacesThatSearchOnly() throws {
        try isolated { _, token in
            let host = "tools-\(token).invalid"
            let first = try #require(Scopes.add(name: "Logs", template: "https://\(host)/logs?id=%s", keyword: "l-" + token))
            _ = try #require(Scopes.add(name: "Monitor", template: "https://\(host)/mon?s=%s", keyword: "m-" + token))
            let draft = try #require(Scopes.draft(name: "Logs again", template: first.template))
            #expect(draft.id == first.id && Scopes.aliasProblem("l-" + token, for: draft) == nil)
            let again = try #require(Scopes.add(name: "Logs again", template: first.template, keyword: "l-" + token))
            #expect(again.id == first.id)
            #expect(own(on: host).map(\.name).sorted() == ["Logs again", "Monitor"])
        }
    }

    /// A scopes.json from before the fix, each search of your own under its
    /// host, reads whole: every entry, its keyword and what was asked of it.
    @Test func anOldFileKeepsEveryEntryAndItsKeyword() throws {
        try isolated { defaults, token in
            let a = "a-\(token).invalid", b = "b-\(token).invalid"
            defaults.set([a: "ka-" + token, b: "kb-" + token], forKey: Scopes.keywordsKey)
            let file = """
            {"learned":[
              {"id":"\(a)","name":"Log ID lookup","template":"https://\(a)/logs/search?logId=%s","aliases":[],"hosts":[],"learned":false,"own":true},
              {"id":"\(b)","name":"Service monitor","template":"https://\(b)/monitor/overview?service=%s","aliases":[],"hosts":[],"learned":false,"own":true},
              {"id":"learned-\(token).invalid","name":"Learned","template":"https://learned-\(token).invalid/?q=%s","aliases":[],"hosts":[],"colour":"#112233","learned":true}
            ],"asked":{"\(a)":["one"]}}
            """
            #expect(Scopes.readForTesting(Data(file.utf8)) == false, "nothing shared an id: nothing moves")
            let mine = Scopes.all.filter { $0.removable }
            #expect(mine.map(\.id) == [a, b, "learned-\(token).invalid"])
            #expect(mine.map(\.host) == [a, b, "learned-\(token).invalid"])
            #expect(mine[0].aliases == ["ka-" + token] && mine[1].aliases == ["kb-" + token])
            #expect(mine[2].color == "#112233")
            #expect(Scopes.recent(mine[0], matching: "") == ["one"])
            // And a second search on an old entry's host is now its own.
            _ = try #require(Scopes.add(name: "Second", template: "https://\(a)/other?q=%s", keyword: ""))
            #expect(own(on: a).map(\.name) == ["Log ID lookup", "Second"])
        }
    }

    /// An old search of your own kept under a host the app searches itself
    /// shared GitHub's id, so one keyword was both. Read again, it is a
    /// search of its own with what it had, and GitHub is still there.
    @Test func anOldSearchSharingAPresetsIdIsSeparatedWithWhatItHad() throws {
        try isolated { defaults, token in
            let template = "https://github.com/issues-\(token)?q=%s"
            defaults.set(["github.com": "iss-" + token], forKey: Scopes.keywordsKey)
            let file = """
            {"learned":[{"id":"github.com","name":"Issues","template":"\(template)","aliases":[],"hosts":[],"learned":false,"own":true}],
             "asked":{"github.com":["bug"]}}
            """
            #expect(Scopes.readForTesting(Data(file.utf8)) == true)
            #expect(Set(Scopes.all.map(\.id)).count == Scopes.all.count, "no two searches share an id")
            let issues = try #require(Scopes.all.first { $0.name == "Issues" })
            #expect(issues.id == template && issues.host == "github.com" && issues.own == true)
            #expect(issues.aliases == ["iss-" + token])
            #expect(issues.url(for: "x")?.absoluteString == "https://github.com/issues-\(token)?q=x")
            #expect(Scopes.recent(issues, matching: "") == ["bug"])
            #expect(Scopes.all.contains { $0.id == "github.com" && $0.name == "GitHub" })
            #expect((defaults.dictionary(forKey: Scopes.keywordsKey) as? [String: String])?[template] == "iss-" + token)
        }
    }

    /// A keyword another search on the host already has is still refused,
    /// as before, with the words the card already shows.
    @Test func aSecondSearchCannotTakeTheFirstOnesKeyword() throws {
        try isolated { _, token in
            let host = "tools-\(token).invalid"
            _ = try #require(Scopes.add(name: "First", template: "https://\(host)/one?q=%s", keyword: "k-" + token))
            #expect(Scopes.add(name: "Second", template: "https://\(host)/two?q=%s", keyword: "k-" + token) == nil)
            #expect(own(on: host).map(\.name) == ["First"])
        }
    }
}
