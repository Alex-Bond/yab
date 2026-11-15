import XCTest
import UIKit
@testable import YabPhone

@MainActor
final class ShakeUndoTests: XCTestCase {
    private func app() throws -> AppModel {
        AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
    }

    func testRootExposesBrowserUndoToUIKit() throws {
        let app = try app()
        let root = RootController(app: app)
        XCTAssertTrue(root.undoManager === app.actionUndo)
        XCTAssertTrue(root.canBecomeFirstResponder)
    }

    func testTextFieldKeepsItsOwnUndoManager() throws {
        let app = try app()
        let root = RootController(app: app)
        root.loadViewIfNeeded()
        let field = UITextField()
        root.view.addSubview(field)
        XCTAssertFalse(field.undoManager === app.actionUndo)
    }

    func testArchiveCanBeUndoneWithoutReplacingLaterChatEdits() throws {
        let app = try app()
        app.archive("cafe")
        XCTAssertTrue(app.actionUndo.canUndo)
        app.chats.update("cafe") { $0.title = "Edited after archiving" }
        app.actionUndo.undo()
        XCTAssertEqual(app.chats.chat("cafe")?.archived, false)
        XCTAssertEqual(app.chats.chat("cafe")?.title, "Edited after archiving")
        XCTAssertFalse(app.actionUndo.canUndo)
    }

    func testCloseUsesExistingReceiptAndRestoresItsSpace() throws {
        let app = try app()
        app.browser.select("lisbon-wiki")
        let saved = try XCTUnwrap(app.backStack.remember("lisbon-wiki"))
        app.browser.close(saved.tab.id)
        app.backStack.offer(saved)
        app.actionUndo.undo()
        XCTAssertEqual(app.browser.tab?.id, saved.tab.id)
        XCTAssertEqual(app.browser.spaceID, saved.space)
        XCTAssertNil(app.backStack.closed)
    }

    func testSwitchingSpacesPreservesAllTabsAndEachSelection() throws {
        let app = try app()
        let before = app.browser.spaces
        for space in before { app.browser.showSpace(space.id) }
        for space in before.reversed() {
            app.browser.showSpace(space.id)
            XCTAssertEqual(app.browser.space(space.id), space)
            XCTAssertEqual(app.browser.tab?.id, space.current)
        }
        XCTAssertEqual(app.browser.spaces, before)
    }
}
