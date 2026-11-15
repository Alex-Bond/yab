import Foundation
import XCTest
@testable import YabPhone

@MainActor
final class DiagnosticLedgerTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owned-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func haptics(_ journal: Haptics.Journal) -> [String] {
        journal.entries.map { "\($0.kind.rawValue) \($0.reason)" }
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            String($0.split(separator: " ", maxSplits: 1)[1])
        }
    }

    func testTenThousandOrdinaryInteractionsRetainNoHapticOrMotionHistory() {
        let haptic = Haptics.Journal(environment: [:], testing: false)
        let motion = TaskMotion.Journal(environment: [:], testing: false)
        let kinds = Haptics.Kind.allCases, motions: [Motion] = [.sheetGrow, .sheetBack, .nowWords]
        for i in 0..<10_000 {
            haptic.append(kinds[i % kinds.count], "ordinary-\(i)")
            motion.append(motions[i % motions.count])
        }
        XCTAssertNil(haptic.url)
        XCTAssertNil(motion.url)
        XCTAssertFalse(haptic.silent, "The recording gate does not silence physical haptics")
        XCTAssertTrue(haptic.entries.isEmpty)
        XCTAssertTrue(motion.entries.isEmpty)
        // An empty opt-in path and silent generators are still not test recording.
        let quiet = Haptics.Journal(environment: ["YAB_HAPTICS_SILENT": "1", "YAB_HAPTICS_JOURNAL": ""], testing: false)
        let unnamed = TaskMotion.Journal(environment: ["YAB_MOTION_JOURNAL": ""], testing: false)
        for _ in 0..<10_000 { quiet.append(.selection, "quiet"); unnamed.append(.sheetGrow) }
        XCTAssertTrue(quiet.silent && quiet.entries.isEmpty && unnamed.entries.isEmpty)
    }

    func testTestModeRetainsTheFullTenThousandEventOrderWithoutTruncation() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("haptics.log")
        let haptic = Haptics.Journal(environment: ["YAB_HAPTICS_JOURNAL": file.path], testing: true)
        let motion = TaskMotion.Journal(environment: [:], testing: true)
        let kinds = Haptics.Kind.allCases, motions: [Motion] = [.sheetGrow, .sheetBack, .nowWords]
        var expectedHaptics: [String] = [], expectedMotions: [String] = []
        for i in 0..<10_000 {
            let kind = kinds[i % kinds.count], reason = "test-\(i)", animation = motions[i % motions.count]
            expectedHaptics.append("\(kind.rawValue) \(reason)")
            expectedMotions.append("\(animation.name)")
            haptic.append(kind, reason)
            motion.append(animation)
        }
        XCTAssertNil(motion.url, "Test mode alone retains the motion history without requiring a file")
        XCTAssertEqual(haptics(haptic), expectedHaptics)
        XCTAssertEqual(motion.entries, expectedMotions)
        XCTAssertEqual(try lines(file), expectedHaptics)
    }

    func testExplicitJournalsRetainCompleteOrderOutsideTestMode() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let hapticFile = folder.appendingPathComponent("haptics.log"), motionFile = folder.appendingPathComponent("motions.log")
        let haptic = Haptics.Journal(environment: ["YAB_HAPTICS_JOURNAL": hapticFile.path], testing: false)
        let motion = TaskMotion.Journal(environment: ["YAB_MOTION_JOURNAL": motionFile.path], testing: false)
        var expectedHaptics: [String] = [], expectedMotions: [String] = []
        for i in 0..<256 {
            let kind = Haptics.Kind.allCases[i % Haptics.Kind.allCases.count], reason = "explicit-\(i)"
            let animation: Motion = i.isMultiple(of: 2) ? .sheetGrow : .sheetBack
            expectedHaptics.append("\(kind.rawValue) \(reason)"); expectedMotions.append("\(animation.name)")
            haptic.append(kind, reason); motion.append(animation)
        }
        XCTAssertEqual(haptics(haptic), expectedHaptics)
        XCTAssertEqual(motion.entries, expectedMotions)
        XCTAssertEqual(try lines(hapticFile), expectedHaptics)
        XCTAssertEqual(try lines(motionFile), expectedMotions)
    }

    func testTaskMotionStillRunsItsBodyAndCompletionAndPreservesPriorSharedHistory() {
        let previous = Motion.disabled
        Motion.disabled = true; defer { Motion.disabled = previous }
        let before = TaskMotion.played, hapticBefore = haptics(Haptics.Journal.shared)
        var actions: [String] = []
        TaskMotion.run(.sheetGrow, { actions.append("body") }) { actions.append("completion") }
        XCTAssertEqual(actions, ["body", "completion"])
        XCTAssertEqual(Array(TaskMotion.played.prefix(before.count)), before)
        XCTAssertEqual(TaskMotion.played.count, before.count + 1)
        XCTAssertEqual(TaskMotion.played.last, "sheetGrow")
        XCTAssertEqual(haptics(Haptics.Journal.shared), hapticBefore)
    }
}
