import XCTest
@testable import YabCoreClient

/// Public API only, so YabCore/tests/transport_baseline.sh runs the same test
/// against an older tree's client and transport, where it ends every page.
final class TransportOverflowTests: XCTestCase {
    /// 40,000 ordered events with nobody consuming: past the 32,768 events
    /// whose overflow used to end the helper and every page. The reply comes
    /// back while they wait; what waits stays in the budget; then every one
    /// arrives, in order.
    func testPausedConsumerPastOldCapacityKeepsRepliesAndEveryOrderedEvent() async throws {
        let fake = try TransportFake()
        let client = try await YabCoreClient.connect(path: fake.path)
        let burst = try await client.request("burst", params: ["count": .number(40_000), "pad": .number(200)], timeout: 60)
        let waiting = try await client.request("metrics")
        if waiting["flow"] != .null {
            XCTAssertEqual(waiting["flow"], .bool(true))
            XCTAssertLessThanOrEqual(burst["peakWaitingBytes"].number ?? .infinity, 32 * 1024 * 1024)
            XCTAssertLessThanOrEqual(waiting["outstandingCount"].number ?? .infinity, 512)
            XCTAssertGreaterThan(waiting["waitingEvents"].number ?? 0, 30_000, "the rest waits in the helper")
        }
        var iterator = client.events.makeAsyncIterator()
        for index in 0..<40_000 {
            guard let event = await iterator.next() else { return XCTFail("events ended at \(index): every page would end") }
            XCTAssertEqual(event.name, "page.committed")
            XCTAssertEqual(event.params["sequence"], .number(Double(index)))
            if event.params["sequence"] != .number(Double(index)) { return }
        }
        let after = try await client.request("echo", params: ["still": .bool(true)])
        XCTAssertEqual(after["still"], .bool(true))
        XCTAssertTrue(fake.alive)
        await client.disconnect()
    }

}
