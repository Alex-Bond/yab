import XCTest
import SwiftUI
import UIKit
@testable import YabPhone

@MainActor
final class ChromeFeedbackTests: XCTestCase {
    private final class Authentication: PrivateAuthenticating {
        var completion: (@MainActor (PrivateAuthenticationResult) -> Void)?
        func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void) { self.completion = completion }
        func invalidate() {}
    }
    private var previousDisabled = false
    private var previousReduced = false

    override func setUp() async throws {
        previousDisabled = Motion.disabled
        previousReduced = FieldMotion.forced
        Motion.disabled = true
        FieldMotion.forced = false
    }

    override func tearDown() async throws {
        Motion.disabled = previousDisabled
        FieldMotion.forced = previousReduced
    }

    private func makeApp(_ auth: Authentication? = nil, locked: Bool = false) throws -> AppModel {
        AppModel(world: try World.load(named: "mira"), privateAuthentication: auth ?? Authentication(),
                 privateLockEnabled: { locked })
    }

    func testPrivateMenuOpensCleanInputWithoutBorrowingOrReplacingPublicDraft() throws {
        let app = try makeApp()
        let owner = app.browser.spaceID, selected = app.browser.tab?.id
        app.openNewTab()
        app.field.typed("ordinary draft")
        app.surfaces.closeField()
        app.openNewTab(privately: true)
        XCTAssertEqual(app.field.place, .privateTab)
        XCTAssertTrue(app.field.text.isEmpty)
        XCTAssertEqual(app.browser.spaceID, owner)
        XCTAssertEqual(app.browser.tab?.id, selected)
        app.field.typed("private notes")
        XCTAssertTrue(app.fieldRows.allSatisfy { [.open, .search].contains($0.action) })
        app.surfaces.closeField()
        app.openNewTab()
        XCTAssertEqual(app.field.place, .newTab)
        XCTAssertEqual(app.field.text, "ordinary draft")
    }

    func testPrivateMenuWaitsForAuthenticationAndCancelDoesNotOpenField() throws {
        let auth = Authentication(), app = try makeApp(auth, locked: true)
        let owner = app.browser.spaceID, selected = app.browser.tab?.id
        app.openNewTab(privately: true)
        XCTAssertNil(app.surfaces.field)
        XCTAssertNotNil(auth.completion)
        auth.completion?(.cancelled)
        XCTAssertNil(app.surfaces.field)
        XCTAssertEqual(app.browser.spaceID, owner)
        XCTAssertEqual(app.browser.tab?.id, selected)
    }

    func testCanceledPrivateInputIsClearedBeforeLandingOnPublicChrome() async throws {
        let app = try makeApp()
        app.openNewTab()
        app.field.typed("ordinary draft")
        app.surfaces.closeField()
        app.openNewTab(privately: true)
        app.field.typed("private cancellation words")
        app.surfaces.closeField()
        let deadline = Date().addingTimeInterval(5)
        while app.field.shown && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(app.field.shown)
        XCTAssertEqual(app.field.text, "")
        XCTAssertEqual(app.field.newTabWords, "ordinary draft")
        XCTAssertFalse(app.browser.space.isPrivate)
        app.openNewTab()
        XCTAssertEqual(app.field.text, "ordinary draft")
    }

    func testRetiredPageCannotOpenPrivateInputAfterAuthentication() throws {
        let auth = Authentication(), app = try makeApp(auth, locked: true)
        app.openNewTab(privately: true)
        let id = try XCTUnwrap(app.browser.tab?.id)
        var changed = try XCTUnwrap(app.browser.tab)
        changed.url = "https://changed.example/path"
        app.browser.replace(id, with: changed)
        auth.completion?(.unlocked)
        XCTAssertNil(app.surfaces.field)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, changed.navigationURL?.absoluteString)
    }

    func testPrivateMenuCreationStaysPrivateAndOrdinaryPlusKeepsItsOwner() throws {
        let app = try makeApp()
        let publicID = app.browser.spaceID
        app.openNewTab(privately: true)
        app.field.typed("http://127.0.0.1/private-menu?owned=1")
        app.fieldReturn()
        XCTAssertTrue(app.browser.space.isPrivate)
        let id = try XCTUnwrap(app.browser.tab?.id)
        XCTAssertTrue(try XCTUnwrap(app.browser.tab).isPrivate)
        XCTAssertFalse(app.tabCandidates.contains { $0.id == id })
        app.openNewTab()
        XCTAssertEqual(app.field.place, .privateTab)
        XCTAssertTrue(app.field.text.isEmpty)
        app.surfaces.closeField()
        app.browser.showSpace(publicID)
        app.openNewTab()
        XCTAssertEqual(app.field.place, .newTab)
        XCTAssertTrue(app.field.text.isEmpty)
    }

    func testFoldRetainsFullSideGeometryAndMenuKeepsThePillsBottomEdge() {
        for height: CGFloat in [812, 874, 956] {
            let open = ChromeGeometry(size: CGSize(width: 402, height: height), folded: false, hasNow: false)
            let folded = ChromeGeometry(size: open.size, folded: true, hasNow: false)
            XCTAssertEqual(folded.back, open.back)
            XCTAssertEqual(folded.space, open.space)
            XCTAssertEqual(open.back.size, CGSize(width: 48, height: 48))
            XCTAssertEqual(open.buttonOpacity, 1)
            XCTAssertEqual(folded.buttonOpacity, 0)
            XCTAssertEqual(folded.plate.height, Metrics.Chrome.minHeight)
            XCTAssertEqual(folded.plateTouch.height, 44)
        }
    }

    /// Read actual UIKit accessibility/automation containers, including virtual
    /// SwiftUI elements, without creating label proxies or estimated frames.
    private func nativeAccessibility(in root: NSObject) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = [], output: [NSObject] = []
        func walk(_ node: NSObject, depth: Int) {
            guard depth < 32, visited.count < 2048, visited.insert(ObjectIdentifier(node)).inserted else { return }
            output.append(node)
            var children = (node.automationElements ?? node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = node.accessibilityElementCount()
            if count > 0 && count < 512 {
                children += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = node as? UIView { children += view.subviews }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return output
    }

    private func labels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}
