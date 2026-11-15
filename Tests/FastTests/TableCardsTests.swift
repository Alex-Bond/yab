import Testing
@testable import Fast

// A wide table in the chat read as cards (ChatTranscript, TableCards):
// which column is the date over the title, the title, the words, the
// foot and the source, decided for the whole column.
struct TableCardsTests {
    let events = [
        ["Date", "Event", "Why it's for you", "Registration", "Link"],
        ["Oct 6, 09:00", "Devtool founders coffee & waffles",
         "A small founders meetup with Evil Martians, a close fit for Acme. Laguna × Washington",
         "Selective, 40 spots max", "[Partiful](https://partiful.com/e/abc)"],
        ["Oct 6, 17:30–20:30", "**Camp AI**",
         "Anthropic/MCP, the CEO of Browserbase, Cloudflare: running agents in production. Ferry Building",
         "RSVP, limited spots", "[Partiful](https://partiful.com/e/def)"],
    ]

    @Test func eventsReadDateTitleWordsFootSource() {
        let card = TableCards(events)
        #expect(card.kicker == 0)
        #expect(card.title == 1)
        #expect(card.words == [2])
        #expect(card.foot == [3])
        #expect(card.source == 4)
        #expect(card.footLine(events[1], head: events[0]) == "Selective, 40 spots max")
    }

    @Test func sourceFoundByItsLinksWhateverItsName() {
        let rows = [
            ["Name", "Where", "Price", "Rating", "Page"],
            ["Tartine", "Mission", "$$", "4.6", "https://www.tartinebakery.com/"],
            ["Arsicault", "Inner Richmond", "$", "4.8", "<https://arsicault.com>"],
        ]
        let card = TableCards(rows)
        #expect(card.source == 4)
        #expect(card.kicker == nil)
        #expect(card.title == 0)
        #expect(card.words.isEmpty)
        #expect(card.foot == [1, 2, 3])
        // A number keeps its label; words stand alone.
        #expect(card.footLine(rows[1], head: rows[0]) == "Mission · $$ · Rating 4.6")
        #expect(TableCards.host(rows[1][4]) == "tartinebakery.com")
        #expect(TableCards.named(rows[2][4]) == "[arsicault.com](https://arsicault.com)")
        #expect(TableCards.named("[Partiful](https://partiful.com/e/abc)") == "[Partiful](https://partiful.com/e/abc)")
    }

    @Test func aLaterDateColumnStillGoesOverTheTitle() {
        let rows = [
            ["Talk", "When", "Room", "Speaker"],
            ["Agents in production", "Tue 14:00", "A", "Dana"],
            ["Browsers for agents", "Wed 10:30", "B", "Lee"],
        ]
        let card = TableCards(rows)
        #expect(card.title == 0)
        #expect(card.kicker == 1)
        #expect(card.foot == [2, 3])
    }

    @Test func datesAndNot() {
        for cell in ["09:00", "6 Oct, 09:00", "Oct 6", "October 6", "2026-10-06", "Tue", "tomorrow, 19:00", "6 Oct."] {
            #expect(TableCards.dated(cell), "\(cell)")
        }
        for cell in ["Camp AI", "4.5", "$40", "RSVP, limited spots", "Mission", "may join later"] {
            #expect(!TableCards.dated(cell), "\(cell)")
        }
        #expect(TableCards.bare(" — ") == "")
    }
}
