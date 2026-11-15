import XCTest

/// All Tabs right after a launch shows real pages, not
/// icons on blank cards: the pictures kept as the tabs were left come back
/// from the disk (with the warm-up off, so they can come only from there),
/// and cards never pictured load out of sight and cross-fade from their
/// icons. In test runs each card's value ends in "picture" or "icon"
/// (TabGalleryLayer); the pictures go to a folder this test names
/// (YAB_TAB_PICTURES), which the app and the test both see in the
/// simulator's /tmp.
final class TabPicturesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var folder: URL!

    override func setUp() {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-tab-pictures-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: folder)
    }

    private func launch(_ state: String, warmUp: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabNoAnim", "YES"]
            + (warmUp ? [] : ["-YabTabWarmup", "NO"])
        app.launchEnvironment["YAB_TAB_PICTURES"] = folder.path
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
    }

    private let cards = ["work-linear-method", "work-lumen", "work-tern-local", "work-gh-pr", "work-hn", "work-figma-onb"]

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    /// A card's value: "current" or its site, then "picture" or "icon".
    private func shows(_ id: String) -> String {
        let card = element("tabs.card.\(id)")
        guard card.exists else { return "no card" }
        return (card.value as? String).flatMap { $0.components(separatedBy: ", ").last } ?? "no value"
    }
    private var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jpg") }
    }

    private func wait(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAllTabsRightAfterARelaunchShowsThePicturesKeptOnDisk() {
        // A person's use: Linear, Lumen, HN and GitHub in front once each,
        // then Figma; each pictured as it was left.
        launch("stack.many", warmUp: false)
        let stack = app.buttons["chrome.plus"]
        XCTAssertTrue(stack.waitForExistence(timeout: 60), "no right button")
        XCTAssertTrue(wait(60) { stack.label.hasPrefix("Previous tab, feat(editor)") }, "the state didn't land: \(stack.label)")
        XCTAssertTrue(wait(30) { self.files.count >= 5 }, "the pictures weren't kept: \(files.count) files")
        app.terminate()

        // The next launch, All Tabs at once: nothing was in front in this run.
        launch("stack.gallery.cold", warmUp: false)
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 60), "All Tabs didn't open")
        for id in ["work-figma-onb", "work-hn", "work-gh-pr", "work-lumen", "work-linear-method"] {
            XCTAssertTrue(wait { self.shows(id) == "picture" }, "\(id)'s card shows \(shows(id)) after the relaunch")
        }
        // Tern was never loaded, and the warm-up is off here: its icon stands in.
        XCTAssertEqual(shows("work-tern-local"), "icon")
        picture("All Tabs right after a relaunch: the pictures kept on disk")
    }

    func testCardsNeverLoadedHereWarmUpUnderTheCardsAndShowTheirPages() {
        // A first launch with nothing kept: only the warm-up can picture them.
        launch("stack.gallery.cold")
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 60), "All Tabs didn't open")
        // One deadline for them all: a cold app and web process on a loaded
        // farm Mac took 90 s to draw its first page once (scripts/README.md).
        let deadline = Date().addingTimeInterval(180)
        for id in cards {
            XCTAssertTrue(wait(max(1, deadline.timeIntervalSinceNow)) { self.shows(id) == "picture" },
                          "\(id)'s card still shows \(shows(id))")
        }
        picture("All Tabs: every card warmed up to its page")
        XCTAssertGreaterThanOrEqual(files.count, 5, "the warmed pictures are kept for the next launch")
        // A warmed card opens its page as any card does: HN's, at the focus.
        let hn = element("tabs.card.work-hn")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: hn.frame.midX, dy: hn.frame.midY)).tap()
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists }, "the card didn't open")
        let plate = element("chrome.plate")
        XCTAssertTrue(wait(20) { plate.exists && plate.label.hasPrefix("Hacker News") }, "HN isn't in front: \(plate.label)")
    }
}
