import AppKit
import Foundation
import Testing
@testable import Fast

// Snippets everywhere (docs/snippets.md): where each works, an older Yab's
// mail snippets kept as Mail's, {date} and {clipboard} filled in a page's
// box and the mail's own variables left alone there, a key of their own
// checked as Shortcuts checks keys, ⌘; in the browser, and what is pasted
// counted by digest alone.

struct SnippetTests {
    let day = Date(timeIntervalSince1970: 1_790_852_400)
    let us = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!

    @Test func aPageGetsDateAndClipboardAndLeavesTheMailsOwn() {
        let filled = MailSnippets.fillPage("Hi {first_name}, on {date} see {clipboard} and {{link}}", date: day,
                                           clipboard: "https://fold.studio", locale: us, zone: utc)
        #expect(filled == "Hi {first_name}, on October 1, 2026 see https://fold.studio and {{link}}")
        // In a mail {clipboard} is filled too, and an empty one is a place.
        #expect(MailSnippets.fill("Link: {clipboard}", to: nil, me: "", date: day, clipboard: "x.com", locale: us, zone: utc) == "Link: x.com")
        #expect(MailSnippets.fill("Link: {clipboard}", to: nil, me: "", date: day, clipboard: "", locale: us, zone: utc) == "Link: {{clipboard}}")
    }

    @MainActor @Test func anOlderYabsSnippetsWithMailThingsStayMailsOwn() throws {
        let folder = MailSnippetTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("snippets.json")
        // As 0.0.23 kept them: no mailOnly, no hotkey.
        let old = """
        [{"id":"a","name":"Intro","body":"Hi","to":"Anna <anna@fold.studio>","cc":"","bcc":"","subject":"","files":[],"uses":0,"made":0},
         {"id":"b","name":"Thanks","body":"Thanks!","to":"","cc":"","bcc":"","subject":"","files":[],"uses":0,"made":0}]
        """
        try Data(old.utf8).write(to: file)
        let snippets = MailSnippets(file: file)
        #expect(snippets.snippet("a")?.mailOnly == true)
        #expect(snippets.snippet("b")?.mailOnly == false)
        #expect(snippets.snippet("b")?.hotkey == "")
        // A page is offered only those that work everywhere.
        #expect(snippets.matching("", pages: true).map(\.id) == ["b"])
        #expect(snippets.matching("").count == 2)
        // Made everywhere, what only a mail takes goes.
        var intro = try #require(snippets.snippet("a"))
        intro.mailOnly = false
        snippets.change(intro)
        #expect(snippets.snippet("a")?.to == "")
        // Kept with where it works and its key.
        let made = snippets.add(name: "Sign-off", body: "Best,\nSam", hotkey: Hotkey("s", [.control, .option]).stored)
        #expect(made.mailOnly == false)
        let again = MailSnippets(file: file)
        #expect(again.snippet(made.id)?.hotkey == Hotkey("s", [.control, .option]).stored)
        #expect(again.holding(Hotkey("s", [.control, .option]))?.id == made.id)
        #expect(again.holding(Hotkey("s", [.control, .option]), besides: made.id) == nil)
        #expect(again.freeName("Thanks") == "Thanks-2")
        #expect(SnippetOffers.command(" my link!") == "my-link")
    }

    @MainActor @Test func aSnippetsKeyNeedsAModifier() {
        let snippets = MailSnippets(file: MailSnippetTests.folder().appendingPathComponent("snippets.json"))
        if case .refused = snippets.clash(Hotkey("a", []), for: nil) {} else { Issue.record("a bare key was taken") }
        if case .refused = snippets.clash(Hotkey("a", .shift), for: nil) {} else { Issue.record("⇧A was taken") }
    }

    @MainActor @Test func commandSemicolonOpensSnippetsInTheBrowser() {
        #expect(Shortcut.byAction[.snippets]?.key == Hotkey(";", .command))
        #expect(Shortcut.context(.snippets) == .browser)
        #expect(FieldPlace.snippets.shortcut == .snippets)
        #expect(FieldPlace.named("snipp") == .snippets)
        #expect(SettingsPage.snippets.parent == nil && SettingsPage.sidebar.contains(.snippets))
    }

    @Test func onlyWordsAreCountedNeverCodesOrKeys() {
        #expect(!SnippetOffers.counts("short"))
        #expect(!SnippetOffers.counts("123 456 789 012"))
        #expect(!SnippetOffers.counts("Xk9#mQ2!vL8@pR"))
        #expect(SnippetOffers.counts("https://www.linkedin.com/in/sam"))
        #expect(SnippetOffers.counts("Thanks for reaching out, I'll get back to you"))
        // The same words however they are spaced.
        #expect(SnippetOffers.digest("  Thanks  for reaching out ") == SnippetOffers.digest("Thanks for reaching out"))
        #expect(SnippetOffers.name(for: "https://www.linkedin.com/in/sam") == "linkedin")
        #expect(SnippetOffers.name(for: "sam@42nd.dev") == "email")
        #expect(SnippetOffers.name(for: "Thanks for reaching out") == "thanks-for")
    }

    @MainActor @Test func threePastesInAWeekAskOnceThenNotForAMonth() {
        let folder = MailSnippetTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let offers = SnippetOffers(file: folder.appendingPathComponent("pastes.json"))
        let words = "https://www.linkedin.com/in/sam"
        #expect(offers.count(words, now: day) == nil)
        // A paste older than a week is forgotten.
        #expect(offers.count(words, now: day.addingTimeInterval(8 * 86_400)) == nil)
        #expect(offers.count(words, now: day.addingTimeInterval(9 * 86_400)) == nil)
        #expect(offers.count(words, now: day.addingTimeInterval(10 * 86_400)) == 3)
        // Only digests are kept.
        let kept = (try? String(contentsOf: folder.appendingPathComponent("pastes.json"), encoding: .utf8)) ?? ""
        #expect(!kept.contains("linkedin"))
        // Put off: not again for 30 days, though pasted again.
        offers.log.quiet[SnippetOffers.digest(words)] = day.addingTimeInterval(10 * 86_400)
        for n in 0..<3 { #expect(offers.count(words, now: day.addingTimeInterval(Double(11 + n) * 86_400)) == nil) }
    }
}
