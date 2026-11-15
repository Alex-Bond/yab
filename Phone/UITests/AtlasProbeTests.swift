import XCTest

/// The test build's probes do what the tools read from them: the catalog
/// lists the states, the frames the app writes are the ones XCTest sees,
/// FrameMeter measures a signposted motion, the haptics journal says what
/// played.
final class AtlasProbeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheCatalogListsTheRegisteredStates() {
        let states = Atlas.states(XCUIApplication())
        let names = states.map(\.name)
        XCTAssertTrue(names.contains("page.1"), "catalog: \(names)")
        XCTAssertTrue(names.contains("page.2"), "catalog: \(names)")
        XCTAssertEqual(Set(names).count, names.count, "a state is registered twice: \(names)")
        XCTAssertFalse(states.contains { $0.title.isEmpty }, "every state has its prototype title")
    }

    /// A misspelled state is not the world's start pictured and passed.
    func testAnUnknownStateIsNotSettled() {
        let outcome = Atlas.open(XCUIApplication(), state: "page.99", ready: Atlas.readyFolder(), takes: 1)
        XCTAssertEqual(outcome, .unknown, outcome.words)
    }

    func testTheAppsFramesAreTheOnesXCTestSees() throws {
        let app = XCUIApplication()
        let ready = Atlas.readyFolder()
        XCTAssertTrue(Atlas.launch(app, state: "page.1", ready: ready), "page.1 never settled")
        let data = try Data(contentsOf: ready.appendingPathComponent("page.1.frames.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let elements = try XCTUnwrap(json["elements"] as? [[String: Any]])
        let byId = Dictionary(elements.compactMap { e in (e["id"] as? String).map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        for id in ["chrome.plate", "chrome.back", "chrome.plus"] {
            let mine = try XCTUnwrap(byId[id], "\(id) isn't in the app's frames: \(byId.keys.sorted())")
            let theirs = app.descendants(matching: .any)[id].frame
            func n(_ k: String) -> CGFloat { CGFloat((mine[k] as? NSNumber)?.doubleValue ?? -1) }
            XCTAssertEqual(n("x"), theirs.minX, accuracy: 0.5, id)
            XCTAssertEqual(n("y"), theirs.minY, accuracy: 0.5, id)
            XCTAssertEqual(n("w"), theirs.width, accuracy: 0.5, id)
            XCTAssertEqual(n("h"), theirs.height, accuracy: 0.5, id)
        }
        // The plate at Safari's sizes (65619b17): 81 from the left, 240 × 48.
        let plate = try XCTUnwrap(byId["chrome.plate"])
        XCTAssertEqual((plate["x"] as? NSNumber)?.doubleValue ?? 0, 81, accuracy: 0.5)
        XCTAssertEqual((plate["w"] as? NSNumber)?.doubleValue ?? 0, 240, accuracy: 0.5)
    }

    func testFrameMeterMeasuresASignpostedMotion() throws {
        let app = XCUIApplication()
        let ready = Atlas.readyFolder()
        let file = Atlas.out.appendingPathComponent("probe/frames-\(UUID().uuidString.prefix(6)).jsonl")
        try? FileManager.default.removeItem(at: file)
        // page.2 is folded; the page pulled down unfolds the chrome on screen.
        // (A tap on the folded plate unfolds it under the field that grows
        // over the chrome, so that fold ends early with nothing drawn.)
        XCTAssertTrue(Atlas.launch(app, state: "page.2", ready: ready, still: false,
                                   environment: ["YAB_FRAMEMETER": "1", "YAB_PERF_OUT": file.path]))
        let plate = app.descendants(matching: .any)["chrome.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        app.webViews.firstMatch.swipeDown(velocity: .slow)
        XCTAssertTrue(TransitionCatalog.wait(5) { abs(plate.frame.height - 48) < 1 }, "the chrome never unfolded: \(plate.frame)")
        XCTAssertTrue(Atlas.waitForFile(file, timeout: 5), "FrameMeter wrote nothing")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let rows = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let fold = try XCTUnwrap(rows.first { $0["name"] as? String == "chromeFold" }, "no chromeFold line: \(lines)")
        let frames = (fold["frames"] as? NSNumber)?.intValue ?? 0
        let duration = (fold["duration_ms"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertGreaterThan(frames, 3, "a 0.42 s motion over \(frames) frames")
        XCTAssertGreaterThan(duration, 150, "chromeFold took \(duration) ms")
        XCTAssertLessThan(duration, 3000, "chromeFold took \(duration) ms")
        XCTAssertGreaterThan((fold["begin"] as? NSNumber)?.doubleValue ?? 0, 1_700_000_000, "begin is the wall clock")
    }

    func testTheHapticsJournalSaysWhatPlayed() throws {
        let app = XCUIApplication()
        let ready = Atlas.readyFolder()
        let journal = Atlas.hapticsJournal()
        XCTAssertTrue(Atlas.launch(app, state: "page.1", ready: ready, still: false,
                                   environment: ["YAB_HAPTICS_JOURNAL": journal.path, "YAB_HAPTICS_SILENT": "1"]))
        SpacesGesture.open(in: app)
        // Table row 4: the spaces (the column's place) opened, impact light.
        XCTAssertTrue(TransitionCatalog.wait(5) { Atlas.haptics(journal).contains("light column") },
                      "journal: \(Atlas.haptics(journal))")
    }
}
