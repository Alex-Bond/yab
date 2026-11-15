import Foundation
import SyncKit
import XCTest
@testable import YabPhone

/// The approval tray's logic without a screen: what a question is shaped
/// into, a drag picking up where the piece is (no jump as a gesture is
/// recognized), shares coming to rest on their targets, and a payment's
/// picks and forms.
@MainActor
final class ApprovalTrayTests: XCTestCase {
    private func request(_ permit: String = "press:pay", lines: [String] = ["amazon.com", "Amount: $42.10"],
                         tab: String = "0b8f0c3e-5c55-4bd8-8f5e-3cb6f7a1e2d4", choices: [String]? = nil) throws -> AssistantApprovalRecords.Request {
        try AssistantApprovalRecords.Request(id: "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10", account: "a", mac: "mac", assistant: "local.claude",
                                             session: "s", tab: tab, permit: permit, title: "Claude: Pay $42.10?", lines: lines,
                                             expires: Date().addingTimeInterval(300), choices: choices)
    }

    func testShapesEachKind() throws {
        let r = try request()
        let pay = AssistantApprovalRecords.Detail(id: r.id, pay: .init(site: "amazon.com", item: "Tips", amount: "$42.10",
                                                                       cards: [.init(id: "c1", brand: "Visa", last4: "6411", name: "")]))
        let shaped = ApprovalContent(r, detail: pay)
        XCTAssertEqual(shaped.kind, .pay)
        XCTAssertEqual(shaped.verb, "Pay $42.10")
        XCTAssertNil(shaped.question, "the receipt says it: no question over it")
        // An older Mac: its lines, the question without the agent's name.
        let old = ApprovalContent(r, detail: nil)
        XCTAssertEqual(old.kind, .lines)
        XCTAssertEqual(old.question, "Pay $42.10?")
        XCTAssertEqual(old.name, "amazon.com")
        XCTAssertEqual(old.lines, ["Amount: $42.10"])
        // A sign-in: one row an account.
        let signIn = ApprovalContent(try request("signin:github.com", lines: ["github.com"], choices: ["ann", "bob"]), detail: nil)
        XCTAssertEqual(signIn.kind, .accounts)
        XCTAssertEqual(signIn.accounts, ["ann", "bob"])
        // Fourteen mails show three rows and "11 more".
        let mails = (0..<14).map { AssistantApprovalRecords.Detail.Mail(id: "m\($0)", from: .init(name: "Sender \($0)"), to: [], subject: "S",
                                                                         body: "B", date: 1) }
        let archive = ApprovalContent(try request("mail.change:archive", tab: "chat:x"), detail: .init(id: r.id, verb: "Archive 14", mails: mails))
        XCTAssertEqual(archive.kind, .mails)
        XCTAssertEqual(archive.shown, 3)
        XCTAssertEqual(archive.name, "Your mail")
    }

    func testAnOlderMacsMailBatchBecomesRows() throws {
        // As 0.34.2 writes "Send these 3 mails?" from an x.com tab: no detail.
        let draft = """
        1. To dane@gmail.com · Re: Yab 0.32
        Hey Dane, Yab 0.34.4 is out.

        Each account has a switch.

        2. To ilya@gmail.com · Cc ann@x.co · Re: Yab 0.33.3
        Hey Ilya, in 0.34.3 Auto no longer picks a model you don't have.

        3. To henrique@gmail.com · Re: Yab 0.33.3
        Hey Henrique, the gray space
        """
        let r = try request("mail.send:batch", lines: ["x.com", "To Dane Kapoor; ilya@gmail.com; henrique@gmail.com", draft])
        let shaped = ApprovalContent(r, detail: nil)
        XCTAssertEqual(shaped.kind, .mails)
        XCTAssertEqual(shaped.name, "Your mail", "mail going out isn't the page the agent is on")
        XCTAssertEqual(shaped.verb, "Send All 3")
        XCTAssertEqual(shaped.items.map(\.title), ["Dane Kapoor", "ilya@gmail.com", "henrique@gmail.com"])
        XCTAssertEqual(shaped.items.map(\.subtitle), ["Re: Yab 0.32", "Re: Yab 0.33.3", "Re: Yab 0.33.3"])
        XCTAssertEqual(shaped.items[0].snippet, "Hey Dane, Yab 0.34.4 is out.")
        XCTAssertEqual(shaped.items[1].mail?.cc.map(\.name), ["ann@x.co"])
        XCTAssertEqual(shaped.items[0].mail?.body, "Hey Dane, Yab 0.34.4 is out.\n\nEach account has a switch.")
    }

    func testAMailSearchAsksForTheChat() throws {
        let lines = ["Reply to testers", "once for this chat"]
        let r = try request("mail.read", lines: lines, tab: "chat:x")
        let said = AssistantApprovalRecords.Detail(id: r.id, verb: "Allow in This Chat",
                                                   text: "Looks for \u{201C}Yab 0.32\u{201D}\nClaude reads what it finds on your plan.")
        let shaped = ApprovalContent(r, detail: said)
        XCTAssertEqual(shaped.kind, .search)
        XCTAssertEqual(shaped.search?.words, "Yab 0.32")
        XCTAssertEqual(shaped.search?.opens, false)
        XCTAssertEqual(shaped.terms, "Claude reads what it finds on your plan.")
        XCTAssertEqual(shaped.sub, "In \u{201C}Reply to testers\u{201D}")
        XCTAssertEqual(shaped.verb, "Allow in This Chat")
        let opening = ApprovalContent(r, detail: .init(id: r.id, text: "Opens \u{201C}Re: Contract\u{201D}"))
        XCTAssertEqual(opening.search?.words, "Re: Contract")
        XCTAssertEqual(opening.search?.opens, true)
        XCTAssertNil(opening.terms)
        // An older Mac: the scope, the yes for the chat.
        let old = ApprovalContent(r, detail: nil)
        XCTAssertEqual(old.kind, .search)
        XCTAssertNil(old.search)
        XCTAssertEqual(old.verb, "Allow in This Chat")
    }

    func testDragPicksUpWhereThePieceIs() throws {
        let tray = ApprovalTray()
        tray.show(try request(), detail: nil)
        tray.measured(.root, height: 300)
        tray.hold(rise: 0)
        // Recognized 12 points down: the tray stays put, then follows.
        tray.trayDragChanged(12)
        XCTAssertEqual(tray.drag, 0, accuracy: 0.001)
        tray.trayDragChanged(40)
        XCTAssertEqual(tray.drag, 28, accuracy: 0.001)
        tray.trayDragEnded(40, velocity: 0, height: 360)
    }

    func testSharesComeToRestOnTheirTargets() {
        var seen: CGFloat = -1
        let spring = UnitSpring(0) { seen = $0 }
        spring.set(0.97)
        XCTAssertEqual(seen, 0.97, accuracy: 1e-6)
        XCTAssertEqual(spring.target, 0.97, accuracy: 1e-6)
    }

    func testCardFormNeedsARealNumber() {
        var form = ApprovalTray.CardForm(number: "4242 4242 4242 4241", expires: "08 / 29", csc: "123", name: "S")
        XCTAssertNil(form.filled)
        form.number = "4242 4242 4242 4242"
        XCTAssertEqual(form.filled?.month, 8)
        XCTAssertEqual(form.filled?.year, 2029)
        var place = ApprovalTray.PlaceForm(name: "S", street: "1 Main St", apt: "Apt 4", city: "", postal: "11201")
        XCTAssertNil(place.filled)
        place.city = "Brooklyn"
        XCTAssertEqual(place.filled?.street, "1 Main St\nApt 4")
    }

    func testReceiptWords() throws {
        let r = try request("message:mom", lines: ["mail.google.com"])
        let message = ApprovalContent(r, detail: .init(id: r.id, verb: "Send", text: "Late", person: .init(name: "Mom")))
        XCTAssertEqual(ApprovalTray.pastWords(message), "Sent")
    }
}
