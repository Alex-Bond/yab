import UIKit
import XCTest
@testable import YabPhone

@MainActor
final class TabletFieldKeysTests: XCTestCase {
    func testArrowCommandsBelongOnlyToAnInputWithResults() throws {
        let field = YabTextField()
        XCTAssertFalse(field.keyCommands?.contains { $0.input == UIKeyCommand.inputDownArrow } ?? false)
        var moves: [Int] = []
        field.moveSelection = { moves.append($0) }
        for (input, delta) in [(UIKeyCommand.inputDownArrow, 1), (UIKeyCommand.inputUpArrow, -1)] {
            let command = try XCTUnwrap(field.keyCommands?.first { $0.input == input })
            XCTAssertTrue(command.modifierFlags.isEmpty)
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            let action = try XCTUnwrap(command.action)
            XCTAssertTrue(field.canPerformAction(action, withSender: command))
            XCTAssertTrue(UIApplication.shared.sendAction(action, to: field, from: command, for: nil))
            XCTAssertEqual(moves.last, delta)
        }
        field.moveSelection = nil
        XCTAssertFalse(field.keyCommands?.contains { $0.input == UIKeyCommand.inputUpArrow } ?? false)
    }

    func testMarkedTextKeepsItsOwnArrowKeys() throws {
        let field = YabTextField()
        field.moveSelection = { _ in XCTFail("composition keeps the arrow") }
        let down = try XCTUnwrap(field.keyCommands?.first { $0.input == UIKeyCommand.inputDownArrow })
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        XCTAssertFalse(field.keyCommands?.contains { $0.input == UIKeyCommand.inputDownArrow } ?? false)
        XCTAssertFalse(field.canPerformAction(try XCTUnwrap(down.action), withSender: down))
        field.unmarkText()
        XCTAssertTrue(field.keyCommands?.contains { $0.input == UIKeyCommand.inputDownArrow } ?? false)
    }
}
