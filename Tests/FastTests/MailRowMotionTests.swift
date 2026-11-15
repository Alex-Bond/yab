import Foundation
import Testing
@testable import Fast

// A row's own motion (docs/mail.md, Motion): its labels as chips, and an
// agent's hand taking out the rows its mail_act took, never holding up
// anything the person does.
@Suite(.serialized) @MainActor
struct MailRowMotionTests {
    @Test func chipsAreThePersonsOwnLabels() {
        let labels: Set<String> = ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS", "Label_12", "STARRED", "Label_3"]
        #expect(MailDesk.userLabels(labels) == ["Label_12", "Label_3"])
        #expect(MailDesk.userLabels(["INBOX", "SENT"]).isEmpty)
    }

    @Test func handLeadsOnlyRowsAnAgentJustTook() {
        let hand = MailHand()
        let now = Date()
        hand.touch("a|1", now: now)
        hand.touch("a|2", now: now)
        #expect(hand.leads(["a|1"], now: now.addingTimeInterval(1)))
        #expect(hand.leads(["a|1", "a|2"], now: now.addingTimeInterval(1)))
        // One the person took with it, or none at all: not the agent's.
        #expect(!hand.leads(["a|1", "a|3"], now: now.addingTimeInterval(1)))
        #expect(!hand.leads([], now: now))
        // Long after mail_act: another device's doing, not the agent's.
        #expect(!hand.leads(["a|1"], now: now.addingTimeInterval(MailHand.window + 1)))
    }

    @Test func nothingWaitsForTheHand() {
        let hand = MailHand()
        var gone = 0
        hand.press(at: CGPoint(x: 10, y: 10)) { gone += 1 }
        #expect(gone == 0)
        // A key, a load or another press: what it held happens at once, once.
        hand.flush()
        #expect(gone == 1)
        hand.flush()
        #expect(gone == 1)
        hand.press(at: CGPoint(x: 10, y: 10)) { gone += 1 }
        hand.press(at: CGPoint(x: 10, y: 50)) { gone += 10 }
        #expect(gone == 2)
        hand.away()
        #expect(gone == 12)
    }
}
