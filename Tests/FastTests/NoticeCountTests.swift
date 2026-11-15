import Foundation
import Testing
@testable import Fast

/// The corner counting down to a send: "Sending in 5s" while ⌘Z can still
/// take it back, a second at a time, at one width.
@MainActor
struct NoticeCountTests {
    @Test func theCountIsTheWholeSecondsLeft() {
        let until = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(Notice.count(until, at: until.addingTimeInterval(-5)) == 5)
        #expect(Notice.count(until, at: until.addingTimeInterval(-4.5)) == 5)
        #expect(Notice.count(until, at: until.addingTimeInterval(-4)) == 4)
        #expect(Notice.count(until, at: until.addingTimeInterval(-0.2)) == 1)
        // Still said once the time is up, until the corner lets it go.
        #expect(Notice.count(until, at: until.addingTimeInterval(0.3)) == 1)
    }

    @Test func aCountKeepsItsWidthAsItsDigitsGo() {
        #expect(Notice.counting("Sending", 5, span: 5) == "Sending in 5s")
        #expect(Notice.counting("Sending", 20, span: 20) == "Sending in 20s")
        #expect(Notice.counting("Sending", 9, span: 20) == "Sending in \u{2007}9s")
        let until = Date().addingTimeInterval(20)
        let start = Say.toast("Sending", mark: "paperplane", keys: ["⌘", "Z"], until: until, span: 20)
        let plain = Say.toast("Sending", mark: "paperplane", keys: ["⌘", "Z"])
        #expect(Notice.size(of: start).width > Notice.size(of: plain).width)
        #expect(Notice.headWidth(start) == Notice.headWidth(Say.toast("Sending", mark: "paperplane", keys: ["⌘", "Z"], until: until.addingTimeInterval(-11), span: 20)))
    }

    @Test func theToasterKeepsTheCountItStartedFrom() {
        let toaster = Toaster()
        let until = Date().addingTimeInterval(10)
        toaster.pop("Sending", mark: "paperplane", keys: ["⌘", "Z"], stay: 10, until: until)
        #expect(toaster.until == until)
        #expect(toaster.said.until == until && toaster.said.span == 10)
        #expect(toaster.words == "Sending")
        // Something else said over it counts nothing.
        toaster.pop("Link copied")
        #expect(toaster.until == nil && toaster.said.until == nil)
        toaster.dismiss()
    }
}
