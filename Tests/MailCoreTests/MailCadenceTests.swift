import Foundation
import Testing
@testable import MailCore
import MailCoreFakes

// How often mail asks Gmail (docs/mail.md, Sync): the rhythm for each state
// of the Mac, what an hour of it costs of Google's quota, when the next beat
// is due, and an ask that finds nothing new changing nothing.
struct MailCadenceTests {
    typealias State = MailCadence.State

    @Test func eachStateHasItsRhythm() {
        #expect(MailCadence.every(State(mailInFront: true, active: true)) == 10)
        // Mail's page on screen behind another app: still looked at.
        #expect(MailCadence.every(State(mailInFront: true)) == 10)
        #expect(MailCadence.every(State(active: true)) == 15)
        #expect(MailCadence.every(State(active: true, notifying: true)) == 15)
        #expect(MailCadence.every(State(notifying: true)) == 30)
        #expect(MailCadence.every(State()) == 300)
        // A code box waiting: every 2 seconds, Low Power or not.
        #expect(MailCadence.every(State(quick: true, mailInFront: true)) == 2)
        #expect(MailCadence.every(State(quick: true, lowPower: true)) == 2)
    }

    @Test func asleepAndLowPowerAskNothing() {
        #expect(MailCadence.every(State(asleep: true, mailInFront: true, active: true, notifying: true)) == nil)
        #expect(MailCadence.every(State(quick: true, asleep: true)) == nil)
        #expect(MailCadence.every(State(lowPower: true, mailInFront: true, active: true, notifying: true)) == nil)
        #expect(MailCadence.every(State(lowPower: true)) == nil)
    }

    @Test func aBatteryNearlyOutWaitsOnlyBehindOtherApps() {
        #expect(MailCadence.every(State(lowBattery: true, notifying: true)) == 300)
        #expect(MailCadence.every(State(lowBattery: true, active: true, notifying: true)) == 15)
        #expect(MailCadence.every(State(lowBattery: true, mailInFront: true)) == 10)
        // On a battery with charge left, the same as plugged in.
        #expect(MailCadence.every(State(notifying: true)) == 30)
    }

    @Test func anHourOfAskingCostsLittleQuota() {
        // A history.list is 2 units; Google gives 6,000 a minute, MailPace spends 4,800 at most.
        #expect(MailCadence.units(perHour: 10) == 720)
        #expect(MailCadence.units(perHour: 15) == 480)
        #expect(MailCadence.units(perHour: 30) == 240)
        #expect(MailCadence.units(perHour: 300) == 24)
        #expect(MailCadence.units(perHour: 2) == 3600)
        #expect(MailCadence.units(perHour: nil) == 0)
        // The fastest steady rhythm, mail in front, is 12 units a minute.
        #expect(MailCadence.units(perHour: 10) / 60 == 12)
        // Even a code box's two minutes are 120 units of a minute's 6,000.
        #expect(MailCadence.units(perHour: 2) / 30 == 120)
    }

    @Test func theNextBeatIsTheSoonestDue() {
        let now = Date()
        #expect(MailCadence.next(asks: [(now.addingTimeInterval(-4), 10, nil)], snoozed: nil, now: now) == now.addingTimeInterval(6))
        // Two accounts: the sooner one.
        #expect(MailCadence.next(asks: [(now.addingTimeInterval(-4), 10, nil), (now.addingTimeInterval(-100), 300, nil)],
                                 snoozed: nil, now: now) == now.addingTimeInterval(6))
        // Resting after Gmail said slow down: not before the rest is over.
        #expect(MailCadence.next(asks: [(now.addingTimeInterval(-4), 10, now.addingTimeInterval(20))], snoozed: nil, now: now)
                == now.addingTimeInterval(20))
        // A snoozed thread due sooner comes back on time.
        #expect(MailCadence.next(asks: [(now.addingTimeInterval(-4), 10, nil)], snoozed: now.addingTimeInterval(3), now: now)
                == now.addingTimeInterval(3))
        // Overdue: now.
        #expect(MailCadence.next(asks: [(now.addingTimeInterval(-400), 300, nil)], snoozed: nil, now: now) == now)
        // Low Power, nothing snoozed: no beat at all.
        #expect(MailCadence.next(asks: [(now, nil, nil)], snoozed: nil, now: now) == nil)
    }

    @Test func aQuietAskChangesNothing() async throws {
        let fake = FakeGmail()
        QuietGmail.fake = fake
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuietGmail.self]
        let gmail = MailGmail(session: URLSession(configuration: config), token: { "token" }, tries: 2, wait: 0.01)
        let store = MailStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("quiet-\(UUID().uuidString).sqlite"))
        fake.add(.init(id: "a1", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Thursday works?",
                       body: "Can we do the review Thursday?", at: Date().addingTimeInterval(-3600), labels: ["INBOX", "UNREAD"]), record: false)
        let sync = MailSync(store: store, gmail: gmail)
        #expect(try await sync.sync())
        let history = store.value("history")
        fake.calls = []
        // Nothing new: one history.list, nothing fetched, nothing written.
        #expect(try await sync.sync() == false)
        #expect(fake.calls == ["GET history"])
        #expect(store.value("history") == history)
        fake.add(.init(id: "a2", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Re: Thursday works?",
                       body: "Or Friday?", at: Date(), labels: ["INBOX", "UNREAD"]))
        #expect(try await sync.sync())
        #expect(store.messages(thread: "ta").count == 2)
    }
}

/// The Gmail in memory of MailSyncTests, behind a protocol of its own, so
/// these tests never share one with that suite running beside them.
final class QuietGmail: URLProtocol {
    nonisolated(unsafe) static var fake = FakeGmail()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = QuietGmail.fake.answer(request)
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
