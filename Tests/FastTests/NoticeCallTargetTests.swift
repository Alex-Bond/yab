import Foundation
import Testing
@testable import Fast

struct NoticeCallTargetTests {
    @Test func showRoutesTheDisplayedTargetToItsOwnerRatherThanTheCurrentWindow() {
        let local = UUID(), remote = UUID()
        let target = NoticeCallTarget(tab: remote, question: "question-one")
        var selected: UUID?
        let owners = [remote: "other-window"]
        let result = target.show(current: target) { id in
            selected = id
            return owners[id] != nil
        }
        #expect(result == .shown)
        #expect(selected == remote && selected != local)
    }

    @Test func staleOrResolvedQuestionNeverInvokesTheRevealCallback() {
        let tab = UUID()
        let old = NoticeCallTarget(tab: tab, question: "old")
        let fresh = NoticeCallTarget(tab: tab, question: "fresh")
        var calls = 0
        #expect(old.show(current: fresh) { _ in calls += 1; return true } == .stale)
        #expect(old.show(current: nil) { _ in calls += 1; return true } == .stale)
        #expect(calls == 0)
        #expect(old != fresh)
    }

    @Test func vanishedOwnerIsMissingWithoutRedirectingToAnUnrelatedTab() {
        let target = NoticeCallTarget(tab: UUID(), question: "pending")
        var seen: [UUID] = []
        #expect(target.show(current: target) { seen.append($0); return false } == .missing)
        #expect(seen == [target.tab])
        // Dismissal is local identity only; a new question on this same tab differs.
        let dismissed = target
        #expect(dismissed == target)
        #expect(dismissed != NoticeCallTarget(tab: target.tab, question: "next"))
    }

    @Test func delayedFlingKeepsItsCapturedQuestionWhenTheBannerWordsStayTheSame() {
        let tab = UUID()
        let a = NoticeCallTarget(tab: tab, question: "A")
        let b = NoticeCallTarget(tab: tab, question: "B")
        var current: NoticeCallTarget? = a
        var hidden: [NoticeCallTarget] = []
        // NoticeFling saves this operation, with A captured, before its delay.
        let pendingA = { a.dismiss(current: current) { hidden.append($0) } }
        current = b
        #expect(a.flingToken != b.flingToken)
        #expect(!pendingA())
        #expect(hidden.isEmpty)
        current = nil
        #expect(!pendingA())
        #expect(hidden.isEmpty)
        current = a
        #expect(pendingA())
        #expect(hidden == [a])
        #expect(hidden.first != b)
        // A's local dismissal cannot make the next question ineligible.
        #expect(b != hidden.first)
        #expect(NoticeCallTarget(tab: tab, question: nil).flingToken
                != NoticeCallTarget(tab: tab, question: "").flingToken)
    }

}
