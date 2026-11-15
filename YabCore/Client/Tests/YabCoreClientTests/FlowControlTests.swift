import XCTest
import Darwin
@testable import YabCoreClient

final class FlowControlTests: XCTestCase {
    /// Progress patches merge while they wait, but never across the commit
    /// between them, and the asks and the close keep their places.
    func testLatestStateCoalescesWithoutCrossingOrderedEvents() async throws {
        let fake = try TransportFake()
        let client = try await YabCoreClient.connect(path: fake.path)
        let metrics = try await client.request("states", params: ["count": .number(20_000)], timeout: 60)
        XCTAssertGreaterThan(metrics["coalesced"].number ?? 0, 30_000)
        var iterator = client.events.makeAsyncIterator()
        var progress: JSONValue = .null, title: JSONValue = .null, layer: JSONValue = .null
        var ordered: [String] = [], beforeCommit: (JSONValue, JSONValue, JSONValue)?
        var states = 0
        while ordered.count < 3, let event = await iterator.next() {
            switch event.name {
            case "page.state":
                states += 1
                progress = event.params["progress"] ?? progress
                title = event.params["title"] ?? title
            case "layer.changed": layer = event.params["contextId"] ?? layer
            default:
                if event.name == "page.committed" { beforeCommit = (progress, title, layer) }
                ordered.append(event.name)
            }
        }
        XCTAssertEqual(ordered, ["page.committed", "dialog.open", "tab.closed"])
        XCTAssertEqual(beforeCommit?.0, .number(19_999))
        XCTAssertEqual(beforeCommit?.1, .string("before"))
        XCTAssertEqual(beforeCommit?.2, .number(1))
        XCTAssertEqual(progress, .number(39_999)); XCTAssertEqual(title, .string("after")); XCTAssertEqual(layer, .number(2))
        XCTAssertLessThan(states, 1_000, "40,002 patches arrive as a handful")
        await client.disconnect()
    }

    /// A consumer slower than the producer for a long time: everything
    /// arrives in order, the helper never holds more than its budget.
    func testSustainedSlowConsumerRecoversInOrder() async throws {
        let fake = try TransportFake()
        let client = try await YabCoreClient.connect(path: fake.path)
        let consumer = Task { () -> Int in
            var iterator = client.events.makeAsyncIterator()
            var seen = 0
            while seen < 4_000, let event = await iterator.next() {
                guard event.params["sequence"] == .number(Double(seen % 400)) else { return seen }
                seen += 1
                if seen % 10 == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
            }
            return seen
        }
        var peak = 0.0
        for _ in 0..<10 {
            let metrics = try await client.request("burst", params: ["count": .number(400), "pad": .number(2_000)])
            peak = max(peak, metrics["peakWaitingBytes"].number ?? 0)
        }
        let seen = await consumer.value
        XCTAssertEqual(seen, 4_000)
        XCTAssertLessThanOrEqual(peak, 32 * 1024 * 1024)
        await client.disconnect()
    }

    /// One page floods notifications past the budget while nobody consumes.
    /// Only it is shed and told; its ask stays, the calm page loses nothing,
    /// and the wire and every other page go on.
    func testFloodShedsOnlyItsSourceAndKeepsAsks() async throws {
        let fake = try TransportFake()
        let client = try await YabCoreClient.connect(path: fake.path)
        let metrics = try await client.request("flood", params: ["count": .number(20_000), "pad": .number(4_000)], timeout: 120)
        XCTAssertLessThanOrEqual(metrics["peakWaitingBytes"].number ?? .infinity, 32 * 1024 * 1024 + 8_192)
        XCTAssertGreaterThanOrEqual(metrics["shed"].number ?? 0, 1)
        guard case .array(let shedTabs) = metrics["shedTabs"] else { return XCTFail("no shed record") }
        XCTAssertEqual(Set(shedTabs.compactMap(\.string)), ["flood"])
        var iterator = client.events.makeAsyncIterator()
        var calm: [JSONValue] = [], asks = 0, told = 0, flooded = 0
        while calm.count < 3 || told == 0, let event = await iterator.next() {
            if event.tab == "calm" { calm.append(event.params["sequence"] ?? .null) }
            else if event.name == "dialog.open" { asks += 1 }
            else if event.name == "page.eventsShed" { told += 1 }
            else if event.name == "page.started" { flooded += 1 }
        }
        XCTAssertEqual(calm, [.number(0), .number(1), .number(2)])
        XCTAssertEqual(asks, 1)
        XCTAssertGreaterThanOrEqual(told, 1)
        XCTAssertLessThan(flooded, 20_000)
        let after = try await client.request("echo", params: ["still": .bool(true)])
        XCTAssertEqual(after["still"], .bool(true))
        XCTAssertTrue(fake.alive)
        await client.disconnect()
    }

    /// Thirty tabs installing the same megabyte of scripts send it once;
    /// forty different sets leave at most ScriptBundles.kept in the helper.
    func testScriptsGoOnceAndBundlesStayBounded() async throws {
        let fake = try TransportFake()
        let client = try await YabCoreClient.connect(path: fake.path)
        let scripts = JSONValue.array([.object(["source": .string(String(repeating: "x", count: 1024 * 1024)), "world": .string("yab")])])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    _ = try await client.request("scripts.install", params: ["tab": .string("\(index)"), "scripts": scripts, "relays": .object([:])])
                }
            }
            try await group.waitForAll()
        }
        var metrics = try await client.request("metrics")
        XCTAssertEqual(metrics["definitions"], .number(1))
        XCTAssertEqual(metrics["installs"], .number(30))
        for index in 0..<40 {
            let distinct = JSONValue.array([.object(["source": .string("set \(index)"), "world": .string("yab")])])
            _ = try await client.request("scripts.install", params: ["tab": .string("t"), "scripts": distinct, "relays": .object([:])])
        }
        for _ in 0..<50 {
            metrics = try await client.request("metrics")
            if (metrics["bundles"].number ?? .infinity) <= Double(ScriptBundles.kept) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertLessThanOrEqual(metrics["bundles"].number ?? .infinity, Double(ScriptBundles.kept))
        XCTAssertEqual(metrics["installs"], .number(70))
        await client.disconnect()
    }

    /// A helper whose loop is stuck reads nothing. Writers wait their turn
    /// in order with the write window full; nothing disconnects, and all of
    /// them finish once it reads again.
    func testBusyHelperSlowsWritersWithoutDisconnect() async throws {
        let fake = try TransportFake()
        let client = try await YabCoreClient.connect(path: fake.path)
        _ = try await client.request("pause", params: ["seconds": .number(2)])
        let padding = String(repeating: "y", count: 512 * 1024)
        let writers = (0..<40).map { index in
            Task { try await client.request("echo", params: ["index": .number(Double(index)), "padding": .string(padding)], timeout: 60) }
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let socket = await client.socketForTests
        let held = await socket.flowSnapshot()
        XCTAssertLessThanOrEqual(held["output"] ?? .max, Socket.writeWindow + Socket.limit)
        XCTAssertGreaterThan(held["parked"] ?? 0, 0, "writers wait for the stuck helper")
        for (index, writer) in writers.enumerated() {
            let value = try await writer.value
            XCTAssertEqual(value["index"], .number(Double(index)))
        }
        XCTAssertTrue(fake.alive)
        await client.disconnect()
    }
}
