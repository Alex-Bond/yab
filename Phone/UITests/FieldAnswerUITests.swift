import XCTest

/// Real typing, accessory taps, native copy actions and Paste in the field.
/// These run with the ordinary keyboard and all page animations enabled.
final class FieldAnswerUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ready: URL!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(); ready = Atlas.readyFolder()
    }

    override func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(at: ready)
    }

    func testNativeMathKeysReturnAndCardTapCopyWithoutLeavingTheField() throws {
        launch("page.1")
        app.descendants(matching: .any)["chrome.plate"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(wait { input.exists && input.isHittable && self.app.keyboards.firstMatch.exists })
        input.typeText("2400")
        let multiply = app.buttons["field.math.×"]
        XCTAssertTrue(wait { multiply.exists && multiply.isHittable })
        assertControl(multiply); multiply.tap()
        input.typeText("12")
        let answer = app.buttons["field.answer"]
        XCTAssertTrue(wait { answer.exists && answer.isHittable && answer.label.contains("28,800") })
        XCTAssertEqual(input.value as? String, "2400×12")
        assertAnswerFits(answer, input: input)
        record("C plate and native math strip")
        tapReturn()
        XCTAssertTrue(input.exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Copy keeps the keyboard and browser field")
        pasteIntoClearedField(expected: "28800")
        app.buttons["field.clearWords"].tap()
        input.typeText("2+2")
        XCTAssertTrue(wait { answer.exists && answer.label.contains("4") && answer.isHittable })
        answer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "A card tap must not bubble into background keyboard dismissal")
        pasteIntoClearedField(expected: "4")
        record("Both real copy paths pasted back into native field")
        app.buttons["field.close"].tap()
        XCTAssertTrue(wait { !input.exists && self.app.descendants(matching: .any)["chrome.plate"].isHittable })
    }

    func testSwapAndHoldMenuUseTheVisibleSidesAndKeepNativeEditingUsable() throws {
        launch("field.answer.units")
        let input = app.textFields["field.input"], answer = app.buttons["field.answer"]
        let swap = app.buttons["field.answer.swap"]
        XCTAssertTrue(wait { answer.isHittable && swap.isHittable && self.app.keyboards.firstMatch.exists })
        assertControl(swap); assertAnswerFits(answer, input: input)
        swap.tap()
        XCTAssertTrue(wait { answer.label.hasPrefix("3.1069 mi is 5 km") })
        answer.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        pasteIntoClearedField(expected: "5 km")
        app.buttons["field.clearWords"].tap(); input.typeText("2400*12")
        XCTAssertTrue(wait { answer.exists && answer.label.contains("28,800") })
        answer.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Copy Answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy Question"].exists)
        XCTAssertTrue(app.buttons["Paste into Page"].exists)
        XCTAssertFalse(app.buttons["Paste into Page"].isEnabled, "The world fixture has no focused original editable field")
        XCTAssertTrue(app.buttons["Share"].exists)
        record("Native answer hold menu")
        app.buttons["Copy Question"].tap()
        XCTAssertTrue(wait { input.exists && input.isHittable })
        XCTAssertNotEqual(answer.value as? String, "Copied", "Copy Question must not mark the result as copied")
        pasteIntoClearedField(expected: "2400 × 12")
        record("Copy Question preserves the expression")
    }

    func testPrivateChatsTimeAndWaitingRatesKeepTheirOwnReturnBehavior() throws {
        launch("field.answer.private")
        let input = app.textFields["field.input"], answer = app.buttons["field.answer"]
        XCTAssertTrue(wait { answer.isHittable && answer.label.contains("16") })
        tapReturn()
        pasteIntoClearedField(expected: "16")
        record("Private calculator stays in private field")
        launch("field.answer.chats")
        XCTAssertFalse(app.buttons["field.answer"].exists)
        input.tap()
        tapReturn()
        XCTAssertTrue(input.exists)
        XCTAssertFalse(app.buttons["field.answer"].exists)
        XCTAssertFalse(app.buttons["field.math.+"].exists)
        record("Chats searches conversations")
        launch("field.answer.time")
        XCTAssertTrue(wait { answer.isHittable })
        tapReturn()
        XCTAssertTrue(wait { !input.exists })
        record("Time Return performs ordinary search")
        launch("field.answer.waiting")
        XCTAssertTrue(wait { answer.exists && !answer.isEnabled })
        XCTAssertEqual(answer.value as? String, "Getting rates")
        record("Pending exchange rates cannot copy")
    }

    private func launch(_ state: String) {
        app.terminate()
        XCTAssertTrue(Atlas.launch(app, state: state, ready: ready, still: false), "\(state) never settled")
    }

    private func tapReturn() {
        // iOS 26's web-search keyboard exposes its blue arrow as Go even
        // when the field's Return route is Search. Key/Button types vary.
        let submit = app.keyboards.descendants(matching: .any).matching(
            NSPredicate(format: "label IN[c] %@ OR identifier IN[c] %@", ["go", "search", "return"], ["go", "search", "return"])
        ).firstMatch
        let ready = wait { submit.exists && submit.isHittable }
        if !ready { record("Native Return key unavailable") }
        XCTAssertTrue(ready)
        assertControl(submit)
        submit.tap()
    }

    private func pasteIntoClearedField(expected: String) {
        let input = app.textFields["field.input"]
        app.buttons["field.clearWords"].tap()
        XCTAssertTrue(wait { input.exists && input.isHittable })
        input.press(forDuration: 0.8)
        XCTAssertTrue(wait { self.app.menuItems["Paste"].exists || self.app.buttons["Paste"].exists })
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "The real native clipboard Paste command must be offered")
        paste.tap()
        XCTAssertTrue(wait { input.value as? String == expected }, "Actual pasted value was \(String(describing: input.value))")
    }

    private func assertControl(_ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(control.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.height, 44, file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame), "control \(control.frame), window \(app.windows.firstMatch.frame)", file: file, line: line)
    }

    private func assertAnswerFits(_ answer: XCUIElement, input: XCUIElement) {
        assertControl(answer)
        XCTAssertLessThanOrEqual(answer.frame.maxY, input.frame.minY, "Answer plate must stay above the field and keyboard")
        let capsule = app.descendants(matching: .any)["newtab.capsule"]
        if capsule.exists { XCTAssertGreaterThanOrEqual(answer.frame.minY, capsule.frame.maxY) }
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expected], timeout: 10) == .completed
    }

    private func record(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
