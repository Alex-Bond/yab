import XCTest
@testable import YabPhone

/// The QR code scanner from New Tab's field: what a code's payload becomes
/// (a web address opens in a new tab, anything else is words for the field),
/// the camera closing before the field acts, and where the glyph shows.
@MainActor
final class CodeScannerTests: XCTestCase {
    private var app: AppModel!

    override func setUp() async throws {
        Motion.disabled = true
        app = AppModel(world: try World.load(named: "mira"))
        app.surfaces.toastsStay = true
    }

    func testAWebAddressOpensAndAnythingElseIsWords() {
        XCTAssertEqual(CodeScanner.route("https://lumen.events/e/design-systems-night"),
                       .open(URL(string: "https://lumen.events/e/design-systems-night")!))
        XCTAssertEqual(CodeScanner.route("  HTTP://EXAMPLE.COM/menu \n"), .open(URL(string: "HTTP://EXAMPLE.COM/menu")!))
        XCTAssertEqual(CodeScanner.route("example.com/menu"), .open(URL(string: "https://example.com/menu")!), "a bare address, as typed")
        XCTAssertEqual(CodeScanner.route("gift ideas for jonas"), .words("gift ideas for jonas"))
        XCTAssertEqual(CodeScanner.route("Table 12\nOrder at the bar"), .words("Table 12 Order at the bar"), "one line for the field")
        XCTAssertEqual(CodeScanner.route("WIFI:S:Casa;T:WPA;P:secret;;"), .words("WIFI:S:Casa;T:WPA;P:secret;;"))
        XCTAssertEqual(CodeScanner.route("mailto:ines@example.com"), .words("mailto:ines@example.com"))
        XCTAssertEqual(CodeScanner.route("javascript:alert(1)"), .words("javascript:alert(1)"), "a code never runs a script")
        XCTAssertEqual(CodeScanner.route("data:text/html,<b>hi</b>"), .words("data:text/html,<b>hi</b>"))
        XCTAssertEqual(CodeScanner.route("ftp://files.example.com"), .words("ftp://files.example.com"))
        XCTAssertEqual(CodeScanner.route(" \n "), .nothing)
        if case let .words(long) = CodeScanner.route(String(repeating: "a", count: 900)) { XCTAssertEqual(long.count, 500) }
        else { XCTFail("long text is words") }
    }

    func testAScannedAddressOpensANewTabOnceTheCameraHasGone() async throws {
        app.scanner.useStandIn("https://example.com/menu", waits: true)
        app.surfaces.openField(.newTab)
        let tabs = app.browser.allTabs.count
        app.scanner.open()
        XCTAssertTrue(app.scanner.shown)
        XCTAssertEqual(Haptics.played.last?.reason, Haptics.Reason.scan)
        app.scanner.found("https://example.com/menu")
        XCTAssertFalse(app.scanner.shown)
        XCTAssertEqual(Haptics.played.last.map { "\($0.kind) \($0.reason)" }, "success scanned")
        XCTAssertEqual(app.browser.allTabs.count, tabs, "nothing before the cover has gone")
        app.scanner.closed()
        XCTAssertEqual(app.browser.allTabs.count, tabs + 1)
        XCTAssertEqual(app.browser.tab?.addressHost, "example.com")
        XCTAssertNil(app.surfaces.field)
    }

    func testAScannedAddressAlreadyOpenIsThatTab() async throws {
        app.scanner.useStandIn("https://lumen.events/e/design-systems-night", waits: true)
        app.surfaces.openField(.newTab)
        let tabs = app.browser.allTabs.count
        app.scanner.open()
        app.scanner.found("https://lumen.events/e/design-systems-night")
        app.scanner.closed()
        XCTAssertEqual(app.browser.tab?.page, "lumen", "as Paste and Go: the open tab, not a second one")
        XCTAssertEqual(app.browser.allTabs.count, tabs)
    }

    func testOtherTextGoesIntoTheField() async throws {
        app.scanner.useStandIn("gift ideas for jonas", waits: true)
        app.surfaces.openField(.newTab)
        let tabs = app.browser.allTabs.count
        app.scanner.open()
        app.scanner.found("gift ideas for jonas")
        app.scanner.closed()
        XCTAssertEqual(app.field.text, "gift ideas for jonas")
        XCTAssertEqual(app.surfaces.field, .newTab, "the person decides what the words do")
        XCTAssertEqual(app.browser.allTabs.count, tabs)
    }

    func testClosingTheCameraGivesTheKeyboardBack() async throws {
        app.scanner.useStandIn("https://example.com", waits: true)
        app.surfaces.openField(.newTab)
        app.field.typed("")
        app.scanner.open()
        let asked = app.field.focusRequest
        app.scanner.close()
        app.scanner.closed()
        XCTAssertFalse(app.scanner.shown)
        XCTAssertEqual(app.field.focusRequest, asked + 1)
        XCTAssertEqual(app.field.text, "")
    }

    func testOfferedOnlyWhereThisIPhoneCanScan() {
        XCTAssertFalse(app.scanner.canScan, "the simulator has no camera to scan with")
        app.surfaces.openField(.newTab)
        app.scanner.open()
        XCTAssertFalse(app.scanner.shown, "nothing to open")
        app.scanner.useStandIn("https://example.com")
        XCTAssertTrue(app.scanner.canScan)
    }

    func testTheRightButtonsScanOpensNewTabUnderTheCamera() {
        app.scanner.useStandIn("https://example.com/menu", waits: true)
        app.openScanner()
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertTrue(app.scanner.shown)
        app.scanner.found("https://example.com/menu")
        app.scanner.closed()
        XCTAssertEqual(app.browser.tab?.addressHost, "example.com")
    }

    func testAScanFromPrivateOpensAPrivateTab() {
        app.scanner.useStandIn("https://example.com/menu", waits: true)
        app.field.openNewTab(privately: true)
        XCTAssertTrue(app.field.isPrivate)
        app.scanner.open()
        app.scanner.found("https://example.com/menu")
        app.scanner.closed()
        XCTAssertEqual(app.browser.tab?.addressHost, "example.com")
        XCTAssertEqual(app.browser.tab?.isPrivate, true, "the eyes were shut")
    }
}
