import Foundation
import SyncKit
import UserNotifications
import XCTest
@testable import YabPhone

/// The server's alert of a Mac agent's question carries it sealed; this
/// iPhone opens it with the account's key and says it in full. Another
/// account's key, a record moved under another name, another collection or
/// a question run out all keep the alert's generic words.
final class ApprovalNoticeTests: XCTestCase {
    private func sealed(_ seal: Seal, expires: Date = Date().addingTimeInterval(300), collection: String = AssistantApprovalRecords.requestCollection)
        throws -> (info: [AnyHashable: Any], request: AssistantApprovalRecords.Request) {
        let id = UUID().uuidString.lowercased()
        let request = try AssistantApprovalRecords.Request(
            id: id, account: seal.account, mac: "mac", assistant: "local.external", session: "s",
            tab: UUID().uuidString.lowercased(), permit: "e1", title: "Claude: Pay · $12.00?",
            lines: ["shop.example", "Amount: $12.00", "A long draft\nwith lines"], expires: expires)
        let record = Record(collection: collection, id: id, fields: try request.fields(), stamps: ["body": Stamp(wall: 1, device: "mac")])
        let name = seal.name(record.key)
        return (["yab": ["n": name, "b": try seal.seal(record).base64EncodedString()]], request)
    }

    func testReconciliationIncludesAlertsFromBeforeThisLaunchAndPreservesOtherThreads() throws {
        let (_, request) = try sealed(Seal.make())
        let inbox: [(identifier: String, approval: String?, thread: String)] = [
            ("server-request-id", request.id.uppercased(), "approval"),
            ("older-question", nil, "approval"),
            ("mail-notice", nil, "mail")
        ]
        XCTAssertEqual(ApprovalNotice.stale(inbox, requests: [request]), ["older-question"])
        var seen = request
        seen.seen = .init(device: request.mac)
        XCTAssertEqual(ApprovalNotice.stale(inbox, requests: [seen]), ["server-request-id", "older-question"])
        XCTAssertEqual(ApprovalNotice.stale(inbox, requests: []), ["server-request-id", "older-question"])
        XCTAssertEqual(seen.yesLabel, "Approve")
    }

    func testAQuestionAlreadyDeliveredPendingOrAnnouncedDoesNotRingAgain() {
        let question = ApprovalNotice.Shown(id: "a", title: "Claude: Search your mail?", body: "Travel")
        XCTAssertEqual(ApprovalNotice.fresh([question], present: [], announced: []), [question])
        XCTAssertTrue(ApprovalNotice.fresh([question], present: ["A"], announced: []).isEmpty)
        XCTAssertTrue(ApprovalNotice.fresh([question], present: [], announced: ["A"]).isEmpty)
    }

    func testAQuestionIsTimeSensitiveWithItsOwnSound() throws {
        let question = ApprovalNotice.Shown(id: "a", title: "Claude: Pay · $12.00?", body: "shop.example")
        let content = ApprovalNotice.content(question)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.sound, UNNotificationSound(named: UNNotificationSoundName("ask.caf")))
        XCTAssertEqual(content.threadIdentifier, "approval")
        XCTAssertNotNil(Bundle.main.url(forResource: "ask", withExtension: "caf"), "the sound sits at the app bundle's root")
    }

    func testOnlyTheQuestionChangesWhatTheAlertCarries() {
        // Another alert (mail, a chat) isn't opened, so Notify/ leaves it as it came.
        XCTAssertNil(ApprovalNotice.open(["aps": ["thread-id": "mail"]], seal: Seal.make()))
        let pushed = UNMutableNotificationContent()
        pushed.userInfo = ["other": 1]
        pushed.categoryIdentifier = "kept"
        let opened = ApprovalNotice.content(.init(id: "b", title: "t", body: "b"), into: pushed)
        XCTAssertEqual(opened.categoryIdentifier, "kept")
        XCTAssertEqual(opened.userInfo["other"] as? Int, 1)
        XCTAssertEqual(opened.userInfo["approval"] as? String, "b")
    }

    func testTheAccountsKeyOpensTheQuestion() throws {
        let seal = Seal.make()
        let (info, request) = try sealed(seal)
        let shown = try XCTUnwrap(ApprovalNotice.open(info, seal: seal))
        XCTAssertEqual(shown, .init(id: request.id, title: "Claude: Pay · $12.00?", body: "shop.example \u{B7} Amount: $12.00"))
        XCTAssertEqual(request.asker, "Claude")
        XCTAssertEqual(request.question, "Pay · $12.00?")
    }

    func testWhatDoesntOpenKeepsTheGenericWords() throws {
        let seal = Seal.make()
        let (info, _) = try sealed(seal)
        XCTAssertNil(ApprovalNotice.open(info, seal: Seal.make()))
        XCTAssertNil(ApprovalNotice.open(info, seal: nil))
        XCTAssertNil(ApprovalNotice.open([:], seal: seal))
        var moved = info
        moved["yab"] = ["n": "another-name", "b": (info["yab"] as? [String: String])?["b"] ?? ""]
        XCTAssertNil(ApprovalNotice.open(moved, seal: seal))
        let (other, _) = try sealed(seal, collection: "task")
        XCTAssertNil(ApprovalNotice.open(other, seal: seal))
        let (late, _) = try sealed(seal, expires: Date().addingTimeInterval(60))
        XCTAssertNil(ApprovalNotice.open(late, seal: seal, now: Date().addingTimeInterval(120)))
    }
}
