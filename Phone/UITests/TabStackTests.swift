import XCTest

/// The tab stack in place of +, touched as a person would: a flick up on it
/// brings the previous tab and another flick takes it back; held, it offers
/// New Tab (our New Tab, as + opened it) and the recent tabs; tapped, it shows
/// All Tabs, where a card swiped up closes and a card tapped opens. Each
/// starts from stack.1: Figma in front, GitHub used before it, HN before that.
final class TabStackTests: XCTestCase {
    private var app: XCUIApplication!
    private var journal: URL!
    private var ready: URL!

    override func setUp() {
        continueAfterFailure = false
        ready = Atlas.readyFolder()
        // In the simulator both the app and the test runner see the Mac's /tmp.
        journal = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: journal)
        try? FileManager.default.removeItem(at: ready)
    }

    private func launch(_ state: String = "stack.1") {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launchEnvironment["YAB_READY_DIR"] = ready.path
        let marker = ready.appendingPathComponent(state)
        try? FileManager.default.removeItem(at: marker)
        app.launch()
        // The initial stack label can appear while the state still visits its tabs.
        XCTAssertTrue(Atlas.waitForFile(marker, timeout: 60), "the named state did not finish preparing")
        XCTAssertTrue(stack.waitForExistence(timeout: 60), "no right button")
        XCTAssertTrue(wait(30) { self.stackLabel == "Previous tab, feat(editor): wrap text at 800 and keep it clear of the side panels" },
                      "the stack doesn't name GitHub: \(stackLabel)")
    }

    private var stack: XCUIElement { app.buttons["chrome.plus"] }
    /// The stack's spoken name; empty while it is away.
    private var stackLabel: String { stack.exists ? stack.label : "" }

    /// A finger held on the stack until its menu is up; on a loaded Mac
    /// UIKit can miss the first hold, so a second one is allowed.
    private func hold() {
        XCTAssertTrue(wait { self.stack.exists && self.stack.isHittable }, "the stack can't be touched")
        stack.press(forDuration: 0.8)
        if !app.buttons["chrome.menu.newtab"].waitForExistence(timeout: 3) { stack.press(forDuration: 1.2) }
        XCTAssertTrue(app.buttons["chrome.menu.newtab"].waitForExistence(timeout: 5), "the stack's menu didn't come")
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    /// The plate's words, "site, title"; empty while it is away.
    private var plate: String {
        let plate = element("chrome.plate")
        return plate.exists ? plate.label : ""
    }

    private func wait(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// What the finger felt since launch: "light flick", "soft card thrown"…
    private var haptics: [String] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in line.split(separator: " ", maxSplits: 1).dropFirst().joined() }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A finger up from the stack, quick, 120 points.
    private func flick() {
        let frame = stack.frame
        let start = point(frame.midX, frame.midY)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)), withVelocity: .fast, thenHoldForDuration: 0.02)
    }

    func testAFlickUpBringsThePreviousTabAndAnotherTakesItBack() {
        launch()
        XCTAssertTrue(wait { self.plate.hasPrefix("Figma") }, "Figma isn't in front: \(plate)")
        flick()
        XCTAssertTrue(wait { self.plate.hasPrefix("GitHub") }, "the flick didn't bring GitHub: \(plate)")
        XCTAssertTrue(wait { self.stackLabel == "Previous tab, Onboarding v3" }, "the stack doesn't offer Figma back: \(stackLabel)")
        picture("After a flick: GitHub in front, Figma in the stack")
        flick()
        XCTAssertTrue(wait { self.plate.hasPrefix("Figma") }, "the second flick didn't take Figma back: \(plate)")
        XCTAssertEqual(haptics.filter { $0 == "light flick" }.count, 2, "one tick per flick: \(haptics)")
        XCTAssertFalse(app.textFields["field.input"].exists)
        XCTAssertFalse(element("tabs.gallery").exists)
        XCTAssertFalse(element("newtab.spaces").exists)
    }

    func testHoldingTheStackOffersNewTabsAndRecentTabsAndNewTabOpensOurNewTab() {
        launch()
        hold()
        for id in ["chrome.menu.newtab", "chrome.menu.newprivate", "chrome.menu.newchat", "chrome.menu.tab.work-gh-pr", "chrome.menu.tab.work-hn", "chrome.menu.alltabs"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "the menu has no \(id)")
        }
        XCTAssertEqual(app.buttons["chrome.menu.alltabs"].label, "All Tabs · 6")
        XCTAssertLessThan(app.buttons["chrome.menu.newchat"].frame.minY, app.buttons["chrome.menu.tab.work-gh-pr"].frame.minY)
        XCTAssertLessThan(app.buttons["chrome.menu.newtab"].frame.minY, app.buttons["chrome.menu.tab.work-gh-pr"].frame.minY)
        XCTAssertLessThan(app.buttons["chrome.menu.tab.work-hn"].frame.minY, app.buttons["chrome.menu.alltabs"].frame.minY)
        picture("The stack held: New Tab, New Private Tab, New Chat, the two recent tabs, All Tabs")
        app.buttons["chrome.menu.newtab"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "New Tab didn't open the field")
        XCTAssertEqual(element("field.eyes").value as? String, "off")
        XCTAssertTrue(element("field.close").waitForExistence(timeout: 5), "no ✕ beside the field")
        picture("New Tab from the stack's menu")
        element("field.close").tap()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertTrue(wait { self.plate.hasPrefix("Figma") }, "New Tab replaced the page in front")
    }

    func testARecentTabInTheMenuComesInFront() {
        launch()
        hold()
        let hn = app.buttons["chrome.menu.tab.work-hn"]
        XCTAssertTrue(hn.waitForExistence(timeout: 5))
        hn.tap()
        XCTAssertTrue(wait { self.plate.hasPrefix("Hacker News") }, "the menu's row didn't bring HN: \(plate)")
    }

    func testTappingTheStackShowsAllTabsWhereACardSwipedUpClosesAndACardTappedOpens() {
        launch()
        stack.tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 5), "All Tabs didn't open")
        for id in ["work-linear-method", "work-lumen", "work-tern-local", "work-hn", "work-gh-pr", "work-figma-onb"] {
            XCTAssertTrue(element("tabs.card.\(id)").exists, "no card for \(id)")
        }
        XCTAssertTrue(element("tabs.new").exists)
        // Oldest to newest, left to right: Figma, in front, on the right.
        XCTAssertLessThan(element("tabs.card.work-gh-pr").frame.minX, element("tabs.card.work-figma-onb").frame.minX)
        XCTAssertLessThan(element("tabs.card.work-hn").frame.minX, element("tabs.card.work-gh-pr").frame.minX)
        picture("All Tabs")
        // GitHub's card shows its left part beside Figma's: up from there, it closes.
        let gh = element("tabs.card.work-gh-pr").frame
        let start = point(max(20, gh.minX + 40), gh.midY)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -380)), withVelocity: .fast, thenHoldForDuration: 0.02)
        XCTAssertTrue(wait { !self.element("tabs.card.work-gh-pr").exists }, "GitHub's card didn't close")
        XCTAssertTrue(haptics.contains("soft card thrown"), "no soft tick for the close: \(haptics)")
        picture("All Tabs with GitHub closed")
        // HN closed the gap: tapped, it opens.
        let hn = element("tabs.card.work-hn")
        XCTAssertTrue(wait { hn.exists && hn.frame.maxX > 40 })
        point(max(20, hn.frame.minX + 40), hn.frame.midY).tap()
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists }, "the card didn't open")
        XCTAssertTrue(wait { self.plate.hasPrefix("Hacker News") }, "HN isn't in front: \(plate)")
        // GitHub's tab is gone, not only its card.
        hold()
        XCTAssertTrue(app.buttons["chrome.menu.alltabs"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["chrome.menu.alltabs"].label, "All Tabs · 5")
        XCTAssertFalse(app.buttons["chrome.menu.tab.work-gh-pr"].exists)
    }

    /// A card's own visible part: the tab in front's card is mostly past
    /// the screen's right edge, so the tap lands 40 points into what shows.
    private func tapCard(_ id: String) {
        let card = element("tabs.card.\(id)")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card for \(id)")
        let screen = app.windows.firstMatch.frame
        point(min(max(card.frame.minX + 40, 20), screen.width - 20), card.frame.midY).tap()
    }

    private func openAllTabs() {
        XCTAssertTrue(wait { self.stack.exists && self.stack.isHittable }, "the stack can't be touched")
        stack.tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 5), "All Tabs didn't open")
        XCTAssertTrue(wait { self.element("tabs.new").exists && self.element("tabs.new").isHittable }, "All Tabs didn't come to rest")
    }

    /// The closing rule (TabGalleryMotion.Closing) as a finger meets it: the
    /// cards lying on the one opened are the stack's two afterwards. The
    /// third card (HN) leaves Figma and GitHub in the stack, Figma in front;
    /// the top card (HN, in front) leaves the stack as it was; the second
    /// (Figma, the previous tab) puts HN in front of the stack, GitHub behind.
    func testAllTabsChatsButtonOpensTheSpacesOnChats() {
        launch()
        stack.tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 5), "All Tabs didn't open")
        let chats = element("tabs.chats")
        XCTAssertTrue(chats.waitForExistence(timeout: 3), "no Chats button")
        XCTAssertLessThan(chats.frame.midX, app.frame.width / 3, "Chats sits at the bar's left")
        chats.tap()
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists }, "All Tabs stayed")
        XCTAssertTrue(wait { self.app.staticTexts["Chats"].exists }, "the spaces didn't open on Chats")
        picture("Chats from All Tabs")
    }

    func testAShortSwipeBringsTheTabInFrontFromTheRightToTheFocus() {
        launch()
        stack.tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 5), "All Tabs didn't open")
        let figma = element("tabs.card.work-figma-onb"), gh = element("tabs.card.work-gh-pr")
        XCTAssertTrue(wait { figma.exists && figma.frame.minX > app.frame.width * 0.6 }, "the tab in front isn't on the right")
        let focusX = gh.frame.minX
        // A short, slow swipe left from its edge pages on, not back.
        let start = point(figma.frame.minX + 30, figma.frame.midY)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.05)
        // The newest card stands in the middle once it reaches the focus.
        XCTAssertTrue(wait { abs(figma.frame.midX - self.app.frame.midX) < 12 }, "Figma's card did not center: \(figma.frame.midX) vs \(app.frame.midX)")
        picture("The tab in front at the focus")
        // And a short swipe right takes it back.
        let back = point(figma.frame.midX, figma.frame.midY)
        back.press(forDuration: 0.05, thenDragTo: back.withOffset(CGVector(dx: 110, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(wait { abs(gh.frame.minX - focusX) < 12 }, "GitHub's card didn't come back to the focus")
    }

    func testTheCardsLyingOnTheOneOpenedAreTheStacksAfterwards() {
        launch()
        openAllTabs()
        tapCard("work-hn")
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists }, "HN's card didn't open")
        XCTAssertTrue(wait { self.plate.hasPrefix("Hacker News") }, "HN isn't in front: \(plate)")
        XCTAssertTrue(wait { self.stackLabel == "Previous tab, Onboarding v3" }, "Figma isn't the stack's front: \(stackLabel)")
        hold()
        let figma = app.buttons["chrome.menu.tab.work-figma-onb"], github = app.buttons["chrome.menu.tab.work-gh-pr"]
        XCTAssertTrue(figma.waitForExistence(timeout: 5) && github.exists, "the stack's two aren't Figma and GitHub")
        XCTAssertLessThan(figma.frame.minY, github.frame.minY, "Figma first")
        picture("After the third card: Figma and GitHub in the stack")
        point(200, 120).tap()
        XCTAssertTrue(wait { !figma.exists }, "the menu didn't go")
        openAllTabs()
        tapCard("work-hn")
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists }, "the top card didn't open")
        XCTAssertTrue(wait { self.plate.hasPrefix("Hacker News") })
        XCTAssertTrue(wait { self.stackLabel == "Previous tab, Onboarding v3" }, "the top card changed the stack: \(stackLabel)")
        openAllTabs()
        tapCard("work-figma-onb")
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists }, "the second card didn't open")
        XCTAssertTrue(wait { self.plate.hasPrefix("Figma") }, "Figma isn't in front: \(plate)")
        XCTAssertTrue(wait { self.stackLabel == "Previous tab, Hacker News" }, "HN isn't the stack's front: \(stackLabel)")
        picture("After the second card: HN in front of the stack, GitHub behind")
    }

    func testLastPrivateCardWithNoOrdinaryTabsReturnsToOrdinarySearch() throws {
        app = XCUIApplication()
        let state = "stack.private-last"
        app.launchArguments = ["-YabWorld", "empty", "-YabState", state, "-YabNoAnim", "YES",
                               "-YabPrivateLockTestAuthentication", "off"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launchEnvironment["YAB_READY_DIR"] = ready.path
        app.launch()
        XCTAssertTrue(Atlas.waitForFile(ready.appendingPathComponent(state), timeout: 60))
        XCTAssertTrue(stack.waitForExistence(timeout: 10))
        XCTAssertEqual(stack.value as? String, "Private")
        stack.tap()
        let card = element("tabs.card.private-last-close")
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        func save(_ name: String) throws {
            let folder = Atlas.out.appendingPathComponent("private-last-close")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
            picture(name)
        }
        try save("before-close")
        let frame = card.frame
        let start = point(min(max(frame.minX + 40, 20), app.frame.width - 20), frame.midY)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -380)),
                    withVelocity: .fast, thenHoldForDuration: 0.02)
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists })
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(element("field.eyes").value as? String, "off")
        try save("ordinary-search")
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        // The empty public page owns New Tab instead of the page's chrome.
        let newTab = app.buttons["empty.new"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { newTab.isHittable })
        newTab.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(element("field.eyes").value as? String, "off")
    }

    func testOneTabLeftStandsInTheStackAndOpensAllTabs() {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "stack.3", "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        XCTAssertTrue(stack.waitForExistence(timeout: 60))
        XCTAssertTrue(wait(30) { self.stackLabel == "All Tabs" }, "no lone tab, yet: \(stackLabel)")
        stack.tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 5), "the stack didn't open All Tabs")
    }
}

extension XCUIApplication {
    /// New Tab from the chrome's right button, as a person opens it: + is
    /// tapped; while other tabs are open it is the tab stack, held for its
    /// menu's New Tab.
    func openNewTabFromChrome(file: StaticString = #filePath, line: UInt = #line) {
        let right = buttons["chrome.plus"]
        XCTAssertTrue(right.waitForExistence(timeout: 10), "no right button", file: file, line: line)
        guard right.label.hasPrefix("Previous tab") else { right.tap(); return }
        right.press(forDuration: 0.8)
        let newTab = buttons["chrome.menu.newtab"]
        // On a loaded Mac UIKit can miss the first hold.
        if !newTab.waitForExistence(timeout: 3) { right.press(forDuration: 1.2) }
        XCTAssertTrue(newTab.waitForExistence(timeout: 5), "the stack's menu has no New Tab", file: file, line: line)
        newTab.tap()
    }
}
