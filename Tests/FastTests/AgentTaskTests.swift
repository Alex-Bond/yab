import CoreGraphics
import Foundation
import Testing
@testable import Fast

// What the field takes for a task (AgentTask): a verb first and three words
// or more leads, five words without one sits under the search, and an
// address or a couple of words to look up is never a task.
struct AgentTaskTests {
    @Test(arguments: ["Nintendo Switch", "iPhone 17 Pro", "Nintendo Switch?", "best coffee beans",
                      "lisbon weather", "lisbon weather?", "best espresso grinder under 300 dollars",
                      "how to center a div", "HOW TO reset AirPods?", "where to buy coffee",
                      "what to see in lisbon", "weather?", "what is", "https://example.com/how?to=reset"])
    func ordinaryQueriesStaySearches(_ words: String) {
        #expect(!TaskWords.question(words))
        #expect(TaskWords.strength(words) != .strong)
    }

    @Test(arguments: ["how do I reset my AirPods", "How do I reset my AirPods?", "is figma down",
                      "what is the weather in lisbon", "can you explain this page?", "why not?"])
    func clearQuestionsStillAsk(_ words: String) {
        #expect(TaskWords.question(words))
        #expect(TaskWords.strength(words) != .strong)
    }

    @Test func verbsLead() {
        #expect(TaskWords.strength("find the best espresso grinder under $300 on 10 sites") == .strong)
        #expect(TaskWords.strength("Compare flights to Lisbon") == .strong)
        #expect(TaskWords.strength("book a table for two") == .strong)
    }

    /// The tweet's words (an address, then what to do with it) are a
    /// task, not a search.
    @Test func saveThePageAsAFile() {
        #expect(TaskWords.strength("save this page as pdf") == .strong)
        #expect(TaskWords.strength("https://karrisaarinen.com/posts/room-for-ambition/ save this page as pdf") == .strong)
        #expect(TaskWords.strength("https://example.com/a and https://example.com/b") == nil)
    }

    @Test func savedFilesShowUnderTheAnswer() {
        #expect(ChatItem.savedFile("save_page", "Saved: /Users/a/Downloads/yab/T/Room.pdf (570 KB)") == "/Users/a/Downloads/yab/T/Room.pdf")
        #expect(ChatItem.savedFile("pdf", "Saved: /x/y.pdf") == "/x/y.pdf")
        #expect(ChatItem.savedFile("download", "Still downloading into /x/y.zip") == nil)
        #expect(ChatItem.savedFile("text", "Saved: /x/y.pdf") == nil)
        #expect(PageSave.format("Markdown") == "md")
        #expect(PageSave.format(nil) == "pdf")
        #expect(PageSave.format("docx") == nil)
    }

    /// A tall page cut into Letter pages, as many as its height needs.
    @Test func tallPageCutIntoPages() throws {
        let tall = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 800, height: 3000)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: tall as CFMutableData)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        let paged = try #require(PageSave.pages(tall as Data))
        let document = try #require(CGPDFDocument(CGDataProvider(data: paged as CFData)!))
        // 800 wide → 612: a page holds 792 / 0.765 = 1035 points of it.
        #expect(document.numberOfPages == 3)
    }

    @Test func longWordsOnlyMight() {
        #expect(TaskWords.strength("the best espresso grinder under 300") == .weak)
    }

    @Test func addressesAndSearchesAreNot() {
        #expect(TaskWords.strength("espresso grinder") == nil)
        #expect(TaskWords.strength("find github.com/openai issues") == nil)
        #expect(TaskWords.strength("https://example.com find this") == nil)
        #expect(TaskWords.strength("best grinder 2026") == nil)
    }

    @MainActor @Test func thePickIsTheFirstLine() {
        #expect(TaskAnswer.pick("# Baratza Encore ESP, $199\n\nWhy…") == "Baratza Encore ESP, $199")
        #expect(TaskAnswer.pick("\n**Walmart is cheapest**\nmore") == "Walmart is cheapest")
        #expect(TaskAnswer.pick("") == nil)
    }

    @Test func writingWordsLeaveADraft() {
        #expect(TaskWords.writes("Reply that we can do $36k if we start in November"))
        #expect(!TaskWords.writes("summarize this thread"))
    }

    @MainActor @Test func aLastingChangeReadsTheBoostsSkill() {
        // One short sentence in the page task's prompt, naming the skill.
        #expect(Agents.boostHint == "To make a site look or work differently every time, read skill('boosts') first.")
    }
}
