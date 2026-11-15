import UIKit
import XCTest
@testable import YabPhone

@MainActor
final class UpdateLoopInputsTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("loop-inputs-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFingerprintNamesOnlyChangedInputs() {
        var before = UpdateLoops.Fingerprint()
        before.chrome(PageViewport.Chrome(folded: false, hasNow: true, visible: true))
        before.size("container", CGSize(width: 402, height: 874))
        before.insets("hardware", UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
        XCTAssertTrue(before.diff(from: before).isEmpty)

        var after = before
        after.chrome(PageViewport.Chrome(folded: true, hasNow: true, visible: true, verticalControls: false))
        after.insets("hardware", UIEdgeInsets(top: 62.25, left: 0, bottom: 34, right: 0))
        let diff = after.diff(from: before)
        XCTAssertEqual(Set(diff.keys), ["chrome.folded", "chrome.verticalControls", "hardware.top"])
        XCTAssertEqual(diff["chrome.folded"] as? [Double], [0, 1])
        XCTAssertEqual(diff["chrome.verticalControls"] as? [Double], [-1, 0])
        XCTAssertEqual(diff["hardware.top"] as? [Double], [62, 62.25])
    }

    func testNonfiniteAndMissingInputsStillMakeValidJSON() throws {
        let before = UpdateLoops.Fingerprint(fields: ["width": .nan, "height": .infinity, "removed": 1])
        let after = UpdateLoops.Fingerprint(fields: ["width": .nan, "height": -.infinity, "added": 2])
        XCTAssertTrue(before.diff(from: before).isEmpty)
        let diff = after.diff(from: before)
        XCTAssertNil(diff["width"], "unchanged NaN is not a new input each iteration")
        XCTAssertEqual(diff["height"] as? [String], ["infinity", "negativeInfinity"])
        XCTAssertEqual(diff["removed"]?.last as? String, "absent")
        XCTAssertEqual(diff["added"]?.first as? String, "absent")
        let data = try JSONSerialization.data(withJSONObject: ["first": before.journal, "fields": diff])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInputsStayLazyUntilTheIterationBeforeTheThreshold() throws {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "active" })
        clock = 2
        var reads = 0
        for _ in 0 ..< UpdateLoops.threshold - 2 {
            loops.add(.pageHost) {
                reads += 1
                return UpdateLoops.Fingerprint(fields: ["folded": 0])
            }
        }
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(UpdateLoops.lines(in: file).isEmpty)
        loops.add(.pageHost) {
            reads += 1
            return UpdateLoops.Fingerprint(fields: ["folded": 0])
        }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(UpdateLoops.lines(in: file).isEmpty)
        loops.add(.pageHost) {
            reads += 1
            return UpdateLoops.Fingerprint(fields: ["folded": 1])
        }
        XCTAssertEqual(reads, 2)
        let inputs = try sampled(.pageHost, file: file)
        XCTAssertEqual(inputs["firstCount"] as? Int, UpdateLoops.threshold - 1)
        XCTAssertEqual(inputs["first"] as? [String: Double], ["folded": 0])
        let changes = try XCTUnwrap(inputs["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0]["count"] as? Int, UpdateLoops.threshold)
        let fields = try XCTUnwrap(changes[0]["fields"] as? [String: [Double]])
        XCTAssertEqual(fields, ["folded": [0, 1]])
    }

    func testChangesAreConsecutiveBoundedAndWrittenBeforeSleep() throws {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "background" })
        clock = 2
        var reads = 0
        func add(_ folded: Double) {
            loops.add(.viewport) {
                reads += 1
                return UpdateLoops.Fingerprint(fields: ["folded": folded])
            }
        }
        for _ in 0 ..< UpdateLoops.threshold { add(0) }
        add(0)
        for index in 1 ... UpdateLoops.keptChanges {
            add(Double(index % 2))
            if index < UpdateLoops.keptChanges {
                let inputs = try sampled(.viewport, file: file)
                XCTAssertTrue(try XCTUnwrap(inputs["changes"] as? [[String: Any]]).isEmpty,
                              "individual changes do not write the journal")
            }
        }
        for index in 1 ... 20 { add(Double(index % 2)) }
        XCTAssertEqual(reads, min(3 + UpdateLoops.keptChanges, UpdateLoops.keptSamples))
        var inputs = try sampled(.viewport, file: file)
        let changes = try XCTUnwrap(inputs["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, UpdateLoops.keptChanges)
        for (index, change) in changes.enumerated() {
            XCTAssertEqual(change["previousCount"] as? Int, UpdateLoops.threshold + 1 + index)
            XCTAssertEqual(change["count"] as? Int, UpdateLoops.threshold + 2 + index)
            let fields = try XCTUnwrap(change["fields"] as? [String: [Double]])
            XCTAssertEqual(fields["folded"], [Double(index % 2), Double((index + 1) % 2)])
        }
        XCTAssertEqual(UpdateLoops.lines(in: file).count, 1)
        loops.sleeps()
        inputs = try sampled(.viewport, file: file)
        XCTAssertEqual((inputs["changes"] as? [[String: Any]])?.count, UpdateLoops.keptChanges)
        XCTAssertEqual(UpdateLoops.lines(in: file).last?["endedMs"] as? Int, 2000)

        clock = 4
        for _ in 0 ..< UpdateLoops.threshold { add(1) }
        inputs = try sampled(.viewport, file: file)
        XCTAssertEqual(inputs["first"] as? [String: Double], ["folded": 1])
        XCTAssertTrue(try XCTUnwrap(inputs["changes"] as? [[String: Any]]).isEmpty, "the next stretch starts fresh")
        XCTAssertEqual(UpdateLoops.lines(in: file).count, 2)
    }

    func testEachPlaceCapturesItsOwnThresholdDespiteFasterViewportUpdates() throws {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "active" })
        clock = 2
        for _ in 0 ..< UpdateLoops.threshold * 4 { loops.add(.viewport) }
        let count = UpdateLoops.threshold + UpdateLoops.keptSamples - 2
        for index in 1 ... count {
            loops.add(.chromeHost) {
                UpdateLoops.Fingerprint(fields: ["folded": index >= UpdateLoops.threshold ? 1 : 0])
            }
        }
        let inputs = try sampled(.chromeHost, file: file)
        XCTAssertEqual((inputs["changes"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(UpdateLoops.lines(in: file).count, 1)
        XCTAssertEqual(UpdateLoops.lines(in: file).last?["counts"] as? [String: Int],
                       ["viewport": UpdateLoops.threshold * 4, "chromeHost": count])
    }

    func testIdenticalInputsStopSamplingAndStartFreshAfterSleep() throws {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "active" })
        clock = 2
        var reads = 0
        func add() {
            loops.add(.pageHost) {
                reads += 1
                return UpdateLoops.Fingerprint(fields: ["folded": 0, "width": .nan])
            }
        }
        for _ in 0 ..< UpdateLoops.threshold * 64 { add() }
        XCTAssertEqual(reads, UpdateLoops.keptSamples)
        let inputs = try sampled(.pageHost, file: file)
        XCTAssertEqual(inputs["sampledThrough"] as? Int, UpdateLoops.threshold + UpdateLoops.keptSamples - 2)
        XCTAssertTrue(try XCTUnwrap(inputs["changes"] as? [[String: Any]]).isEmpty)
        loops.sleeps()
        clock = 4
        for _ in 0 ..< UpdateLoops.threshold * 2 { add() }
        XCTAssertEqual(reads, UpdateLoops.keptSamples * 2)
        XCTAssertEqual(UpdateLoops.lines(in: file).count, 2)
    }

    func testEmptyInputsAlsoUseTheSampleBudgetForEachPlace() throws {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "active" })
        clock = 2
        var reads: [UpdateLoops.Place: Int] = [:]
        for place in UpdateLoops.Place.allCases {
            for _ in 0 ..< UpdateLoops.threshold * 8 {
                loops.add(place) {
                    reads[place, default: 0] += 1
                    return UpdateLoops.Fingerprint()
                }
            }
        }
        for place in UpdateLoops.Place.allCases {
            XCTAssertEqual(reads[place], UpdateLoops.keptSamples)
        }
        let line = try XCTUnwrap(UpdateLoops.lines(in: file).last)
        XCTAssertTrue(try XCTUnwrap(line["inputs"] as? [String: Any]).isEmpty)
    }

    func testTheSampleBudgetEndsBeforeFourWidelySpacedChanges() throws {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "active" })
        clock = 2
        var reads = 0
        for index in 1 ... UpdateLoops.threshold * 8 {
            loops.add(.root) {
                reads += 1
                return UpdateLoops.Fingerprint(fields: ["folded": index < UpdateLoops.threshold + 2 ? 0 : 1])
            }
        }
        XCTAssertEqual(reads, UpdateLoops.keptSamples)
        let inputs = try sampled(.root, file: file)
        let changes = try XCTUnwrap(inputs["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0]["count"] as? Int, UpdateLoops.threshold + 2)
        XCTAssertEqual(inputs["sampledThrough"] as? Int, UpdateLoops.threshold + UpdateLoops.keptSamples - 2)
    }

    func testForgettingWaitsForQueuedWrites() {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "active" })
        clock = 2
        for _ in 0 ..< UpdateLoops.threshold { loops.add(.root) }
        loops.sleeps()
        UpdateLoops.forget(in: file)
        XCTAssertTrue(UpdateLoops.lines(in: file).isEmpty)
    }

    func testDisabledReportsDoNotReadInputs() {
        let previous = UpdateLoops.shared
        UpdateLoops.shared = nil
        defer { UpdateLoops.shared = previous }
        var reads = 0
        for _ in 0 ..< UpdateLoops.threshold * 2 {
            UpdateLoops.count(.plusMenu) {
                reads += 1
                return UpdateLoops.Fingerprint(fields: ["folded": 0])
            }
        }
        XCTAssertEqual(reads, 0)
    }

    private func sampled(_ place: UpdateLoops.Place, file: URL) throws -> [String: Any] {
        let line = try XCTUnwrap(UpdateLoops.lines(in: file).last)
        let inputs = try XCTUnwrap(line["inputs"] as? [String: Any])
        return try XCTUnwrap(inputs[place.name] as? [String: Any])
    }
}
