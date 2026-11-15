import XCTest

/// The field's keyboard is the one Safari's address bar brings (#317): the
/// web search keyboard, with a "." key beside the space bar, not the
/// standard one. Pictures go to the job's field-keyboard/ folder.
final class FieldKeyboardTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAddressFieldBringsTheWebSearchKeyboard() throws {
        let app = XCUIApplication()
        XCTAssertTrue(Atlas.launch(app, state: "page.1", ready: Atlas.readyFolder()), "page.1 never settled")
        let plate = app.descendants(matching: .any)["chrome.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 8))
        plate.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no software keyboard came up")
        _ = keyboard.keys["space"].waitForExistence(timeout: 5)
        let labels = keyboard.keys.allElementsBoundByIndex.map(\.label)
        save(app, "field-keyboard", keys: labels)
        XCTAssertTrue(keyboard.keys["."].exists, "the field's keyboard has no \".\" key: \(labels)")
        XCTAssertTrue(keyboard.keys["space"].exists, "the field's keyboard lost its space bar: \(labels)")
    }

    private func save(_ app: XCUIApplication, _ name: String, keys: [String]) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = Atlas.out.appendingPathComponent("field-keyboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try? Data(keys.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent(name + "-keys.txt"))
    }
}
