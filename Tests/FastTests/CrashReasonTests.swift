import XCTest
@testable import Fast

/// Why it crashed reaches the site: the uncaught exception crash.log holds
/// goes with the report it ended, cleaned (Crashes, Links.watchForTrouble).
final class CrashReasonTests: XCTestCase {
    private let home = "/Users/someone"

    /// Two exceptions as Links.watchForTrouble writes them, the first cut
    /// where `tail` began reading.
    private let log = """
    1   libobjc.A.dylib                     0x000000018cba6cd8 objc_exception_throw + 88

    2026-10-05 09:00:00 +0000: NSRangeException: *** -[__NSArrayM objectAtIndex:]: index 4 beyond bounds [0 .. 3]
    0   CoreFoundation                      0x000000018d0c2ec0 __exceptionPreprocess + 176

    2026-10-05 11:35:28 +0000: NSInvalidArgumentException: attempt to insert nil for https://bank.example/?t=1 from /Users/someone/Library/Yab
    0   CoreFoundation                      0x000000018d0c2ec0 __exceptionPreprocess + 176
    2   yab                                 0x0000000102b4c8a0 yab + 2361504


    """

    private func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testTheLogReadsAsExceptionsWithTheirTimes() {
        let thrown = Crashes.thrown(inLog: log)
        XCTAssertEqual(thrown.map(\.at), [at("2026-10-05T09:00:00Z"), at("2026-10-05T11:35:28Z")])
        XCTAssertTrue(thrown[1].text.hasPrefix("2026-10-05 11:35:28 +0000: NSInvalidArgumentException"))
        XCTAssertTrue(thrown[1].text.hasSuffix("yab + 2361504"))
        XCTAssertEqual(Crashes.thrown(inLog: ""), [])
        XCTAssertEqual(Crashes.thrown(inLog: "not a log\n\nat all"), [])
    }

    func testOnlyTheExceptionJustBeforeAReportIsItsAndItGoesCleaned() throws {
        let thrown = Crashes.thrown(inLog: log)
        let written = at("2026-10-05T11:35:31Z")
        let exception = try XCTUnwrap(Crashes.exception(before: written, after: .distantPast, in: thrown, home: home))
        XCTAssertTrue(exception.hasPrefix("2026-10-05 11:35:28 +0000: NSInvalidArgumentException: attempt to insert nil for <url> from ~/Library/Yab"))
        XCTAssertFalse(exception.contains("NSRangeException"), "two hours before is not this crash's")
        for gone in ["bank.example", "someone", "000000018d0c2ec0"] {
            XCTAssertFalse(exception.contains(gone), gone)
        }
        // Sent at an earlier launch: not again.
        XCTAssertNil(Crashes.exception(before: written, after: at("2026-10-05T11:35:29Z"), in: thrown, home: home))
        // A report with no exception before it has none.
        XCTAssertNil(Crashes.exception(before: at("2026-10-05T15:00:00Z"), after: .distantPast, in: thrown, home: home))
    }

    func testTheTailIsTheEndOfTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((String(repeating: "x", count: 1000) + "the end").utf8).write(to: file)
        XCTAssertEqual(Crashes.tail(of: file, limit: 7), "the end")
        XCTAssertEqual(Crashes.tail(of: file).count, 1007)
        XCTAssertEqual(Crashes.tail(of: file.appendingPathExtension("missing")), "")
    }

    func testAReportGoesWithTheExceptionThatEndedItsRun() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("yab-2026-10-05-113531.ips")
        let body = #"{"procName":"yab","asi":{"CoreFoundation":["*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'jane@example.com'"]}}"#
        try Data((#"{"app_name":"yab","bug_type":"309"}"# + "\n" + body).utf8).write(to: file)
        let written = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 60).rounded())
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
        let thrown = [Crashes.Thrown(at: written.addingTimeInterval(-2), text: "NSInvalidArgumentException: for https://x.example/a?b=c")]

        var posted: [Crashes.Report] = []
        let moved = await Crashes.send([(file, written)], after: written.addingTimeInterval(-3600), home: home,
                                       thrown: thrown, settle: .zero) { posted.append($0); return true }
        XCTAssertEqual(moved, written)
        let report = try XCTUnwrap(posted.first)
        XCTAssertEqual(report.exception, "NSInvalidArgumentException: for <url>")
        XCTAssertTrue(report.text.contains(#"reason: '<email>'"#))
        XCTAssertFalse(report.text.contains("jane"))
    }
}
