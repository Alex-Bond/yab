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

    func testGallerySwitchesSpacesWithoutClearingTabs() throws {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabSearchSheet", "-YabState", "stack.gallery", "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        XCTAssertTrue(node("tabs.gallery").waitForExistence(timeout: 30))
        func cards() -> [String] {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.card.'"))
                .allElementsBoundByIndex.map(\.identifier).sorted()
        }
        let original = cards()
        XCTAssertFalse(original.isEmpty)
        try save("gallery-spaces-before")
        // The spaces' own capsule: its names are buttons by their labels.
        let lisbon = node("tabs.spaces").buttons["Lisbon"]
        XCTAssertTrue(lisbon.waitForExistence(timeout: 5), "spaces must be reachable while tabs are still open")
        lisbon.tap()
        XCTAssertTrue(wait { current == "Lisbon" })
        XCTAssertTrue(cards().allSatisfy { $0.hasPrefix("tabs.card.lisbon-") })
        XCTAssertFalse(cards().isEmpty)
        try save("gallery-spaces-lisbon")
        node("tabs.spaces").buttons["Work"].tap()
        XCTAssertTrue(wait { current == "Work" })
        XCTAssertEqual(cards(), original, "switching away and back must keep every card")
        try save("gallery-spaces-returned")
        let picker = node("tabs.spaces")
        XCTAssertLessThan(app.buttons["tabs.new"].frame.midX, picker.frame.midX)
        XCTAssertGreaterThan(app.buttons["tabs.done"].frame.midX, picker.frame.midX)
        XCTAssertLessThan(app.buttons["tabs.settings"].frame.midY, app.frame.height * 0.3)
        // The computer: the sidebar in place, its Settings, +, capsule and Done where All Tabs' were.
        let settings = app.buttons["tabs.settings"].frame, plus = app.buttons["tabs.new"].frame
        let done = app.buttons["tabs.done"].frame, computer = app.buttons["tabs.sidebar"].frame
        app.buttons["tabs.sidebar"].tap()
        XCTAssertTrue(app.buttons["spaces.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait { !node("tabs.gallery").exists })
        try save("gallery-to-sidebar")
        XCTAssertEqual(app.buttons["newtab.settings"].frame.midX, settings.midX, accuracy: 1)
        XCTAssertEqual(app.buttons["newtab.settings"].frame.midY, settings.midY, accuracy: 1)
        XCTAssertEqual(app.buttons["spaces.new"].frame.midX, plus.midX, accuracy: 1)
        XCTAssertEqual(app.buttons["spaces.done"].frame.midX, done.midX, accuracy: 1)
        XCTAssertEqual(app.buttons["spaces.done"].frame.midY, done.midY, accuracy: 1)
        XCTAssertEqual(node("newtab.more").frame.midY, computer.midY, accuracy: 1)
    }

    func testSwitchingSpacesPreservesTheirRows() throws {
        try launch()
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.tab.work-'"))
            .allElementsBoundByIndex.map(\.identifier).sorted()
        XCTAssertFalse(original.isEmpty)
        for _ in 0..<2 {
            drag(x: app.frame.width - 14, y: row.frame.midY, dx: -260)
            XCTAssertTrue(wait { current == "Lisbon" })
            try save("tabs-lisbon")
            drag(x: 14, y: app.frame.height * 0.5, dx: 260)
            XCTAssertTrue(wait { current == "Work" })
        }
        try save("tabs-work-returned")
        let returned = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.tab.work-'"))
            .allElementsBoundByIndex.map(\.identifier).sorted()
        XCTAssertEqual(returned, original)
    }

    func testMacShortcutDoesNotAppearInAnotherSpace() throws {
        try launch()
        drag(x: app.frame.width - 14, y: row.frame.midY, dx: -260)
        XCTAssertTrue(wait { current == "Lisbon" })
        try save("mac-shortcut-lisbon")
        let leaked = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'On your Mac now'"))
        XCTAssertEqual(leaked.count, 0, "the Mac shortcut belongs only in its source space")
    }

    func testApprovedBottomLayout() throws {
        try launch()
        try save("layout")
        checkBottomLayout()
    }

    func testApprovedBottomLayoutInLandscape() throws {
        try launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { app.frame.width > app.frame.height })
        try save("layout-landscape")
        checkBottomLayout()
    }

    private func checkBottomLayout() {
        let picker = node("newtab.capsule")
        let plus = app.buttons["spaces.new"]
        let gear = app.buttons["newtab.settings"]
        let done = app.buttons["spaces.done"]
        XCTAssertGreaterThan(picker.frame.midY, app.frame.height * 0.7)
        XCTAssertLessThan(plus.frame.midX, picker.frame.midX)
        XCTAssertGreaterThan(done.frame.midX, picker.frame.midX)
        XCTAssertLessThan(gear.frame.midY, app.frame.height * 0.3)
    }

    func testSearchOpensInTheViewedSpaceAndKeepsIt() throws {
        try launch()
        drag(x: app.frame.width - 14, y: row.frame.midY, dx: -260)
        XCTAssertTrue(wait { current == "Lisbon" })
        try save("search-lisbon-before")
        let input = app.textFields["field.input"]
        app.buttons["spaces.new"].tap()
        XCTAssertTrue(wait { app.keyboards.firstMatch.exists })
        input.typeText("g\n")
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        try save("search-opened")
        app.openNewTabFromChrome()
        // Expand the search sheet back to the spaces.
        let start = node("search.sheet").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -350)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(wait { current == "Lisbon" }, "search must open in the viewed space and reopen there")
        try save("search-space-after")
    }

    func testViewedSpaceIsKeptWhenSpacesAreClosedWithoutOpeningATab() throws {
        try launch()
        drag(x: app.frame.width - 14, y: row.frame.midY, dx: -260)
        XCTAssertTrue(wait { current == "Lisbon" })
        try save("selection-before-close")
        app.buttons["spaces.done"].tap()
        app.openNewTabFromChrome()
        let lift = node("search.sheet").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        lift.press(forDuration: 0.05, thenDragTo: lift.withOffset(CGVector(dx: 0, dy: -350)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        try save("selection-after-reopen")
        XCTAssertTrue(wait { current == "Lisbon" })
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
