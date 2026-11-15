import Testing
import SyncKit
@testable import Fast

/// A row of Now handed to the agent (Do It) goes with its first message as
/// one line of the item's detail, which the Mac and the iPhone both read.
struct HandedCardTests {
    @Test func aCardSurvivesItsLine() {
        let card = SyncHanded(host: "mail.google.com", title: "3 more Builder cancellations to pass to support",
                              detail: "Graham Muir (Amex 1032, failed Oct 14), Yatong Wen", from: "From Now · Graham Muir")
        #expect(SyncHanded.parse(card.label) == card)
        // Among a message's other things, one a line.
        #expect(SyncHanded.parse("t:github.com|Pull\n" + card.label + "\nf:notes.txt") == card)
    }

    @Test func tabsAndBreaksInsideFieldsDoNotSplitIt() {
        let card = SyncHanded(host: "", title: "Two\tparts", detail: "line one\nline two", from: "From Now")
        let read = SyncHanded.parse(card.label)
        #expect(read?.title == "Two parts")
        #expect(read?.detail == "line one line two")
        #expect(read?.host == "")
    }

    @Test func noCardWithoutOne() {
        #expect(SyncHanded.parse("") == nil)
        #expect(SyncHanded.parse("t:github.com|Pull") == nil)
        #expect(SyncHanded.parse("w:only\ttwo") == nil)
    }
}
