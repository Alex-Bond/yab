import XCTest
@testable import Fast

/// The chat's field as a surface: a Send?'s yes saying Sending until what
/// it sends has gone or failed, and a question's choices picked by keys.
@MainActor
final class ChatFieldSurfacesTests: XCTestCase {
    func testYesRewordsAroundTheSameWord() {
        XCTAssertEqual(AgentPermit.going("Send"), "Sending")
        XCTAssertEqual(AgentPermit.going("Upload"), "Uploading")
        XCTAssertEqual(AgentPermit.going("Post"), "Posting")
        XCTAssertEqual(AgentPermit.going("Delete"), "Deleting")
        XCTAssertEqual(AgentPermit.going("Submit"), "Submitting")
        XCTAssertEqual(AgentPermit.going("Send Reply"), "Sending Reply")
        XCTAssertEqual(MorphWords.shared("Send", "Sending"), "Send")
    }

    func testOnlyWhatSendsSaysSending() {
        XCTAssertTrue(AgentPermit(kind: .sendMail(to: "Anna", mail: "m"), session: "s", detail: "").sends)
        XCTAssertTrue(AgentPermit(kind: .sendMessage(to: "Anna"), session: "s", detail: "").sends)
        XCTAssertTrue(AgentPermit(kind: .press(label: "Send", ref: "e1"), session: "s", detail: "").sends)
        // A payment has its own sheet; a sign-in or a tab's use sends nothing.
        var pay = AgentPermit(kind: .press(label: "Pay", ref: "e2"), session: "s", detail: "")
        pay.pays = true
        XCTAssertFalse(pay.sends)
        XCTAssertFalse(AgentPermit(kind: .use, session: "s", detail: "").sends)
        XCTAssertFalse(AgentPermit(kind: .signIn(host: "x.com", users: ["a"]), session: "s", detail: "").sends)
    }

    func testFailedSendKeepsTheCardAndTryAgainSendsOnce() async {
        let agents = Agents()
        let tab = Tab(bench: true)
        let permit = AgentPermit(kind: .sendMessage(to: "Anna"), session: "s", detail: "Messages", draft: "Hi")
        agents.going(tab, permit)
        XCTAssertNotNil(tab.sending)
        // A message says how it went itself: the yes taken is not "sent".
        tab.approved = ("s", "imessage:Anna", Date())
        tab.approved = nil
        XCTAssertNotNil(tab.sending)
        XCTAssertNil(tab.sending?.failure)

        var tries = 0
        agents.sent(tab, trouble: "Messages isn't signed in") {
            tries += 1
            return nil
        }
        XCTAssertEqual(tab.sending?.failure, "Messages isn't signed in")
        agents.sendAgain(tab)
        XCTAssertNil(tab.sending?.failure, "Sending again while it tries")
        for _ in 0..<50 where tries == 0 { await Task.yield() }
        XCTAssertEqual(tries, 1)

        // Not Now after a failure: the card goes.
        agents.going(tab, permit)
        agents.sent(tab, trouble: "no") { nil }
        agents.dropSending(tab)
        XCTAssertNil(tab.sending)
    }

    func testAPressIsSentOnceItsYesIsTaken() async {
        let agents = Agents()
        let tab = Tab(bench: true)
        let permit = AgentPermit(kind: .press(label: "Send", ref: "e1"), session: "s", detail: "")
        agents.going(tab, permit)
        tab.approved = ("s", "e1", Date())
        let started = tab.sending?.at
        XCTAssertNotNil(started)
        // Agents.shared hears the yes taken (Tab.approved); here the bench's own.
        agents.consumed(tab)
        // Sending has its beat first, then the card goes.
        XCTAssertNotNil(tab.sending)
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertNil(tab.sending)
    }

    func testChoicesByKeys() {
        let choosing = ChatChoosing()
        let tab = Tab(bench: true)
        tab.choices = ["Tue 10:30", "Wed 2:00", "Thu 9:00"]
        choosing.take(tab)
        choosing.move(tab, by: 1)
        XCTAssertEqual(choosing.lit, 0)
        choosing.move(tab, by: 1)
        choosing.move(tab, by: 1)
        choosing.move(tab, by: 1)
        XCTAssertEqual(choosing.lit, 2, "stops at the last")
        choosing.move(tab, by: -1)
        XCTAssertEqual(choosing.lit, 1)

        // Esc puts them away, keeping the question; ↑ brings them back.
        XCTAssertTrue(choosing.putAway(tab))
        XCTAssertEqual(choosing.away, tab.id)
        XCTAssertFalse(choosing.pickLit(tab))
        choosing.move(tab, by: 1)
        XCTAssertEqual(choosing.away, tab.id, "↓ doesn't bring them back")
        choosing.move(tab, by: -1)
        XCTAssertNil(choosing.away)

        // ↑ from nothing lit starts at the last.
        choosing.take(tab, fresh: true)
        choosing.move(tab, by: -1)
        XCTAssertEqual(choosing.lit, 2)
        XCTAssertTrue(choosing.pickLit(tab))
        XCTAssertEqual(choosing.picked, 2)
        // Picked: nothing moves any more.
        choosing.move(tab, by: -1)
        XCTAssertEqual(choosing.lit, 2)
        // Its answer, a beat later, finds the question gone: nothing told.
        tab.choices = []
    }
}
