import Foundation
import Testing
@testable import Fast

// What a model's reply turns into over a new chat: its lines, without list
// marks, the words inside them untouched.
@MainActor
struct ChatIdeasTests {
    @Test func marksGoWordsStay() {
        #expect(ChatIdeas.plain("1. Open \"Neural networks explained in 60 seconds!\"") == "Open \"Neural networks explained in 60 seconds!\"")
        #expect(ChatIdeas.plain("2) Find the paper.") == "Find the paper")
        #expect(ChatIdeas.plain("- Compare \"A\" and \"B\"") == "Compare \"A\" and \"B\"")
        #expect(ChatIdeas.plain("\u{2022} Wait...") == "Wait...")
        #expect(ChatIdeas.plain("Top 10") == "Top 10")
        #expect(ChatIdeas.plain("Swift 6.2") == "Swift 6.2")
        #expect(ChatIdeas.plain("3D printing basics") == "3D printing basics")
    }

    @Test func wrappingQuotesGoInnerOnesStay() {
        #expect(ChatIdeas.plain("\"Summarize this\"") == "Summarize this")
        #expect(ChatIdeas.plain("\u{AB}Résumé\u{BB}") == "Résumé")
        #expect(ChatIdeas.plain("\"A\" vs \"B\"") == "\"A\" vs \"B\"")
    }

    @Test func tooLongIsNoIdea() {
        let reply = "1. One\n2. Two\n3. What is the difference between \"Trump Mamdani Cold Open\" and \"ABC World News Tonight\"?"
        #expect(ChatIdeas.lines(reply) == ["One", "Two"])
        #expect(ChatIdeas.lines("Only one") == nil)
    }
}
