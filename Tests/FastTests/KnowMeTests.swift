import Foundation
import Testing
@testable import Fast

// What getting to know you writes (docs/forms.md): the profile key by key
// with where each came from, never over what the person wrote themselves;
// a contact card's links sorted into their keys; the new keys in forms.
struct KnowMeTests {
    @Test func whatYouWroteStaysYours() {
        var p = Profile()
        p.merge(["role": "Designer", "company": "Tern"], source: "you", force: true)
        let r = p.merge(["role": "Staff Designer", "company": "Tern Labs", "location": "Stockholm"], source: "LinkedIn")
        #expect(p.role == "Designer")
        #expect(p.company == "Tern")
        #expect(p.location == "Stockholm")
        #expect(Set(r.kept) == ["role", "company"])
        #expect(r.changed == ["location"])
        #expect(p.sources["location"] == "LinkedIn")
        #expect(p.sources["role"] == "you")
    }

    // A card with a name and a city filled the profile first, and memory,
    // asked only of an empty one, never was (Partiful, 2026-10-05).
    @Test func onlyTheCardsIsThin() {
        var p = Profile()
        #expect(p.thin)
        p.merge(["name": "Sam", "location": "San Francisco, United States"], source: "contact card")
        #expect(!p.isEmpty)
        #expect(p.thin)
        p.merge(["company": "Acme Labs"], source: "memory")
        #expect(!p.thin)
        var mine = Profile()
        mine.merge(["name": "Sam"], source: "contact card")
        mine.merge(["name": "Sam R."], source: "you", force: true)
        #expect(!mine.thin)
    }

    @Test func aPhoneIsOneHoweverWritten() {
        #expect(KnownPhone.key("+1 (415) 555-0100") == KnownPhone.key("415 555 0100"))
        #expect(KnownPhone.key("+1 415 555 0100") == "4155550100")
    }

    @Test func anOlderFileStillReads() throws {
        let old = #"{"name":"Mira","company":"Tern","source":"agent"}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        #expect(p.name == "Mira")
        #expect(p.working.isEmpty)
        #expect(p.edited.isEmpty)
    }

    @Test func aCardsLinksFindTheirKeys() {
        #expect(MeCard.key(for: "https://www.linkedin.com/in/mira") == "linkedin")
        #expect(MeCard.key(for: "twitter.com/miralq") == "x")
        #expect(MeCard.key(for: "https://x.com/miralq") == "x")
        #expect(MeCard.key(for: "github.com/miralq") == "github")
        #expect(MeCard.key(for: "t.me/miralq") == "telegram")
        #expect(MeCard.key(for: "https://mira.design") == "website")
    }

    @Test func theNewKeysAnswerTheirQuestions() {
        var p = FormTests.mira
        p.working = "A calm scheduling tool for small studios."
        p.languages = "English, Swedish"
        p.timezone = "Europe/Stockholm"
        func source(_ label: String, tag: String = "input") -> FormSource {
            FormRules.step(FormTests.box(label, tag: tag), profile: p, answers: .init(), site: "lu.ma", hasAddress: true, known: [:]).source
        }
        #expect(source("What are you working on?") == .profile("working"))
        #expect(source("Languages you speak") == .profile("languages"))
        #expect(source("Time zone") == .profile("timezone"))
        #expect(source("Preferred programming language") != .profile("languages"))
        // Pronouns only as given; otherwise the box is yours.
        #expect(source("Pronouns") == .yours("self"))
        p.pronouns = "she/her"
        #expect(FormRules.step(FormTests.box("Pronouns"), profile: p, answers: .init(), site: "lu.ma", hasAddress: true, known: [:]).source == .profile("pronouns"))
    }

    @Test func gettingToKnowYouAsksForTheStores() {
        #expect(Agents.setUpMemoryPrompt.contains("keep_address"))
        #expect(Agents.setUpMemoryPrompt.contains("`profile`"))
        #expect(Agents.fromMemoryPrompt.contains("don't open tabs"))
    }

    /// Out of sight and bounded (docs/get-to-know.md): history first, text
    /// without a tab where a page gives it, a few tabs at most, alone, about
    /// ten minutes, and no loop that goes round until it scores itself high.
    @Test func gettingToKnowYouIsBrief() {
        let prompt = Agents.setUpMemoryPrompt
        #expect(prompt.contains("`fetch`"))
        #expect(prompt.contains("at most three at once"))
        #expect(prompt.contains("ten minutes"))
        #expect(prompt.contains("no subagents"))
        #expect(!prompt.contains("9 out of 10"))
        let history = prompt.range(of: "`history`")?.lowerBound
        let search = prompt.range(of: "Web search")?.lowerBound
        #expect(history != nil && search != nil && history! < search!)
        #expect(Agents.knowingMinutes == 10)
        #expect(Agents.knowingStop == 14)
    }

    @MainActor @Test func itsBriefLeavesPeopleOut() {
        for words in ["`name`", "`handoff`", "`ask`", "`sign_in`", "subagents", "Close every tab you open"] {
            #expect(Agents.sealedBrief.contains(words), "\(words)")
        }
    }
}
