import Foundation
import Testing
@testable import Fast

// ⌘T's Ask and agents answered from the day's threads (AskFromDay,
// AgentHistory.threads): time words narrow the threads, the pages go out
// numbered, the numbers come back as rows; "pick up where I left off" leads
// with the thread as a folder. A diary of its own, seeded as DayThreadsTests
// seeds one.
struct AskFromDayTests {
    static func weekday(daysAgo: Int) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEEE"
        return format.string(from: DayThreadsTests.at(9, 0, daysAgo: daysAgo))
    }

    static func seeded() async -> (Diary, URL) {
        let (diary, folder) = DayThreadsTests.diary()
        await diary.plant(DayThreadsTests.morning + [
            DayThreadsTests.page("https://news.ycombinator.com/show", "Show HN guidelines", DayThreadsTests.at(16, 15)),
            DayThreadsTests.page("https://docs.google.com/document/d/hn", "Show HN draft - Google Docs", DayThreadsTests.at(16, 30)),
            DayThreadsTests.page("https://news.ycombinator.com/item?id=1", "Show HN: Arc for Windows", DayThreadsTests.at(16, 45)),
            DayThreadsTests.page("https://docs.google.com/document/d/hn", "Show HN draft - Google Docs", DayThreadsTests.at(18, 50)),
        ])
        diary.act(.selected, on: URL(string: "https://dia.com/pricing")!, words: "$20 a month, billed yearly", at: DayThreadsTests.at(10, 31))
        await diary.rethread(DayThreadsTests.at(9, 0))
        return (diary, folder)
    }

    @Test func aDayNamedIsTheOnlyOneHanded() async throws {
        let (diary, folder) = await Self.seeded()
        defer { try? FileManager.default.removeItem(at: folder) }
        let day = Self.weekday(daysAgo: 3)
        let context = try #require(await AskFromDay.context(for: "what did Dia Pro cost, the one I looked at on \(day)", diary: diary))
        #expect(context.caption == day)
        #expect(context.text.contains("Dia Pro · Plans and pricing · dia.com · 10:20 AM"))
        #expect(context.text.contains("10:31 AM Selected \u{201C}$20 a month, billed yearly\u{201D}"))
        #expect(!context.text.contains("SFO"))
        #expect(context.folder == nil)
        // The agent's numbers, its last line, become the rows.
        let said = "Dia Pro is $20 a month billed yearly.\n\nSources: 1, 4"
        let (answer, numbers) = AskFromDay.cited(said)
        #expect(answer == "Dia Pro is $20 a month billed yearly.")
        #expect(numbers == [1, 4])
        let rows = AskFromDay.rows(context, numbers: numbers)
        #expect(rows.map(\.title) == ["Dia Pro · Plans and pricing", "Pricing table"])
        #expect(rows.map(\.place) == ["dia.com", "Google Sheets"])
        #expect(AskFromDay.rows(context, numbers: nil).isEmpty)
        // Another day names nothing there.
        #expect(await AskFromDay.context(for: "what did Dia Pro cost yesterday", diary: diary) == nil)
    }

    @Test func pickingUpLeadsWithTheThreadAsAFolder() async throws {
        let (diary, folder) = await Self.seeded()
        defer { try? FileManager.default.removeItem(at: folder) }
        let day = Self.weekday(daysAgo: 3)
        let context = try #require(await AskFromDay.context(for: "pick up where I left off on \(day)", diary: diary))
        let resumed = try #require(context.folder)
        #expect(resumed.kind == .folder)
        #expect(resumed.title == "Reopen 3 Pages as a Folder")
        #expect(resumed.urls.first?.absoluteString == "https://news.ycombinator.com/show")
        #expect(context.caption == "\(day), 4:15 to 6:50 PM")
        // Nothing named: the folder and the last page.
        let rows = AskFromDay.rows(context, numbers: [])
        #expect(rows.count == 2)
        #expect(rows[1].title == "Show HN draft")
        #expect(rows[1].place == "Google Docs")
    }

    @Test func theNumbersLineNeverShowsWhileWritten() {
        #expect(AskFromDay.streaming("The answer.\nSour") == "The answer.")
        #expect(AskFromDay.streaming("The answer.\n**Sources:** 2") == "The answer.")
        #expect(AskFromDay.streaming("The answer.\nSo then") == "The answer.\nSo then")
        #expect(AskFromDay.cited("No sources line here.").numbers == nil)
        #expect(AskFromDay.cited("Answer.\nSources: none").numbers == [])
    }

    @Test func agentsReadTheWeekAsThreads() async throws {
        let (diary, folder) = await Self.seeded()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = await AgentHistory.threads(when: "on " + Self.weekday(daysAgo: 3), query: nil, diary: diary)
        #expect(text.contains("say in one plain line what you left out"))
        #expect(text.contains("10:20 to 11:05 AM · Dia Pro (4 pages)"))
        #expect(text.contains("  - Dia Pro · Plans and pricing · https://dia.com/pricing · 10:20 AM"))
        #expect(text.contains("What they did: 10:31 AM Selected \u{201C}$20 a month, billed yearly\u{201D}"))
        let flights = await AgentHistory.threads(when: nil, query: "sfo", diary: diary)
        #expect(flights.contains("SFO · Nov 10"))
        #expect(!flights.contains("Dia Pro"))
        #expect(await AgentHistory.threads(when: "yesterday", query: nil, diary: diary).hasSuffix("Nothing for that."))
    }
}
