import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Memory of people (docs/mail.md, People in memory): a page per person you write
// with often, from your mail: who they are and how they write, how you
// write to them, what is open between you; a Who you wrote stays yours.
struct MailPeopleTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let me = MailPerson(name: "Me", address: "me@acme.io")
    static let mark = MailPerson(name: "Mark Chen", address: "mark@north.vc")

    // MARK: - reading the mail

    @Test func greetingsAndLengths() {
        #expect(MailPeople.greeting(["Hi Mark,", "Numbers below."]) == "Hi Mark")
        #expect(MailPeople.greeting(["Hello!", "Numbers below."]) == "Hello")
        #expect(MailPeople.greeting(["Numbers below."]) == nil)
        #expect(MailPeople.length(1) == "one line" && MailPeople.length(2) == "two lines")
        #expect(MailPeople.length(4) == "a few lines" && MailPeople.length(12) == "long mails")
    }

    @Test func theLineUnderTheirName() {
        let signed = { (words: String) in "\(words)\n\nBest,\nMark Chen\nPartner, North Ventures\n+1 415 555 0100" }
        #expect(MailPeople.title(in: [signed("Can you send the numbers?"), signed("Thanks.")], name: "Mark Chen") == "Partner, North Ventures")
        // Once is no signature to go by.
        #expect(MailPeople.title(in: [signed("Thanks.")], name: "Mark Chen") == nil)
    }

    @Test func whatTheStoreSays() {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        var messages: [MailMessage] = []
        for n in 0..<3 {
            let at = Self.now.addingTimeInterval(-Double(n + 1) * 86_400)
            messages.append(MailMessage(id: "m\(n)", thread: "t\(n)", from: Self.mark, to: [Self.me], subject: "Q3", snippet: "",
                                        date: at, labels: ["INBOX"],
                                        text: "Can you send Sep numbers?\n\nBest,\nMark Chen\nPartner, North Ventures"))
            messages.append(MailMessage(id: "r\(n)", thread: "t\(n)", from: Self.me, to: [Self.mark], subject: "Re: Q3", snippet: "",
                                        date: at.addingTimeInterval(1800), labels: ["SENT"], text: "Hi Mark,\nSending them Friday.\nSam"))
        }
        store.put(messages)
        let facts = MailPeople.facts(store, name: "Mark Chen", address: "mark@north.vc", threads: 3, last: Self.now)
        #expect(facts.title == "Partner, North Ventures")
        #expect(facts.theirLines == 1 && !facts.theyGreet)
        #expect(facts.youGreet == "Hi Mark")
        #expect(MailPeople.who(facts) == "Partner, North Ventures. Writes one line, no greeting.")
        #expect(MailPeople.how(facts).hasSuffix("or so, \u{201C}Hi Mark\u{201D}."))
    }

    // MARK: - the page

    func facts() -> MailPeople.Facts {
        MailPeople.Facts(name: "Mark Chen", address: "mark@north.vc", threads: 23, last: Self.now, title: "Partner, North Ventures",
                         theirLines: 2, theyGreet: false, yourLines: 3, youGreet: "Hi Mark")
    }

    @Test func aPageFromMail() throws {
        let page = MailPeople.render(nil, facts: facts(), open: ["You owe: Q3 numbers · by Fri"], now: Self.now)
        #expect(page.hasPrefix("# Mark Chen\n\n## Who\nPartner, North Ventures. Writes two lines, no greeting.\n" + MailPeople.mailMark))
        #expect(page.contains("## How you write to them\nA few lines or so, \u{201C}Hi Mark\u{201D}."))
        #expect(page.contains("## Open between you\n- You owe: Q3 numbers · by Fri"))
        #expect(page.contains("## From mail\nFrom 23 threads with mark@north.vc"))
        let card = try #require(MailPeople.card(page))
        #expect(card.who == "Partner, North Ventures. Writes two lines, no greeting.")
        #expect(card.source == "From 23 threads · in your memory" && !card.yours)
        #expect(MailPeople.known(page)?.hasPrefix("Who: Partner, North Ventures.") == true)
    }

    @Test func anAgentsSectionsAndYourWhoStay() throws {
        let agents = "# Mark Chen\n\n## Who\nLed the seed round.\n\n## Notes\nPrefers mornings."
        let page = MailPeople.render(agents, facts: facts(), open: [], now: Self.now)
        // An agent's Who isn't the mail's to write over.
        #expect(page.contains("## Who\nLed the seed round.\n"))
        #expect(page.contains("## Notes\nPrefers mornings."))
        #expect(!page.contains("## Open between you"))
        // Yours: first, said so, kept by the next pass.
        let yours = MailPeople.withWho(page, text: "Partner at North Ventures, led your seed. Writes two lines.", now: Self.now)
        let card = try #require(MailPeople.card(yours))
        #expect(card.yours && card.who == "Partner at North Ventures, led your seed. Writes two lines.")
        #expect(card.source.hasPrefix("Changed by you · "))
        let again = MailPeople.render(yours, facts: facts(), open: [], now: Self.now)
        #expect(MailPeople.card(again)?.who == card.who)
    }

    @Test func aPagesName() {
        #expect(MailPeople.page(name: "Mark Chen", address: "mark@north.vc") == "people/Mark Chen")
        #expect(MailPeople.page(name: "", address: "mark@north.vc") == "people/mark")
    }
}
