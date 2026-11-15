import XCTest
@testable import YabPhone

/// The crashes of 0.1.33 to 0.1.37: iOS ended Yab as its scene connected
/// (New Tab's content made again for each thing that read it, every tab of
/// every space scanned per row), as it went to the background (the profile
/// filtered and compared whole on the main thread, #1482), and while it read
/// MetricKit's payload (SIGBUS, #1537).
@MainActor
final class LaunchHangTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchHang-\(UUID())", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A person's profile: 2,000 tabs, one in front on the Mac, a visit on each of 100.
    private func liveApp() -> AppModel {
        let profile = BrowserProfile(folder: folder)
        var tabs = (0..<2_000).map { i in
            PageFixtures.liveTab(for: URL(string: "https://example.com/\(i)")!, id: "saved-\(i)")
        }
        tabs[1_500].onMac = true
        let space = Space(id: "saved", name: "Saved", emoji: "", tint: RGB(238, 233, 226), today: tabs, current: tabs[0].id)
        let world = World(name: "profile", space: space.id, spaces: [space], mac: World.Mac(joined: false))
        let app = AppModel(world: world, fixturesEnabled: false, profile: profile)
        for tab in tabs.prefix(100) { profile.recordVisit(tab) }
        return app
    }

    func testNewTabsContentIsMadeOncePerChangeOfWhatItShows() throws {
        let app = liveApp()
        app.surfaces.openField(.newTab)
        let before = NewTabContent.builds
        // What one draw of the field asks, many draws over.
        for _ in 0..<50 {
            let content = NewTabContent.make(for: app)
            _ = app.fieldRows(content: content)
            _ = content.sheetRows
        }
        XCTAssertEqual(NewTabContent.builds - before, 1, "made once while nothing it shows changed")

        let first = NewTabContent.make(for: app)
        app.browser.select("saved-7")
        let moved = NewTabContent.make(for: app)
        XCTAssertEqual(NewTabContent.builds - before, 2, "made again once the tab in front changed")
        XCTAssertEqual(first.sheetRows.map(\.id), moved.sheetRows.map(\.id), "the sheet's rows don't shift under a finger")

        let page = PageFixtures.liveTab(for: URL(string: "https://news.example.org/today")!, id: "visited")
        app.profile?.recordVisit(page)
        let visited = NewTabContent.make(for: app)
        XCTAssertEqual(NewTabContent.builds - before, 3, "a new visit makes it again")
        XCTAssertEqual(visited.recent.first?.title, page.title)
    }

    func testTheTabOnTheMacAndOpenTabsAreLookedUpNotScanned() {
        let app = liveApp()
        XCTAssertEqual(app.browser.onMac?.id, "saved-1500")
        XCTAssertEqual(app.browser.openTab(at: "https://example.com/42")?.id, "saved-42")
        XCTAssertNil(app.browser.openTab(at: "https://example.com/none"))
        let revision = app.browser.revision
        app.browser.close("saved-42")
        XCTAssertNotEqual(app.browser.revision, revision)
        XCTAssertNil(app.browser.openTab(at: "https://example.com/42"), "a closed tab is gone from the lookup")

        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<10_000 { _ = app.browser.openTab(at: "https://example.com/\(i % 2_000)") }
        _ = app.browser.onMac
        let took = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(took, 0.1, "10,000 lookups took \(Int(took * 1000)) ms")
    }

    func testGoingToTheBackgroundCapturesWithoutWorkOnTheMainThread() async throws {
        let app = liveApp()
        let profile = try XCTUnwrap(app.profile)
        profile.capture(app.browser)
        // Pages call it on every navigation, and Yab as it leaves: with
        // nothing changed it is one comparison of two numbers.
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10_000 { profile.capture(app.browser) }
        let took = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(took, 0.05, "10,000 captures of an unchanged browser took \(Int(took * 1000)) ms")

        app.browser.select("saved-9")
        profile.capture(app.browser)
        XCTAssertEqual(profile.snapshot.spaces.first?.current, "saved-9", "a change still reaches the snapshot")
        await app.flushProfile()
        let saved = try JSONDecoder().decode(BrowserProfile.Snapshot.self,
                                             from: Data(contentsOf: folder.appendingPathComponent("profile.json")))
        XCTAssertEqual(saved.spaces.first?.current, "saved-9")
        XCTAssertEqual(saved.spaces.first?.today.count, 2_000)
    }

    func testAPrivateTabIsStillFilteredByTheWriter() async throws {
        let app = liveApp()
        let profile = try XCTUnwrap(app.profile)
        let secret = PageFixtures.liveTab(for: URL(string: "https://secret.example.com/")!, id: "secret", isPrivate: true)
        app.browser.open(secret, in: "saved", deduplicate: false)
        profile.capture(app.browser)
        await app.flushProfile()
        let text = try String(contentsOf: folder.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("secret.example.com"))
    }

    // MARK: - MetricKit's payload

    private func samplePayload() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("MetricKitPayload.json"))
    }

    func testATruncatedOrEmptyPayloadIsNoReport() throws {
        let whole = try samplePayload()
        XCTAssertFalse(DiagnosticReports.crashes(inPayload: whole, bundle: "dev.serafim.fast.iphone").isEmpty)
        for cut in [0, 1, whole.count / 3, whole.count / 2, whole.count - 2] {
            let part = whole.prefix(cut)
            XCTAssertTrue(DiagnosticReports.crashes(inPayload: part, bundle: "dev.serafim.fast.iphone").isEmpty, "cut at \(cut)")
            XCTAssertTrue(DiagnosticReports.hangs(inPayload: part, bundle: "dev.serafim.fast.iphone").reports.isEmpty, "cut at \(cut)")
        }
        XCTAssertNil(DiagnosticReports.payload(Data("[1, 2, 3]".utf8)), "an array is no payload")
        XCTAssertNil(DiagnosticReports.payload(Data(repeating: 0xFF, count: 4096)), "bytes that aren't JSON")
        XCTAssertTrue(DiagnosticReports.crashes(inPayload: Data(#"{"crashDiagnostics": [{"x": 1}, 7, "y"]}"#.utf8), bundle: "x").isEmpty)
    }

    func testThePayloadIsReadFromACopyOfItsOwn() throws {
        var bytes = try samplePayload()
        let payload = try XCTUnwrap(DiagnosticReports.payload(bytes))
        // The bytes handed over change after parsing, as a file MetricKit
        // replaces would: what was parsed reads the same.
        let before = DiagnosticReports.crashes(in: payload, bundle: "dev.serafim.fast.iphone").map(\.key)
        bytes.resetBytes(in: 0..<bytes.count)
        XCTAssertEqual(DiagnosticReports.crashes(in: payload, bundle: "dev.serafim.fast.iphone").map(\.key), before)
        XCTAssertFalse(before.isEmpty)
    }

    func testAValueJSONCantHoldIsNoException() {
        XCTAssertEqual(DiagnosticReports.json(["n": Double.nan]), "{}")
        XCTAssertEqual(DiagnosticReports.json(["date": Date()]), "{}")
        XCTAssertEqual(DiagnosticReports.json(["a": 1]), #"{"a":1}"#)
    }
}
