import XCTest

/// The paths between the features, each built on a branch of its own and
/// joined on 2026-10-06: + grows the field's New Tab, a question in the
/// field grows the chats' answer, the spaces' gear and the word "settings"
/// open Settings, the Now line opens the tasks' sheet, and Settings › Sync ›
/// Your Mac › Sync opens sync's join with a code.
final class IntegrationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Mira's world, in a named state or at its start; nothing animates.
    private func launch(_ state: String? = nil) {
        app = XCUIApplication()
        var arguments = ["-YabWorld", "mira", "-YabNoAnim", "YES"]
        if let state { arguments += ["-YabState", state] }
        app.launchArguments = arguments
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shows(_ id: String, _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(id).waitForExistence(timeout: timeout), what, file: file, line: line)
    }

    /// The spaces up, from the plate swipe.
    private func openSpaces() {
        shows("chrome.plate", "no plate", timeout: 30)
        SpacesGesture.open(in: app)
        shows("newtab.spaces", "the spaces didn't come up")
    }

    /// The plate's field, the address selected: the first key replaces it.
    private func typeInField(_ words: String) -> XCUIElement {
        shows("chrome.plate", "no plate", timeout: 30)
        element("chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "no field")
        input.typeText(words)
        let best = element("field.best")
        XCTAssertTrue(best.waitForExistence(timeout: 5), "no row for \(words)")
        return best
    }

    /// Mira has other tabs, so the right button is the tab stack and its
    /// held menu's New Tab is the + (c5b9180c); New Tab is the spaces' card
    /// around the field (efa361a2).
    func testThePlusOpensTheFieldsNewTab() {
        launch()
        shows("chrome.plus", "no +", timeout: 30)
        app.openNewTabFromChrome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5), "+ opened no field")
        shows("newtab.spaces", "+ opened the field without New Tab's spaces")
    }

    func testAQuestionInTheFieldGrowsTheChatsAnswer() {
        launch()
        let best = typeInField("what does anna want?")
        XCTAssertTrue(best.label.lowercased().contains("ask"), "the question's row: \(best.label)")
        best.tap()
        shows("chat.question", "no answer sheet with the question")
        shows("chat.answer", "the question was never answered", timeout: 15)
    }

    func testTheSpacesGearOpensSettings() {
        launch()
        openSpaces()
        element("newtab.settings").tap()
        shows("settings.sheet", "the spaces' gear opened no Settings")
    }

    /// Yab's mark by the capsule opens About Yab: the name, "Version X (build)",
    /// the copyright, no credits; ‹ takes it away.
    func testTheSpacesMarkOpensAbout() {
        launch()
        openSpaces()
        element("newtab.about").tap()
        shows("about", "the mark opened no About")
        XCTAssertEqual(element("about.name").label, "Yab")
        let version = element("about.version").label
        XCTAssertNotNil(version.range(of: #"^Version \d+(\.\d+)+ \(\d+\)$"#, options: .regularExpression), "the version: \(version)")
        XCTAssertTrue(element("about.website").exists, "no Website")
        XCTAssertTrue(element("about.copyright").label.hasPrefix("©"), "no copyright")
        XCTAssertFalse(app.staticTexts["Credits"].exists, "About shows no credits")
        element("about.back").tap()
        XCTAssertTrue(wait { !self.element("about").exists }, "‹ left About up")
    }

    private func wait(_ condition: () -> Bool) -> Bool { TransitionCatalog.wait(10, condition) }

    func testTheWordSettingsOpensSettings() {
        launch()
        let best = typeInField("settings")
        XCTAssertTrue(best.label.contains("Settings"), "the word's row: \(best.label)")
        best.tap()
        shows("settings.sheet", "the word settings opened no Settings")
    }

    func testTheNowLineOpensTheTasksChat() {
        launch("now.3")
        shows("chrome.now", "no Now line", timeout: 30)
        element("chrome.now").tap()
        shows("task.chat.sheet", "the Now line opened no task chat")
        XCTAssertFalse(element("chat.body").exists, "a task's chat is the tasks' sheet, not the chats' too")
    }

    /// The root's Sync page holds Your Mac, whose own Sync row joins (the
    /// Mac's groups on the root, as SettingsTests walks it).
    func testSyncInSettingsOpensJoiningWithACode() {
        launch("settings.1")
        let root = app.buttons["settings.row.sync"]
        XCTAssertTrue(root.waitForExistence(timeout: 30), "no Sync row in Settings")
        root.tap()
        let mac = app.buttons["settings.row.mac"]
        XCTAssertTrue(mac.waitForExistence(timeout: 5), "no Mac row on the Sync page")
        mac.tap()
        let onMacPage = NSPredicate(format: "exists == true AND label == %@", "Your Mac")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: onMacPage, evaluatedWith: element("settings.page.title"))], timeout: 5),
                       .completed, "Mac opened no Your Mac page")
        let sync = app.buttons["settings.row.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5), "no Sync row on the Mac's page")
        sync.tap()
        shows("join.sheet", "Sync opened no join sheet", timeout: 5)
        XCTAssertEqual(element("join.title").label, "Join Your Mac")
        let code = element("join.code")
        XCTAssertTrue(code.waitForExistence(timeout: 5), "the join sheet has no code")
        XCTAssertTrue(code.label.range(of: #"^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$"#, options: .regularExpression) != nil,
                      "a code of the Mac's alphabet: \(code.label)")
    }
}
