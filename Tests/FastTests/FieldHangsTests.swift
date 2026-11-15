import XCTest
@testable import Fast

/// MetricKit's hang histograms as they go to the site (FieldHangs): this
/// version's, the last 24 hours, never twice, summed by bucket, no id.
final class FieldHangsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_759_660_000)

    private func day(_ hoursAgo: Double, version: String = "0.0.9", build: String? = "202610060900", mixed: Bool = false,
                     _ buckets: [FieldHangs.Bucket]) -> FieldHangs.Day {
        FieldHangs.Day(version: version, build: build, mixed: mixed,
                       end: now.addingTimeInterval(-hoursAgo * 60 * 60), buckets: buckets)
    }

    private func b(_ from: Int, _ to: Int, _ count: Int) -> FieldHangs.Bucket {
        FieldHangs.Bucket(from: from, to: to, count: count)
    }

    func testBucketsAreWholeMillisecondsFromAnyUnit() {
        XCTAssertEqual(FieldHangs.bucket(from: Measurement(value: 0.25, unit: .seconds),
                                         to: Measurement(value: 0.5, unit: .seconds), count: 3), b(250, 500, 3))
        XCTAssertEqual(FieldHangs.bucket(from: Measurement(value: 1000.4, unit: .milliseconds),
                                         to: Measurement(value: 2, unit: .seconds), count: 1), b(1000, 2000, 1))
    }

    func testDaysAreSummedByBucketAndEmptyOnesLeftOut() {
        let sent = FieldHangs.toSend([
            day(2, [b(250, 500, 3), b(500, 1000, 0), b(1000, 2000, 1)]),
            day(20, [b(250, 500, 2), b(2000, 5000, 1)]),
        ], version: "0.0.9", build: 202610060900, now: now, after: nil)
        XCTAssertEqual(sent, [b(250, 500, 5), b(1000, 2000, 1), b(2000, 5000, 1)])
    }

    func testOnlyThisVersionOnlyTheLastDayNeverTwice() {
        let hangs = [b(250, 500, 4)]
        func send(_ days: [FieldHangs.Day], after: Date? = nil) -> [FieldHangs.Bucket] {
            FieldHangs.toSend(days, version: "0.0.9", build: 202610060900, now: now, after: after)
        }
        XCTAssertEqual(send([day(1, hangs)]), hangs)
        XCTAssertEqual(send([day(1, build: nil, hangs)]), hangs, "no build said: the version decides")
        XCTAssertEqual(send([day(1, version: "0.0.8", hangs)]), [])
        XCTAssertEqual(send([day(1, build: "202610050900", hangs)]), [], "an earlier build of the same version")
        XCTAssertEqual(send([day(1, mixed: true, hangs)]), [], "a day across an update")
        XCTAssertEqual(send([day(25, hangs)]), [], "older than a day")
        XCTAssertEqual(send([day(1, hangs)], after: now.addingTimeInterval(-60 * 60)), [], "already looked at")
        XCTAssertEqual(send([day(1, hangs)], after: now.addingTimeInterval(-2 * 60 * 60)), hangs)
    }

    func testTheBodyIsBucketsBuildAndMacOSOnly() throws {
        let body = FieldHangs.body([b(250, 500, 5)], version: "0.0.9", build: 202610060900, system: "26.0")
        XCTAssertEqual(Set(body.keys), ["version", "build", "os", "buckets"])
        let buckets = try XCTUnwrap(body["buckets"] as? [[String: Int]])
        XCTAssertEqual(buckets, [["from": 250, "to": 500, "count": 5]])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    /// Looked at once whatever the switch says, sent only when it is on: a
    /// day that came while it was off never goes later.
    func testSentOnlyWithAutomaticReportsAndMarkedEitherWay() {
        let name = "FieldHangsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let days = [day(1, version: Updater.version, build: nil, [b(250, 500, 2)])]
        var posted: [[String: Any]] = []
        FieldHangs.handle(days, defaults: defaults, now: now, sends: false) { posted.append($0) }
        XCTAssertTrue(posted.isEmpty)
        XCTAssertEqual(defaults.object(forKey: FieldHangs.sentKey) as? Date, days[0].end)
        FieldHangs.handle(days, defaults: defaults, now: now, sends: true) { posted.append($0) }
        XCTAssertTrue(posted.isEmpty, "the same day twice")

        let next = [day(0.5, version: Updater.version, build: nil, [b(250, 500, 1)])]
        FieldHangs.handle(next, defaults: defaults, now: now, sends: true) { posted.append($0) }
        XCTAssertEqual(posted.count, 1)
        XCTAssertNil(posted.first?["id"])
        XCTAssertEqual(defaults.object(forKey: FieldHangs.sentKey) as? Date, next[0].end)
    }

    // MARK: stacks, for crash reports only

    func testAStackKeepsFramesAndImagesOnly() throws {
        let tree: [String: Any] = [
            "callStackPerThread": true,
            "callStacks": [[
                "threadAttributed": true,
                "callStackRootFrames": [[
                    "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743", "offsetIntoBinaryTextSegment": 123,
                    "sampleCount": 20, "binaryName": "yab", "address": 74565,
                    "subFrames": [["binaryName": "AppKit", "address": 1, "path": "/Users/jane/secret"]],
                    "somethingNew": "/Users/jane/Documents",
                ]],
            ]],
        ]
        let kept = try XCTUnwrap(FieldHangs.stack(milliseconds: 1500, build: "202610060900",
                                                  tree: JSONSerialization.data(withJSONObject: tree)))
        XCTAssertEqual(kept["ms"] as? Int, 1500)
        XCTAssertEqual(kept["build"] as? String, "202610060900")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: kept), as: UTF8.self)
        XCTAssertTrue(text.contains("70B89F27-1634-3580-A695-57CDB41D7743"), "symbols need the image's id")
        XCTAssertTrue(text.contains("AppKit"))
        XCTAssertFalse(text.contains("jane"))
        XCTAssertNil(FieldHangs.stack(milliseconds: 1, build: nil, tree: Data("nope".utf8)))
    }

    func testOnlyTheNewestFewStacksWait() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { FieldHangs.forgetStacks(in: file) }
        XCTAssertTrue(FieldHangs.stacks(in: file).isEmpty)
        for n in 1...4 { FieldHangs.keep([["ms": n]], in: file) }
        FieldHangs.keep([["ms": 5], ["ms": 6], ["ms": 7]], in: file)
        XCTAssertEqual(FieldHangs.stacks(in: file).compactMap { $0["ms"] as? Int }, [3, 4, 5, 6, 7])
        FieldHangs.forgetStacks(in: file)
        XCTAssertTrue(FieldHangs.stacks(in: file).isEmpty)
    }
}
