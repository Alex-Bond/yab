import XCTest
@testable import Fast

/// A subagent's report, handed to its task as a message, read back as the
/// subagent's card; the agent's quiet answer to it; a closing line of counts.
final class ChatSubagentTests: XCTestCase {
    func testReportRoundTrips() throws {
        let text = SubagentReport.message(name: "Routines reference", id: "25d220", state: "done", model: "codex",
                                          over: 1, all: 1, answer: "- **Scheduled tasks:** [Routines](https://yetanotherbrowser.com/manual/routines) run on a schedule.\n- No monthly syntax.")
        let report = try XCTUnwrap(SubagentReport(text))
        XCTAssertEqual(report.name, "Routines reference")
        XCTAssertEqual(report.id, "25d220")
        XCTAssertEqual(report.state, "done")
        XCTAssertFalse(report.body.contains("(quiet)"), "Yab's words to the agent stay out of the card")
        XCTAssertTrue(report.body.hasSuffix("No monthly syntax."))
        XCTAssertEqual(report.gist, "Scheduled tasks: Routines run on a schedule.")
    }

    func testReportSavedBeforeTheAskReadsTheSame() throws {
        let old = "Subagent Routines reference (25d220) is done (done, codex, 1/1 completed).\n\n**No exact monthly syntax** is documented."
        let report = try XCTUnwrap(SubagentReport(old))
        XCTAssertEqual(report.body, "**No exact monthly syntax** is documented.")
        XCTAssertEqual(report.gist, "No exact monthly syntax is documented.")
    }

    func testNoReport() throws {
        let text = SubagentReport.message(name: "Subagent 2", id: "ab12", state: "stopped", model: "claude", over: 2, all: 2, answer: "  ")
        let report = try XCTUnwrap(SubagentReport(text))
        XCTAssertEqual(report.state, "stopped")
        XCTAssertEqual(report.body, "")
        XCTAssertEqual(report.gist, "Stopped without a report")
    }

    func testOnlyReportsAreCards() {
        XCTAssertNil(SubagentReport("Subagent lists are useful"))
        XCTAssertNil(ChatItem(id: "1", kind: .message, text: "Subagent X (1) is done (done, codex, 1/1 completed).", state: .done).subagentReport)
        XCTAssertNotNil(ChatItem(id: "2", kind: .asked, text: "Subagent X (1) is done (done, codex, 1/1 completed).", state: .done).subagentReport)
    }

    func testQuietAnswer() {
        XCTAssertTrue(ChatItem(id: "1", kind: .message, text: " (quiet)\n", state: .done).isQuiet)
        XCTAssertFalse(ChatItem(id: "2", kind: .message, text: "(quiet) but the date matters", state: .done).isQuiet)
    }

    func testCountsInAnyLanguageWithoutZeros() {
        XCTAssertTrue(ChatWords.counts("10 checked · 2 skipped: seriouseats.com (paywall)"))
        XCTAssertTrue(ChatWords.counts("4 pasos hechos · 0 sitios omitidos"))
        XCTAssertFalse(ChatWords.counts("4 tabs are open, and I read them all."))
        XCTAssertEqual(ChatWords.counted("4 pasos hechos · 0 sitios omitidos"), "4 pasos hechos")
        XCTAssertEqual(ChatWords.counted("10 checked · 2 skipped: seriouseats.com (paywall)"), "10 checked · 2 skipped: seriouseats.com (paywall)")
        XCTAssertEqual(ChatWords.counted("~ 0 checked · 3 skipped"), "3 skipped")
    }
}
