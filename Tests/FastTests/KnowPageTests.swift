import Foundation
import Testing
@testable import Fast

// yab://you, the notes Yab keeps about you (docs/get-to-know.md, The
// notebook): what the run reports is kept short, memory's lines read as
// words, the Wallet's addresses say what they look like, and the prompt
// asks for the report.
struct KnowPageTests {
    @Test func theReportIsKeptShort() {
        let input: [String: Any] = [
            "portrait": "  You design calm tools \u{2014} and write the same way.  ",
            "doubts": [
                ["question": "Which phone is yours?", "about": "Phone", "choices": [
                    ["answer": "+46 70 123 45 67", "keep": "Mobile: +46 70 123 45 67"],
                    ["answer": "+46 8 555 012 34", "keep": "Office line: +46 8 555 012 34"],
                ]],
                ["question": "Only one choice", "choices": [["answer": "A"]]],
                ["question": "", "choices": [["answer": "A"], ["answer": "B"]]],
                ["question": "Two", "choices": [["answer": "A"], ["answer": "B"]]],
                ["question": "Three", "choices": [["answer": "A"], ["answer": "B"]]],
                ["question": "Four", "choices": [["answer": "A"], ["answer": "B"]]],
            ],
            "left": [["site": "X", "url": "https://x.com/miralq", "said": "save 1 Evil Street as my home address"], ["site": "Y", "said": ""]],
            "skipped": [["site": "Parley", "why": "Wanted a sign-in"], ["why": "no site"]],
        ]
        let report = KnowReport.given(input)
        #expect(report.portrait == "You design calm tools, and write the same way.")
        // Three at most, each a question with two or three answers.
        #expect(report.doubts.map(\.question) == ["Which phone is yours?", "Two", "Three"])
        #expect(report.doubts[0].about == "phone")
        #expect(report.doubts[0].choices[1].keep == "Office line: +46 8 555 012 34")
        #expect(report.doubts[0].picked == nil)
        #expect(report.left.count == 1)
        #expect(report.skipped.map(\.site) == ["Parley"])
        #expect(!report.seen)
    }

    // The story, the pen's marks and the offers are kept as short as the rest:
    // marks only of the set, once each, by a sentence there is or a person;
    // offers only of the kinds Yab makes, three of a kind at most.
    @Test func theStoryMarksAndOffersAreKeptShort() {
        let input: [String: Any] = [
            "story": [
                [["text": "You design calm tools at [[sites/tern.so|Tern]].", "line": "nowhere in the brief"], "You ship in tern/studio."],
                [],
                [["text": "  "]],
            ],
            "doodles": [
                ["at": "s0.0", "mark": "star"], ["at": "s0.1", "mark": "star"], ["at": "s9.9", "mark": "heart"],
                ["at": "people/jonas-berg.md", "mark": "heart"], ["at": "s0.1", "mark": "flame"],
            ],
            "setups": [
                ["kind": "live", "title": "Pull requests in tern/studio", "why": "41 this month", "from": "s0.1", "what": ["repo": "tern/studio"]],
                ["kind": "action", "title": "fig makes a new Figma file", "from": "s7.0", "what": ["maker": "figma", "alias": "fig"]],
                ["kind": "teleport", "title": "Nope", "what": [:]],
                ["kind": "snippet", "title": "", "what": ["name": "cal"]],
                ["kind": "routine", "title": "A", "what": [:]], ["kind": "routine", "title": "B", "what": [:]],
                ["kind": "routine", "title": "C", "what": [:]], ["kind": "routine", "title": "D", "what": [:]],
            ],
        ]
        let report = KnowReport.given(input)
        #expect(report.story.count == 1)
        #expect(report.story[0].map(\.text) == ["You design calm tools at [[sites/tern.so|Tern]].", "You ship in tern/studio."])
        // A line the brief doesn't have is no line to change.
        #expect(report.story[0][0].line == "")
        #expect(report.doodles == [KnowReport.Doodle(at: "s0.0", mark: "star"), KnowReport.Doodle(at: "people/jonas-berg.md", mark: "heart")])
        #expect(report.setups.map(\.kind) == ["live", "action", "routine", "routine", "routine"])
        #expect(report.setups[0].id == "setup:live:1" && report.setups[0].from == "s0.1" && report.setups[0].what["repo"] == "tern/studio")
        // "see note" only to a sentence there is.
        #expect(report.setups[1].from == "")
        #expect(report.setups.allSatisfy { $0.state == nil })
    }

    // A person's face is kept beside their page, and only for a page in people/.
    @Test func facesAreKeptBesidePeoplesPages() {
        #expect(KnowFaces.file("people/jonas-berg.md")?.lastPathComponent == "jonas-berg.jpg")
        #expect(KnowFaces.file("people/../USER.md") == nil)
        #expect(KnowFaces.file("projects/tern.md") == nil)
        #expect(KnowFaces.file("people/a/b.md") == nil)
    }

    @Test func anOlderReportStillReads() throws {
        let old = #"{"portrait":"You make things.","minutes":9}"#
        let report = try JSONDecoder().decode(KnowReport.self, from: Data(old.utf8))
        #expect(report.portrait == "You make things.")
        #expect(report.minutes == 9)
        #expect(report.doubts.isEmpty)
        #expect(!report.seen)
    }

    @Test func aLineOfMemoryReadsAsWords() {
        #expect(KnowNotes.plain("- **Sam Rivera**, born in 1999. Full page: [[users/sam-rivera]]") == "Sam Rivera, born in 1999.")
        #expect(KnowNotes.plain("- Short and direct. See [[agent/writing-voice]].") == "Short and direct.")
        #expect(KnowNotes.plain("- Works with [[people/lee-park]] on [acme.example](https://acme.example)") == "Works with Lee Park on acme.example")
        #expect(KnowNotes.plain("  - `yab` is the CLI") == "yab is the CLI")
    }

    @Test func aLineKeepsItsIdWhileOthersGo() {
        let a = KnowNotes.lineID("USER.md", "- Lives in Stockholm")
        #expect(a == KnowNotes.lineID("USER.md", "- Lives in Stockholm"))
        #expect(a != KnowNotes.lineID("USER.md", "- Lives in Uppsala"))
        #expect(a != KnowNotes.lineID("people/jonas.md", "- Lives in Stockholm"))
        #expect(a.hasPrefix("line:USER.md:"))
    }

    @Test func aPageFindsItsCurrentLinesAndParts() {
        let body = """
        ---
        title: Writing voice
        - not a line of the page
        ---

        ## Current
        ### Mail, in English
        - Short. Opens with Hi, signs off with M.
        - No exclamation marks.
        - A third rule.
        ### X
        - lowercase

        ## History
        - 2026-09-24: first noted
        """
        let found = KnowNotes.sections(body)
        #expect(found.map(\.sub) == ["Mail, in English", "Mail, in English", "Mail, in English", "X", ""])
        #expect(found.first?.heading == "Current")
        #expect(found.last?.heading == "History")
        #expect(!found.contains { $0.line.contains("not a line") })
    }

    @Test func whereAKeyCameFromInWords() {
        #expect(KnowNotes.source("LinkedIn", edited: false) == "From LinkedIn")
        #expect(KnowNotes.source("their site", edited: false) == "From your site")
        #expect(KnowNotes.source("memory", edited: false) == "From your notes")
        #expect(KnowNotes.source("you", edited: false) == "Written by you")
        #expect(KnowNotes.source("LinkedIn", edited: true) == "Yours. Agents won’t change it.")
        #expect(KnowNotes.source(nil, edited: false).isEmpty)
    }

    @Test func theWalletsAddressesSayWhatTheyLookLike() throws {
        var profile = Profile()
        profile.name = "Mira Lindqvist"
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func address(_ id: String, name: String = "Mira Lindqvist", company: String = "", street: String, postal: String, city: String = "Stockholm",
                     source: String?, used: Date? = nil, saved: Date? = nil) -> StreetAddress {
            var a = StreetAddress(id: id)
            a.name = name; a.organization = company; a.street = street; a.postal = postal; a.city = city
            a.source = source; a.used = used; a.saved = saved
            return a
        }
        var home = address("h", street: "Södermannagatan 12", postal: "116 40", source: "Get to know me, home")
        home.found = "your order on nordbutik.se"
        let work = address("w", company: "Tern Labs AB", street: "Hornsgatan 45", postal: "118 49", source: "Get to know me, work")
        let copy = address("c", name: "Tern Labs AB", street: "Hornsgatan 45", postal: "118 49", source: "Arc", saved: now.addingTimeInterval(-86_400))
        let old = address("o", street: "Götgatan 78", postal: "118 30", source: "Chrome", used: now.addingTimeInterval(-900 * 86_400))
        let gift = address("g", name: "Jonas Berg", street: "Ringvägen 3", postal: "118 60", source: "Chrome", used: now.addingTimeInterval(-300 * 86_400))
        let rows = KnowNotes.addressRows([old, gift, work, copy, home], profile: profile, now: now)
        #expect(rows.map { $0["key"] as? String } == ["h", "w", "o", "g", "c"])
        #expect(rows[0]["label"] as? String == "Home")
        #expect(rows[0]["value"] as? String == "Södermannagatan 12, 116 40 Stockholm")
        #expect(rows[0]["source"] as? String == "Found in your order on nordbutik.se")
        #expect(rows[1]["value"] as? String == "Tern Labs AB, Hornsgatan 45, 118 49 Stockholm")
        #expect(rows[1]["source"] as? String == "Found by Get to Know")
        #expect(rows[2]["note"] as? String == "looks old")
        #expect(rows[2]["act"] as? String == "forget")
        #expect((rows[2]["source"] as? String ?? "").hasPrefix("From Chrome, last used "))
        // Someone else's: said, never tidied away on its own.
        #expect(rows[3]["note"] as? String == "Jonas’s, not yours")
        #expect(rows[3]["act"] as? String == "")
        #expect(rows[3]["value"] as? String == "Jonas Berg, Ringvägen 3, 118 60 Stockholm")
        #expect(rows[4]["note"] as? String == "same as work")
        #expect(rows[4]["act"] as? String == "merge")
        #expect(rows[4]["source"] as? String == "From Arc, never used")
    }

    @Test func aStepSaysWhichSiteItRead() {
        #expect(Agents.readHost("read · www.linkedin.com") == "linkedin.com")
        #expect(Agents.readHost("fetch · x.com") == "x.com")
        #expect(Agents.readHost("text · github.com") == "github.com")
        #expect(Agents.readHost("read · Mira Lindqvist") == nil)
        #expect(Agents.readHost("click · github.com") == nil)
    }

    @Test func gettingToKnowYouReportsForItsPage() {
        #expect(Agents.setUpMemoryPrompt.contains("`know_report`"))
        #expect(Agents.setUpMemoryPrompt.contains("`found`"))
        #expect(Agents.setUpMemoryPrompt.contains("4. End with exactly three plain lines"))
        // The profile from memory alone has no page of its own to fill.
        #expect(!Agents.fromMemoryPrompt.contains("know_report"))
        #expect(Agents.fromMemoryPrompt.contains("3. End with exactly three plain lines"))
        #expect(!Agents.setUpMemoryPrompt.contains("\u{2014}"))
        // Its page tells your story with faces and logos, and offers what to set up.
        for word in ["story:", "photos:", "doodles:", "setups:", "[[people/slug|Name]]", "github.pulls", "figma"] {
            #expect(Agents.setUpMemoryPrompt.contains(word), "\(word)")
        }
    }

    // A real run writes the brief and a person's page in sentences, not as
    // a list: every sentence is a line of the page all the same.
    @Test func aBriefInSentencesIsLinesToo() {
        let brief = """
        # User Briefing
        <!-- Who the user is, in a few lines, loaded into every task. -->
        Mira Lindqvist (she/her), Founding Designer at [[companies/tern-labs]] (since 2024), Stockholm, Sweden.
        - Home: Södermannagatan 12, 116 40 Stockholm.

        People: [[people/jonas-berg]].
        """
        #expect(KnowNotes.sections(brief).map(\.line) == [
            "Mira Lindqvist (she/her), Founding Designer at [[companies/tern-labs]] (since 2024), Stockholm, Sweden.",
            "- Home: Södermannagatan 12, 116 40 Stockholm.",
            "People: [[people/jonas-berg]].",
        ])
        #expect(KnowNotes.plain("Mira Lindqvist (she/her), Founding Designer at [[companies/tern-labs]] (since 2024).")
                == "Mira Lindqvist (she/her), Founding Designer at Tern Labs (since 2024).")
        let person = """
        ---
        name: Jonas Berg
        ---
        ## Current
        Friend of Mira's; they have lunch near her office.

        ## History
        - 2026-09-29: email "Lunch Thursday?"
        """
        let found = KnowNotes.sections(person)
        #expect(found.first?.heading == "Current")
        #expect(found.first?.line == "Friend of Mira's; they have lunch near her office.")
    }

    // A fix changes only what its words changed: the bold, the links and
    // the pointer to the full page stay.
    @Test func aFixKeepsWhatTheLineWasWrittenWith() {
        #expect(KnowNotes.fixed("- **Sam Rivera**, born in 1999. Full page: [[users/sam-rivera]]", to: "Sam Rivera, born in 1998.")
                == "- **Sam Rivera**, born in 1998. Full page: [[users/sam-rivera]]")
        #expect(KnowNotes.fixed("- Mira Lindqvist, designer at [[companies/tern-labs|Tern Labs]].", to: "Mira Lindqvist, design lead at Tern Labs.")
                == "- Mira Lindqvist, design lead at [[companies/tern-labs|Tern Labs]].")
        #expect(KnowNotes.fixed("Lives in Stockholm.", to: "Lives in Uppsala.") == "Lives in Uppsala.")
        // A name made from a page's name, changed: the link says the new
        // name and still goes to the page.
        #expect(KnowNotes.fixed("- Lunch with [[people/jonas-berg]] on Thursdays", to: "Lunch with Jonas Bergström on Thursdays")
                == "- Lunch with [[people/jonas-berg|Jonas Bergström]] on Thursdays")
        #expect(KnowNotes.fixed("- Works with [[people/lee-park]] on [acme.example](https://acme.example)", to: "Works with Lee on acme.example")
                == "- Works with [[people/lee-park|Lee]] on [acme.example](https://acme.example)")
        // The link's words gone with the words round it: the link goes too.
        #expect(KnowNotes.fixed("- Works with [[people/lee-park]] on [acme.example](https://acme.example)", to: "Works with on acme.example")
                == "- Works with on [acme.example](https://acme.example)")
        // Words added at the end go before the pointer, not after it.
        #expect(KnowNotes.fixed("- Short and direct. See [[agent/writing-voice]].", to: "Short and direct, never cold.")
                == "- Short and direct, never cold. See [[agent/writing-voice]].")
        #expect(KnowNotes.fixed("  - `yab` is the CLI", to: "yab is the CLI") == "  - `yab` is the CLI")
    }

    @Test func twoLinesAlikeAreTwoRows() {
        let numbered = KnowNotes.numbered(["- No exclamation marks.", "- Short.", "- No exclamation marks."])
        #expect(numbered.map(\.nth) == [0, 0, 1])
        #expect(KnowNotes.lineID("x.md", "- No exclamation marks.", 0) != KnowNotes.lineID("x.md", "- No exclamation marks.", 1))
        #expect(KnowNotes.lineID("x.md", "- Short.") == KnowNotes.lineID("x.md", "- Short.", 0))
    }

    // Someone else at your street, two flats of one building, a card's
    // address: none of them tidied away as yours.
    @Test func onlyYourCopiesAreTheSamePlace() {
        var profile = Profile()
        profile.name = "Mira Lindqvist"
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func address(_ id: String, name: String = "Mira Lindqvist", street: String, postal: String, city: String = "Stockholm",
                     source: String?, used: Date? = nil) -> StreetAddress {
            var a = StreetAddress(id: id)
            a.name = name; a.street = street; a.postal = postal; a.city = city; a.source = source; a.used = used
            return a
        }
        let home = address("h", street: "Södermannagatan 12", postal: "116 40", source: "Get to know me, home")
        let partner = address("p", name: "Anna Berg", street: "Södermannagatan 12", postal: "116 40", source: "Chrome")
        let flat = address("f", street: "Södermannagatan 12\nlgh 1304", postal: "116 40", source: "Chrome")
        let mine = address("m", street: "Södermannagatan 12\nlgh 1102", postal: "116 40", source: "Chrome")
        let billed = address("b", street: "Götgatan 78", postal: "118 30", source: "Chrome", used: now.addingTimeInterval(-900 * 86_400))
        let elsewhere = address("e", street: "1 Main Street", postal: "", city: "Cork", source: "Arc")
        let dublin = address("d", street: "1 Main Street", postal: "", city: "Dublin", source: "Get to know me, work")
        let rows = KnowNotes.addressRows([home, partner, flat, mine, billed, elsewhere, dublin], profile: profile, billing: ["b"], now: now)
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0["key"] as? String ?? "", $0) })
        #expect(by["p"]?["note"] as? String == "Anna’s, not yours")
        #expect(by["p"]?["act"] as? String == "")
        #expect(by["m"]?["note"] as? String == "same as home")
        #expect(by["f"]?["note"] as? String == "same as home")
        #expect(by["b"]?["act"] as? String == "")
        #expect((by["b"]?["source"] as? String ?? "").hasSuffix("a card bills here"))
        #expect(by["e"]?["note"] as? String != "same as work")
        // Two flats of one building are two places.
        #expect(!KnowNotes.sameStreet(flat, mine))
        // A picked phone goes on home and on its copies of yours alone.
        #expect(KnowNotes.homes([home, partner, flat], owner: "mira").map(\.id) == ["h", "f"])
    }

    @Test func aPickKeepsOneLineAndSaysWhatItIsAbout() {
        let report = KnowReport.given(["doubts": [
            ["question": "Which phone is yours?", "about": "Phone number", "choices": [
                ["answer": "+46 70 123 45 67", "keep": "- Mobile: +46 70 123 45 67"],
                ["answer": "+46 8 555 012 34", "keep": "Office line:\n+46 8 555 012 34"],
            ]],
            ["question": "Which is your email?", "about": "E-mail", "choices": [["answer": "a@b.se"], ["answer": "c@d.se"]]],
        ]])
        #expect(report.doubts[0].about == "phone")
        #expect(report.doubts[0].choices[0].keep == "Mobile: +46 70 123 45 67")
        #expect(report.doubts[0].choices[1].keep == "Office line: +46 8 555 012 34")
        #expect(report.doubts[1].about == "email")
        #expect(KnowReport.about("Time zone") == "timezone")
    }

    @Test func theRunsLinesLeadIntoItsPage() {
        let said = "Memory now holds: who you are.\nProfile has your name; Wallet has your home.\nMissing: Parley needs a sign-in."
        #expect(KnowPage.linked(said) == "[Memory](yab://you#brief) now holds: who you are.\n[Profile](yab://you#forms) has your name; "
                + "[Wallet](yab://you#addresses) has your home.\n[Missing](yab://you#left): Parley needs a sign-in.")
        // Only where a line starts with them: memory, mid-sentence, stays words.
        #expect(KnowPage.linked("It kept your Memory notes.") == "It kept your Memory notes.")
        #expect(KnowPage.escaped("Mira</title><script>") == "Mira&lt;/title&gt;&lt;script&gt;")
    }

    @Test func aChatFromBeforeReadsAsNoRun() throws {
        let old = #"{"id":"a1","title":"Get to know me","began":"other","cli":"claude","items":[],"subagents":[],"tabs":[],"pinned":false,"state":"done","answer":"","started":0,"updated":0}"#
        let chat = try JSONDecoder().decode(Chat.self, from: Data(old.utf8))
        #expect(chat.knowing == nil)
    }
}
