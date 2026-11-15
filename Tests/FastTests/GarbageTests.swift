import Foundation
import Testing
import WebKit
@testable import Fast

// What hidden pages dropped, collected while the Mac is idle (Garbage).
@MainActor
@Suite(.serialized)
struct GarbageTests {
    @Test func webKitStillHasItsCollection() {
        // The SPI it calls: gone from a WebKit, the collector stays off
        // rather than crashing, and this says so.
        #expect(Web.pool.responds(to: NSSelectorFromString("_garbageCollectJavaScriptObjectsForTesting")))
    }

    @Test func atMostEveryFifteenMinutesAfterAMinuteIdle() {
        guard ProcessInfo.processInfo.environment["YAB_COLLECT_EVERY"] == nil,
              ProcessInfo.processInfo.environment["YAB_COLLECT_IDLE"] == nil else { return }
        #expect(Garbage.every == 15 * 60)
        #expect(Garbage.idle == 60)
    }

    @Test func collectingCounts() {
        let before = Garbage.count
        Garbage.collect()
        #expect(Garbage.count == before + 1)
    }
}
