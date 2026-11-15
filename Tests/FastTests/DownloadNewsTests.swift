import Foundation
import Testing
@testable import Fast

@MainActor
struct DownloadNewsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func store(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "DownloadNewsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func file(_ name: String, seconds: TimeInterval) -> Keep {
        Keep(name: name, from: "test", path: "/tmp/" + name, date: now.addingTimeInterval(seconds))
    }

    @Test func doneHidesLatestAndDoesNotFallBackToOlderArrival() {
        store { defaults in
            let kept = [file("latest.pdf", seconds: -1), file("older.pdf", seconds: -30)]
            #expect(DownloadNews.detail(now: now, started: [], kept: kept, defaults: defaults) == "latest.pdf")
            DownloadNews.finish(now: now, defaults: defaults)
            #expect(DownloadNews.detail(now: now, started: [], kept: kept, defaults: defaults) == nil)
        }
    }

    @Test func laterArrivalIncludingTheSamePathAnnouncesItself() {
        store { defaults in
            DownloadNews.finish(now: now, defaults: defaults)
            let next = file("latest.pdf", seconds: 1)
            #expect(DownloadNews.detail(now: now.addingTimeInterval(2), started: [], kept: [next], defaults: defaults) == "latest.pdf")
            #expect(DownloadNews.detail(now: now.addingTimeInterval(602), started: [], kept: [next], defaults: defaults) == nil)
        }
    }

    @Test func activeTransfersAreAcknowledgedAndNewOnesStillAppear() {
        store { defaults in
            let old = now.addingTimeInterval(-10)
            #expect(DownloadNews.detail(now: now, started: [old], kept: [], defaults: defaults) == "1 downloading")
            DownloadNews.finish(now: now, defaults: defaults)
            #expect(DownloadNews.detail(now: now, started: [old], kept: [], defaults: defaults) == nil)
            #expect(DownloadNews.detail(now: now, started: [old, now.addingTimeInterval(1)], kept: [], defaults: defaults) == "1 downloading")
        }
    }

    @Test func acknowledgmentIsPersistentAndNeverMovesBackward() {
        let name = "DownloadNewsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        DownloadNews.finish(now: now, defaults: defaults)
        DownloadNews.finish(now: now.addingTimeInterval(-20), defaults: defaults)
        let reopened = UserDefaults(suiteName: name)!
        #expect(DownloadNews.detail(now: now, started: [], kept: [file("latest.pdf", seconds: -1)], defaults: reopened) == nil)
        #expect(reopened.double(forKey: DownloadNews.doneKey) == now.timeIntervalSince1970)
    }
}
