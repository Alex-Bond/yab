import CryptoKit
import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Snippets (docs/mail.md, Snippets): {first_name} and the rest filled from
// the draft's first To chip and the account, a variable with nothing to
// fill it left as a place to fill by hand, which keeps the mail from going;
// ";" only at a word's start; a snippet's files copied into the draft; and
// the list kept on this Mac, most used first.

struct MailSnippetTests {
    let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")
    /// Oct 1, 2026, noon in London: the same day in any zone the test names.
    let day = Date(timeIntervalSince1970: 1_790_852_400)
    let us = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!

    // MARK: - the words

    @Test func theNameIsFilledFromTheFirstToChip() {
        let words = "Hi {first_name},\n\nMeet {name}'s team. Talk on {date}?\n\n{my_name}"
        let filled = MailSnippets.fill(words, to: anna, me: "Sam Rivera", date: day, locale: us, zone: utc)
        #expect(filled == "Hi Anna,\n\nMeet Anna Lindqvist's team. Talk on October 1, 2026?\n\nSam Rivera")
        // Whatever case it is written in; a word in braces that is none of them stays.
        #expect(MailSnippets.fill("Hi {First_Name}, {company} next", to: anna, me: "", date: day, locale: us, zone: utc) == "Hi Anna, {company} next")
        // "Lindqvist, Anna": the name after the comma.
        let listed = MailPerson(name: "Lindqvist, Anna", address: "anna@fold.studio")
        #expect(MailSnippets.fill("Hi {first_name}", to: listed, me: "", date: day, locale: us, zone: utc) == "Hi Anna")
        #expect(MailSnippets.holes(MailSnippets.fill(words, to: anna, me: "Sam", date: day, locale: us, zone: utc)).isEmpty)
    }

    @MainActor @Test func aChipWithoutANameIsNamedAsTheMailYouKnowNamesIt() throws {
        // The account's own name: the newest mail from it that says one.
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        let at = Date()
        store.put([
            MailMessage(id: "m1", thread: "t1", from: MailPerson(name: "Sam", address: "me@example.com"), subject: "Old", date: at.addingTimeInterval(-86_400)),
            MailMessage(id: "m2", thread: "t2", from: MailPerson(name: "Sam Rivera", address: "me@example.com"), subject: "New", date: at),
            MailMessage(id: "m3", thread: "t3", from: MailPerson(name: "", address: "me@example.com"), subject: "Bare", date: at.addingTimeInterval(60)),
        ])
        #expect(store.myName() == "Sam Rivera")
        store.set("name", "Sam R.")
        #expect(store.myName() == "Sam R.")
        #expect(store.newestName(from: "nobody@example.com") == "")
    }

    @Test func noNameMeansThePlaceStaysAndKeepsTheMailFromGoing() {
        let words = "Hi {first_name}, see you on {{date}}."
        // A chip of an address alone, nobody it is known by: a place to fill.
        let bare = MailPerson(name: "", address: "tim@okafor.co")
        let filled = MailSnippets.fill(words, to: bare, me: "", date: day, locale: us, zone: utc)
        #expect(filled == "Hi {{first_name}}, see you on {{date}}.")
        #expect(MailSnippets.fill(words, to: nil, me: "", date: day, locale: us, zone: utc) == filled)
        #expect(MailSnippets.holes(filled) == ["{{first_name}}", "{{date}}"])
        // {{first_name}} written by hand stays a place, never "{Anna}".
        #expect(MailSnippets.fill("{{first_name}}", to: anna, me: "", date: day, locale: us, zone: utc) == "{{first_name}}")
        // {my_name} with no name for the account: a place too.
        #expect(MailSnippets.fill("Best, {my_name}", to: anna, me: "  ", date: day, locale: us, zone: utc) == "Best, {{my_name}}")

        // The draft holds them in its words and its subject, each once; not in the mail it quotes.
        var draft = MailDesk.Draft(id: "new:1", thread: "", account: "me@example.com", to: "tim@okafor.co", subject: "Lunch on {{day}}", body: filled)
        draft.quote = "On Tue, Anna wrote:\n> {{not this}}"
        #expect(draft.holes == ["{{day}}", "{{first_name}}", "{{date}}"])
        #expect(MailSnippets.line(draft.holes) == "Fill in {{day}}, {{first_name}} and 1 more before sending")
        #expect(MailSnippets.line(["{{date}}"]) == "Fill in {{date}} before sending")
        #expect(MailSnippets.line(["{{date}}", "{{place}}"]) == "Fill in {{date}} and {{place}} before sending")
        // Filled in, nothing holds it.
        draft.subject = "Lunch on Friday"
        draft.body = "Hi Tim, see you on Friday."
        #expect(draft.holes.isEmpty && MailSnippets.line(draft.holes) == nil)
        // The caret goes to the first place to fill.
        #expect(MailSnippets.firstHole("Hi {{first_name}}, on {{date}}") == NSRange(location: 3, length: 14))
    }

    @Test func aSemicolonOpensThePickerOnlyAtAWordsStart() throws {
        let start = try #require(MailSnippets.trigger(in: ";intro", caret: 6))
        #expect(start.range == NSRange(location: 0, length: 6) && start.words == "intro")
        let after = try #require(MailSnippets.trigger(in: "Hi Anna,\n;in", caret: 12))
        #expect(after.range == NSRange(location: 9, length: 3) && after.words == "in")
        // ";" alone, after a space: every snippet, nothing typed yet.
        #expect(MailSnippets.trigger(in: "Thanks ;", caret: 8)?.words == "")
        // In a word, after a mark, inside a link: no picker.
        #expect(MailSnippets.trigger(in: "a;b", caret: 3) == nil)
        #expect(MailSnippets.trigger(in: "done;", caret: 5) == nil)
        #expect(MailSnippets.trigger(in: "(;intro", caret: 7) == nil)
        #expect(MailSnippets.trigger(in: "https://x.co/a;b=1", caret: 18) == nil)
        // Only at the name's end: the caret in its middle opens nothing.
        #expect(MailSnippets.trigger(in: ";intro", caret: 3) == nil)
        // A space ends the name.
        #expect(MailSnippets.trigger(in: ";intro ", caret: 7) == nil)
        // Counted as a text view counts, in UTF-16: after an emoji, in Japanese.
        #expect(MailSnippets.trigger(in: "👋 ;in", caret: 6)?.range == NSRange(location: 3, length: 3))
        #expect(MailSnippets.trigger(in: "こんにちは ;会議", caret: 9)?.words == "会議")
    }

    @Test func aMailsOwnWordsWithoutItsQuoteAndSignature() {
        let reply = MailMessage(id: "m", thread: "t", from: anna, subject: "Re: Fwd: Intro", date: day,
                                text: "Hi Tim,\n\nMeet Anna, she runs Fold.\nThanks!\n\nBest,\nSam\n\nOn Tue, Sep 29, 2026 at 10:00 AM Anna <anna@fold.studio> wrote:\n> Who should I meet?")
        #expect(MailSnippets.words(of: reply) == "Hi Tim,\n\nMeet Anna, she runs Fold.\nThanks!")
        let signed = MailMessage(id: "s", thread: "t", from: anna, subject: "Hello", date: day,
                                 text: "\n\nThe deck is attached.\n-- \nAnna Lindqvist\nFold Studio")
        #expect(MailSnippets.words(of: signed) == "The deck is attached.")
        let forwarded = MailMessage(id: "f", thread: "t", from: anna, subject: "Fwd: Deck", date: day,
                                    text: "For a look.\n\n" + MailCompose.forwardLine + "\nFrom: Mark <mark@northwind.vc>\n\nNumbers.")
        #expect(MailSnippets.words(of: forwarded) == "For a look.")
        #expect(MailSnippets.bare(subject: "Re: Fwd: Intro") == "Intro")
        #expect(MailSnippets.suggestedName(subject: "Re: Intro to Fold", body: "Hi") == "Intro to Fold")
        #expect(MailSnippets.suggestedName(subject: "", body: "Thanks for the call, Anna. More soon.") == "Thanks for the call")
    }

    // MARK: - files

    @MainActor @Test func aSnippetsFilesAreCopiedIntoTheDraft() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snippets = MailSnippets(file: folder.appendingPathComponent("mail/snippets.json"))
        let deck = Self.noise(48_000), price = Data("Price list, October\n".utf8)
        let a = try Self.file("Deck v3.pdf", deck, in: folder), b = try Self.file("Prix été.txt", price, in: folder)
        let made = snippets.add(name: "Intro", body: "Hi {first_name}", cc: "Mark <mark@northwind.vc>", bcc: "crm@fold.studio", files: [a, b])
        #expect(made.files.map(\.name) == ["Deck v3.pdf", "Prix été.txt"] && made.files.map(\.size) == [48_000, price.count])
        // The snippet keeps copies of its own: the ones chosen can go.
        try FileManager.default.removeItem(at: a)
        #expect(snippets.urls(of: made).count == 2)

        let store = MailStore(file: folder.appendingPathComponent("mail/me@example.com.sqlite"))
        var draft = MailDraft(id: "new:7", to: [anna], cc: [MailPerson(name: "", address: "kept@fold.studio")])
        snippets.bring(made, into: &draft, store: store)
        // Copied into the draft's own folder, a copy each, the bytes whole.
        #expect(draft.files.map(\.name) == ["Deck v3.pdf", "Prix été.txt"])
        #expect(draft.files.allSatisfy { !$0.original })
        for (file, bytes) in zip(draft.files, [deck, price]) {
            let place = try #require(MailAttach.place(file, draft: draft.id, store: store))
            #expect(place.path.hasPrefix(try #require(MailAttach.folder(for: store, draft: draft.id)).path))
            #expect(Self.sha(try Data(contentsOf: place)) == Self.sha(bytes))
        }
        // Cc only where the draft had none; Bcc where it had none.
        #expect(draft.cc.map(\.address) == ["kept@fold.studio"] && draft.bcc.map(\.address) == ["crm@fold.studio"])
        #expect(snippets.snippet(made.id)?.uses == 1)
        // The draft keeps them across the store opened again; the snippet keeps its own.
        store.save(draft)
        #expect(MailStore(file: store.file).draft("new:7")?.files.map(\.name) == ["Deck v3.pdf", "Prix été.txt"])
        MailAttach.drop(draft: draft.id, store: store)
        #expect(snippets.urls(of: made).count == 2)
        // Deleted, its copies go with it.
        snippets.remove(made.id)
        #expect(!FileManager.default.fileExists(atPath: snippets.folder.appendingPathComponent(made.id).path))
        #expect(MailSnippets(file: snippets.file).all.isEmpty)
    }

    // MARK: - kept

    @MainActor @Test func keptOnThisMacMostUsedFirst() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("mail/snippets.json")
        let snippets = MailSnippets(file: file)
        let intro = snippets.add(name: "Intro", body: "Hi {first_name}, meet {{who}}.", to: "Anna <anna@fold.studio>", subject: "Intro")
        let thanks = snippets.add(name: "Thanks for the call", body: "Thanks for the call, {first_name}.")
        let pricing = snippets.add(name: "Pricing", body: "Our prices: {{link}}")
        // Never used: by name.
        #expect(snippets.ordered.map(\.name) == ["Intro", "Pricing", "Thanks for the call"])
        let then = Date()
        snippets.used(thanks.id, at: then)
        snippets.used(thanks.id, at: then)
        snippets.used(pricing.id, at: then)
        snippets.used(intro.id, at: then.addingTimeInterval(60))
        // Most used first; of as many uses, the one used last.
        #expect(snippets.ordered.map(\.name) == ["Thanks for the call", "Intro", "Pricing"])
        snippets.used(intro.id, by: -1)
        #expect(snippets.snippet(intro.id)?.uses == 0)

        // Kept in the file, read back the same, with everything it says.
        let again = MailSnippets(file: file)
        #expect(again.all == snippets.all)
        #expect(again.ordered.map(\.name) == ["Thanks for the call", "Pricing", "Intro"])
        #expect(again.snippet(intro.id)?.to == "Anna <anna@fold.studio>" && again.snippet(intro.id)?.subject == "Intro")
        // By name whatever its case; the picker by the name's start, or a word's.
        #expect(again.named("  INTRO ")?.id == intro.id && again.named("intr") == nil)
        #expect(again.matching("th").map(\.name) == ["Thanks for the call"])
        #expect(again.matching("call").map(\.name) == ["Thanks for the call"])
        #expect(again.matching("ri").map(\.name) == ["Pricing"])
        #expect(again.matching("").count == 3)
        // Kept under a name it has already: its place taken, its uses kept.
        let redone = again.add(name: "thanks for the call", body: "Thank you, {first_name}!")
        #expect(redone.id == thanks.id && redone.uses == 2 && again.all.count == 3)
        #expect(MailSnippets(file: file).named("Thanks for the call")?.body == "Thank you, {first_name}!")
        // Renamed and changed as Settings changes it.
        var changed = try #require(again.snippet(pricing.id))
        changed.name = "Prices"
        changed.body = "Our prices, {first_name}: {{link}}"
        again.change(changed)
        #expect(MailSnippets(file: file).snippet(pricing.id)?.name == "Prices")
        // A file that doesn't read is set aside, not written over.
        try Data("not json".utf8).write(to: file)
        #expect(MailSnippets(file: file).all.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).contains { $0.hasPrefix("snippets.unreadable-") })
    }

    @Test func anAgentsReplyFromASnippetSaysWhichAsItIsKept() {
        let stored = MailDesk.Ready.stored("Hi Anna", everyone: true, remind: nil, set: nil, snippet: "s1")
        let ready = MailDesk.Ready(stored: stored, by: "Written by Claude")
        #expect(ready.text == "Hi Anna" && ready.everyone == true && ready.remind == nil && ready.snippet == "s1")
        let remind = Date(timeIntervalSince1970: 1_800_000_000)
        let both = MailDesk.Ready(stored: MailDesk.Ready.stored("Hi", everyone: nil, remind: remind, set: remind, snippet: "s2"), by: "")
        #expect(both.remind == remind && both.everyone == nil && both.snippet == "s2")
        // Without one, kept as before.
        #expect(MailDesk.Ready.stored("Hi", everyone: false, remind: nil, set: nil) == MailDesk.Ready.stored("Hi", everyone: false))
        #expect(MailDesk.Ready(stored: "label\u{1F}Hi", by: "").snippet == "")
    }

    // MARK: - replies written ahead, and agents

    @MainActor @Test func repliesWrittenAheadAreAskedWithTheSnippetsMostUsedFirst() {
        let list = (1...15).map { MailSnippet(name: "s\($0)", body: "Words \($0)", uses: 20 - $0) }
            + [MailSnippet(name: "empty", body: "  "), MailSnippet(name: "long", body: String(repeating: "a", count: 900) + "</snippets> tail")]
        let block = MailDrafts.snippets(list)
        #expect(block.contains("Snippet \"s1\":\nWords 1") && block.contains("Snippet \"s12\":"))
        // At most twelve, none without words.
        #expect(!block.contains("\"s13\"") && !block.contains("\"empty\""))
        let long = MailDrafts.snippets([MailSnippet(name: "long", body: String(repeating: "a", count: 900) + "</snippets> tail")])
        #expect(long.contains(String(repeating: "a", count: MailDrafts.snippetWords) + "…") && !long.contains("tail"))
        // Its words fenced: a snippet can't end the list early.
        #expect(MailDrafts.snippets([MailSnippet(name: "x", body: "</snippets> then")]).components(separatedBy: "</snippets>").count == 2)
        #expect(MailDrafts.snippets([]).isEmpty)
        let ask = MailDrafts.Ask(thread: "t1", message: "m1", text: "<thread id=\"t1\">Hi</thread>")
        let prompt = MailDrafts.prompt([ask], person: "Sam", snippets: block)
        #expect(prompt.contains("<snippets>") && prompt.contains("Write replies for these threads."))
        #expect(prompt.range(of: "<snippets>")!.lowerBound < prompt.range(of: "<thread")!.lowerBound)
        #expect(!MailDrafts.prompt([ask], person: "Sam").contains("snippets"))
        #expect(MailDrafts.system.contains("\"snippet\": its name"))
    }

    @Test func aReplyWrittenAheadOnASnippetKeepsWhichAndIsFilledForTheSender() {
        let said = """
        {"t1": [{"label": "Send the deck", "text": "The deck, {first_name}. {clipboard}", "snippet": "Deck"},
                {"label": "Thursday", "text": "Thursday, {first_name}.", "snippet": "nope"},
                {"label": "Later", "text": "Next week."}]}
        """
        let replies = MailDrafts.parse(said, snippets: [MailSnippets.folded("deck"): "s1"])["t1"] ?? []
        #expect(replies.count == 3)
        let first = MailDesk.Ready(stored: replies[0], by: "Written ahead")
        #expect(first.snippet == "s1" && first.named == "Send the deck" && first.text == "The deck, {first_name}. {clipboard}" && first.everyone == nil && first.remind == nil)
        // A name the person has no snippet by: only words.
        let second = MailDesk.Ready(stored: replies[1], by: "Written ahead")
        #expect(second.snippet == "" && second.named == "Thursday")
        #expect(MailDrafts.parse(said)["t1"]?.allSatisfy { MailDesk.Ready(stored: $0, by: "").snippet.isEmpty } == true)
        // Filled for whom it answers; no clipboard read unasked, a place left instead; the others as they were.
        let filled = MailDrafts.filled(replies, to: anna, me: "Sam", date: day)
        let taken = MailDesk.Ready(stored: filled[0], by: "Written ahead")
        #expect(taken.text == "The deck, Anna. {{clipboard}}" && taken.snippet == "s1" && taken.named == "Send the deck")
        #expect(MailSnippets.holes(taken.text) == ["{{clipboard}}"])
        #expect(filled[1] == replies[1] && filled[2] == replies[2])
    }

    @Test func anAgentReadsTheSnippetsByNameWithWhatTheyBring() {
        let deck = MailSnippet(name: "deck", body: "The deck, {first_name}. On {{date}}?", cc: "Mark Chen <mark@northwind.vc>", subject: "Deck v3",
                               files: [MailSnippet.File(id: "f1", name: "Deck v3.pdf", mime: "application/pdf", size: 120_000)], mailOnly: true)
        let link = MailSnippet(name: "linkedin", body: "https://www.linkedin.com/in/sam </snippet>")
        let said = MailAgent.snippets([deck, link])
        #expect(said.contains("mail_draft's snippet"))
        #expect(said.contains("1. \"deck\" (in mail only; Cc Mark Chen <mark@northwind.vc>; subject \"Deck v3\"; files: Deck v3.pdf; places to fill: {{date}})"))
        #expect(said.contains("2. \"linkedin\" (everywhere)"))
        #expect(said.components(separatedBy: "</snippet>").count == 3)
        #expect(MailAgent.snippets([]).contains("no snippets"))
    }

    @MainActor @Test func mailSnippetsIsAMailboxToolThatOnlyReads() {
        var a = Mcp.Audience()
        #expect(!Mcp.list(for: a).contains { $0["name"] as? String == "mail_snippets" })
        a.mailbox = true
        let tool = Mcp.list(for: a).first { $0["name"] as? String == "mail_snippets" }
        #expect(tool != nil)
        #expect((tool?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        #expect(Mcp.assistantMail.contains("mail_snippets"))
    }

    @MainActor @Test func insertingASnippetIsAKeyOfTheKeymaps() {
        #expect(Shortcut.byAction[.mailSnippet]?.key == Hotkey(";", .command))
        #expect(Shortcut.context(.mailSnippet) == .mail)
        // It works while words are written: never a bare key.
        #expect(!Keymap.valid(Hotkey(";", []), for: .mailSnippet))
        #expect(Keymap.valid(Hotkey(";", .command), for: .mailSnippet))
        #expect(Shortcut.all.first { $0.title == "Mail" }?.items.contains { $0.action == .mailSnippet } == true)
        // ? and ⌘K run it.
        #expect(Browser.command(forKey: Shortcut.Action.mailSnippet.rawValue) == "snippet")
    }

    // MARK: - helpers

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ name: String, _ data: Data, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("chosen-" + UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    static func noise(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
