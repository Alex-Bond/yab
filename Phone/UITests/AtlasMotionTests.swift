import XCTest

/// The prototype's haptics table ("Haptics", 16 rows,
/// Phone/Reference/digest/motion.md) by the reasons the app writes in its
/// journal (Design/Haptics.swift): what each moment must play. A scenario's
/// journal is checked two ways: every line plays its reason's kind, and the
/// lines are the ones the scenario expects, in order.
///
///     let journal = Atlas.hapticsJournal()   // launch with YAB_HAPTICS_JOURNAL
///     ...the finger...
///     HapticsTable.assert(Atlas.haptics(journal), ["light column"])
///
/// A reason the table doesn't know is a mismatch too: add its row here when
/// the prototype's table has it, with the row's number.
enum HapticsTable {
    static let kinds: [String: String] = [
        "eyes": "soft", "eyes close": "soft", "eyes open": "soft",                    // 1
        "tab": "selection",                                                           // 2
        "space": "selection",                                                         // 3
        "column": "light",                                                            // 4
        "menu": "medium",                                                             // 5, 7, 11
        "clear": "rigid",                                                             // 6
        "hold": "medium", "lift": "light", "drop": "light",                           // 7
        "row": "light", "close": "light", "keep": "light", "unkeep": "light", "moved": "light", // 8
        "threshold": "selection", "swipe through": "selection",                       // 9
        "chat": "light", "pin": "light", "unread": "light", "archive": "light",       // 10
        "confirm": "light", "let go": "light", "send": "light",                       // 12
        "needs you": "warning",                                                       // 13
        "done": "success", "paid": "success",                                         // 14
        "failed": "error",                                                            // 15
    ]

    /// Journal lines ("light column") whose kind isn't the table's for their reason.
    static func mismatches(_ played: [String]) -> [String] {
        played.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "\(line): not a journal line" }
            guard let kind = kinds[parts[1]] else { return "\(line): \(parts[1]) isn't in the prototype's table" }
            return kind == parts[0] ? nil : "\(line): the table plays \(kind) for \(parts[1])"
        }
    }

    /// The journal against the table and against what the scenario expects.
    static func assert(_ played: [String], _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mismatches(played), [], "haptics against the prototype's table", file: file, line: line)
        XCTAssertEqual(played, expected, "the scenario's haptics", file: file, line: line)
    }
}

/// The transition table's rule for durations (PLAN-iphone.md 5.3): a
/// motion's signpost within 20 % of its Motion's duration, never less than
/// three frames at 60 Hz, since the end is said by the animation's
/// completion a frame or two after it arrives. Phone/scripts/lib/perf.py
/// judges perf runs by the same rule.
enum MotionTable {
    static func tolerance(_ expectedMs: Double) -> Double { max(expectedMs * 0.2, 50) }
}

/// Section 7 of PLAN-iphone.md on the skeleton's own movements: each runs
/// as long as the Motion says (5.3, within 20 %), Reduce Motion plays a short
/// cross-fade under its own signpost instead of the morph, and a scenario's
/// haptics journal matches the prototype's table. Feature branches check
/// their scenarios the same way (HapticsTable.assert, the frames lines).
final class AtlasMotionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The plate unfolding from page.2 as the page is pulled down, measured
    /// by FrameMeter: its line. (A tap on the folded plate unfolds it under
    /// the field growing over the chrome, which ends that fold early.)
    private func unfold(arguments: [String]) throws -> [String: Any] {
        let app = XCUIApplication()
        let ready = Atlas.readyFolder()
        let file = Atlas.out.appendingPathComponent("probe/motion-\(UUID().uuidString.prefix(6)).jsonl")
        XCTAssertTrue(Atlas.launch(app, state: "page.2", ready: ready, still: false, extra: arguments,
                                   environment: ["YAB_FRAMEMETER": "1", "YAB_PERF_OUT": file.path]), "page.2 never settled")
        let plate = app.descendants(matching: .any)["chrome.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        app.webViews.firstMatch.swipeDown(velocity: .slow)
        XCTAssertTrue(TransitionCatalog.wait(5) { abs(plate.frame.height - 48) < 1 }, "the chrome never unfolded: \(plate.frame)")
        XCTAssertTrue(TransitionCatalog.wait(5) { FileManager.default.fileExists(atPath: file.path) }, "FrameMeter wrote nothing")
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        app.terminate()
        return try XCTUnwrap(rows.first { $0["name"] as? String == "chromeFold" }, "no chromeFold line: \(rows)")
    }

    private func number(_ row: [String: Any], _ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? -1 }

    func testAMotionLastsWhatItsMotionSays() throws {
        let row = try unfold(arguments: [])
        XCTAssertEqual(row["signpost"] as? String, "chromeFold")
        XCTAssertEqual(row["fade"] as? Bool, false)
        let expected = number(row, "expected_ms"), duration = number(row, "duration_ms")
        XCTAssertEqual(expected, 300, accuracy: 0.5, "Motion.chromeFold is 0.3 s, Safari's fold")
        XCTAssertEqual(duration, expected, accuracy: MotionTable.tolerance(expected), "the signpost's interval against the table")
        XCTAssertGreaterThan(number(row, "first_ms"), 0, "the first frame is measured")
    }

    func testReduceMotionFadesUnderItsOwnSignpost() throws {
        let row = try unfold(arguments: ["-YabReduceMotion", "YES"])
        XCTAssertEqual(row["signpost"] as? String, "fade", "a cross-fade, not the morph")
        XCTAssertEqual(row["fade"] as? Bool, true)
        let expected = number(row, "expected_ms"), duration = number(row, "duration_ms")
        XCTAssertEqual(expected, 200, accuracy: 0.5, "Reduce Motion's fade is 0.2 s")
        XCTAssertEqual(duration, expected, accuracy: MotionTable.tolerance(expected), "the fade's interval")
    }

    /// Scrolling folds and unfolds the chrome quietly (row 16: the frequent
    /// stays quiet); a swipe up on the plate brings the spaces, the column's
    /// place since aaf8443d, light (row 4).
    func testTheJournalMatchesThePrototypesTable() throws {
        // The quiet path: a long page scrolled down and back up.
        let app = XCUIApplication()
        let quiet = Atlas.hapticsJournal()
        app.launchArguments = ["-YabWorld", Atlas.world, "-YabTab", "work-launch-notes"]
        app.launchEnvironment = ["YAB_HAPTICS_JOURNAL": quiet.path, "YAB_HAPTICS_SILENT": "1"]
        app.launch()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Tern 2.0 launch notes"].waitForExistence(timeout: 60), "the page never drew")
        let plate = app.descendants(matching: .any)["chrome.plate"]
        page.swipeUp(velocity: .slow)
        XCTAssertTrue(TransitionCatalog.wait(5) { abs(plate.frame.height - 44) < 1 }, "the chrome never folded")
        page.swipeDown(velocity: .slow)
        XCTAssertTrue(TransitionCatalog.wait(5) { abs(plate.frame.height - 48) < 1 }, "the chrome never unfolded")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        HapticsTable.assert(Atlas.haptics(quiet), [])

        // The plate regains its upward-swipe path after folding and unfolding.
        SpacesGesture.open(in: app)
        let spaces = app.descendants(matching: .any)["newtab.spaces"]
        XCTAssertTrue(TransitionCatalog.wait(5) { spaces.exists },
                      "the upward swipe didn't bring the spaces after folding and unfolding")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        HapticsTable.assert(Atlas.haptics(quiet), ["light column"])
        app.terminate()

        // The spaces from a fresh start: light, once.
        let ready = Atlas.readyFolder()
        let journal = Atlas.hapticsJournal()
        XCTAssertTrue(Atlas.launch(app, state: "page.1", ready: ready, still: false,
                                   environment: ["YAB_HAPTICS_JOURNAL": journal.path, "YAB_HAPTICS_SILENT": "1"]))
        SpacesGesture.open(in: app)
        XCTAssertTrue(TransitionCatalog.wait(5) { !Atlas.haptics(journal).isEmpty }, "nothing played")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        HapticsTable.assert(Atlas.haptics(journal), ["light column"])
    }

    /// The checker itself: a wrong kind, an unknown reason, a missing line.
    func testTheTableCatchesAWrongKind() {
        XCTAssertEqual(HapticsTable.mismatches(["light column", "selection space", "rigid clear"]), [])
        XCTAssertEqual(HapticsTable.mismatches(["medium column"]), ["medium column: the table plays light for column"])
        XCTAssertEqual(HapticsTable.mismatches(["success joined"]), ["success joined: joined isn't in the prototype's table"])
    }
}
