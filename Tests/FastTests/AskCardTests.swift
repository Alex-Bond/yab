import Foundation
import SyncKit
import Testing
@testable import Fast

/// What the question card shows, shaped from a permit (docs/chat-asks.md,
/// "The card"), and what the stand at the page's bottom right holds.
@MainActor
@Suite(.serialized)
struct AskCardTests {
    private func session() -> Agents.Session {
        let id = "ask-card-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        let made = Agents.shared.session(id)!
        made.cli = "claude"
        return made
    }

    @Test func mailSearchIsASearchFieldWithItsReach() {
        let asker = session()
        var permit = AgentPermit(kind: .mailRead, session: asker.id, detail: "Looks for \u{201C}boarding pass\u{201D}")
        ApprovalDetails.shared.searching[ApprovalDetails.changeKey(session: asker.id, permit: permit)] = "Looks for \u{201C}boarding pass\u{201D}\nReads subjects and senders"
        let content = AskContent.make(permit, tab: nil)
        #expect(content.mark == .mail)
        #expect(content.name == "Your mail")
        #expect(content.question == "Let Claude search your mail?")
        #expect(content.body == .search(words: "boarding pass", opens: false, scope: "And any search after it, until this chat ends."))
        #expect(content.terms == "Reads subjects and senders")
        // Another app's agent: its yes reaches its session, and says so.
        permit.forSession = true
        let session = AskContent.make(permit, tab: nil)
        if case .search(_, _, let scope) = session.body { #expect(scope.contains("session")) } else { Issue.record("not a search") }
    }

    @Test func openingAMailReadsInsteadOfSearching() {
        let asker = session()
        let permit = AgentPermit(kind: .mailRead, session: asker.id, detail: "Opens \u{201C}Invoice #4471\u{201D}")
        let content = AskContent.make(permit, tab: nil)
        #expect(content.question == "Let Claude read your mail?")
        #expect(content.body == .search(words: "Invoice #4471", opens: true, scope: "And any mail after it, until this chat ends."))
    }

    @Test func aMessageIsItsBubbleUnderThePerson() {
        let asker = session()
        let permit = AgentPermit(kind: .sendMessage(to: "Mom"), session: asker.id, detail: "Messages", draft: "Landing at 18:40")
        let content = AskContent.make(permit, tab: nil)
        #expect(content.mark == .person("Mom"))
        #expect(content.name == "Mom")
        #expect(content.question == nil)
        #expect(content.body == .bubble("Landing at 18:40"))
        #expect(content.sub.hasPrefix("iMessage"))
    }

    @Test func aSignInIsItsAccounts() {
        let asker = session()
        let permit = AgentPermit(kind: .signIn(host: "vercel.com", users: ["a@x.dev", "b@x.dev", "c@x.dev", "d@x.dev"]), session: asker.id, detail: "")
        let content = AskContent.make(permit, tab: nil)
        #expect(content.mark == .site("vercel.com"))
        #expect(content.body == .accounts(["a@x.dev", "b@x.dev", "c@x.dev"]))
    }

    @Test func theHeadSaysWhoseQuestion() {
        let asker = session()
        asker.title = "Plan Lisbon trip"
        let permit = AgentPermit(kind: .computer, session: asker.id, detail: "Files and terminal for this task.")
        let content = AskContent.make(permit, tab: nil)
        #expect(content.sub == "Claude \u{00B7} Plan Lisbon trip")
        #expect(content.mark == .mac)
        #expect(content.body == .lines(["Files and terminal for this task."]))
    }

    @Test func snippetSkipsAShortGreeting() {
        #expect(AskContent.snippet("Hi Dane,\nAs promised, meet Ilya.") == "As promised, meet Ilya.")
        #expect(AskContent.snippet("The deck comes Friday.") == "The deck comes Friday.")
        #expect(AskContent.quoted("Looks for \u{201C}Yab 0.32\u{201D}") == "Yab 0.32")
        #expect(AskContent.quoted("Looks at what needs you") == nil)
    }

    @Test func initialsAndTintsAreStable() {
        #expect(AskMark.initials("Lucas Vocos") == "LV")
        #expect(AskMark.initials("sam@42nd.dev") == "S4")
        #expect(AskMark.tint("Lucas Vocos") == AskMark.tint("Lucas Vocos"))
    }
}
