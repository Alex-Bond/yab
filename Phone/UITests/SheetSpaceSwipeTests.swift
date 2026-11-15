import XCTest

/// Space paging on the search sheet, the way the app opens it outside tests
/// (`-YabSearchSheet`, pulled up to the spaces). SpaceRowSwipeTests covers the
/// older field layer; both draw SpacePagesCard.
final class SheetSpaceSwipeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() { app?.terminate() }

    private func node(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var row: XCUIElement { node("newtab.tab.work-launch-notes") }
    private var current: String {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == 'current'")).firstMatch.label
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func launch() throws {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabSearchSheet", "-YabState", "search.spaces"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        try save("sheet-launch")
        XCTAssertEqual(current, "Work")
    }

    private func drag(x: CGFloat, y: CGFloat, dx: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func save(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("sheet-space-swipes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shot = app.screenshot()
        try shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testEmptyAreaBelowTheListPagesFromTheCenter() throws {
        try launch()
        drag(x: app.frame.width - 14, y: row.frame.midY, dx: -260)
        XCTAssertTrue(wait { current == "Lisbon" })
        let tabs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.tab.lisbon-'")).allElementsBoundByIndex
        let bottom = tabs.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? 0
        XCTAssertGreaterThan(bottom, 0)
        let y = bottom + 35
        XCTAssertLessThan(y, app.frame.height - 140, "the swipe must begin in empty space below the list")
        try save("empty-before")
        drag(x: app.frame.midX - 80, y: y, dx: 220)
        XCTAssertTrue(wait { current == "Work" }, "empty space must page from the center")
        try save("empty-after")
    }

    func testChatsPagePagesFromTheCenter() throws {
        try launch()
        for _ in 0..<3 {
            if current == "Chats" { break }
            let before = current
            drag(x: 14, y: app.frame.height * 0.5, dx: 260)
            XCTAssertTrue(wait { current != before })
        }
        XCTAssertEqual(current, "Chats")
        try save("chats-before")
        drag(x: app.frame.midX + 80, y: app.frame.height * 0.5, dx: -220)
        XCTAssertTrue(wait { current == "Personal" }, "Chats must page from the center")
        try save("chats-after")
    }

    func testCenterRowSwipeOpensCloseWithoutChangingSpace() throws {
        try launch()
        drag(x: row.frame.midX, y: row.frame.midY, dx: -120)
        try save("row-after")
        XCTAssertEqual(current, "Work", "a row swipe from its middle must keep its Space")
        XCTAssertTrue(app.buttons["newtab.swipe.close.work-launch-notes"].firstMatch.waitForExistence(timeout: 3),
                      "a row swipe from its middle must open the row's actions")
    }
}
