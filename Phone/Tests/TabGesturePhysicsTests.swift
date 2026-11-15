import XCTest
@testable import YabPhone

@MainActor
final class TabGesturePhysicsTests: XCTestCase {
    func testAThrownCardKeepsItsVelocityAndFasterThrowsLeaveEarlier() {
        let slow = TabCardTrajectory(start: -80, velocity: -500, bottom: 700)
        let fast = TabCardTrajectory(start: -80, velocity: -2400, bottom: 700)
        XCTAssertEqual(slow.offset(at: 0), -80)
        XCTAssertEqual(fast.offset(at: 0), -80)
        XCTAssertGreaterThan(slow.offset(at: 0.1), fast.offset(at: 0.1))
        XCTAssertFalse(slow.hasLeft(at: 0.25))
        XCTAssertTrue(fast.hasLeft(at: 0.25))
        XCTAssertTrue(slow.hasLeft(at: 1))
    }

    func testPinchDoesNotStealWebsiteZoomOrStartOverAModal() {
        XCTAssertTrue(TabOverviewPinch.mayBegin(inward: true, zoom: 1, minimum: 1, available: true))
        XCTAssertTrue(TabOverviewPinch.mayBegin(inward: true, zoom: 0.6, minimum: 0.6, available: true))
        XCTAssertFalse(TabOverviewPinch.mayBegin(inward: true, zoom: 2, minimum: 1, available: true))
        XCTAssertFalse(TabOverviewPinch.mayBegin(inward: false, zoom: 1, minimum: 1, available: true))
        XCTAssertFalse(TabOverviewPinch.mayBegin(inward: true, zoom: 1, minimum: 1, available: false))
    }

    func testInteractiveOpeningHasExactPageAndGalleryEndpointsOnPhoneAndTablet() {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 1024, height: 1366)] {
            let layout = TabGalleryLayout(screen: size, count: 6)
            let stack = TabStackGeometry(screen: size)
            for i in 0..<6 {
                let first = TabGalleryMotion.interactiveOpening(i, layout: layout, stack: stack, progress: 0)
                let last = TabGalleryMotion.interactiveOpening(i, layout: layout, stack: stack, progress: 1)
                XCTAssertEqual(first.rect, TabGalleryMotion.opening(i, layout: layout, stack: stack, t: 0).rect)
                XCTAssertEqual(last.rect, TabGalleryMotion.rest(i, layout: layout, focus: layout.initialFocus).rect)
            }
        }
    }

    func testPinchCanCancelAndCommitWithoutChangingTheSelectedTab() async throws {
        let old = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = old }
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let stack = TabStack.of(app)
        let selected = app.browser.tab?.id
        stack.beginPinch()
        stack.updatePinch(0.2)
        XCTAssertEqual(stack.gallery?.pinchProgress, 0.2)
        stack.endPinch(velocity: 0, cancelled: true)
        XCTAssertNil(stack.gallery)
        XCTAssertEqual(app.surfaces.chromeOpacity, 1)
        stack.beginPinch()
        stack.updatePinch(0.6)
        stack.endPinch(velocity: 0, cancelled: false)
        XCTAssertEqual(stack.gallery?.phase, .open)
        XCTAssertNil(stack.gallery?.pinchProgress)
        XCTAssertEqual(app.browser.tab?.id, selected)
        stack.dismissGallery()
    }

    func testAnInFlightCardCanBeCaughtAndKeptOpen() async throws {
        let old = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = old }
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let stack = TabStack.of(app)
        stack.openGallery()
        let id = try XCTUnwrap(stack.gallery?.order.first)
        Motion.disabled = false
        stack.liftCard(id, by: -80)
        stack.releaseCard(id, dy: -80, velocity: -900)
        XCTAssertTrue(stack.gallery?.leaving.contains(id) == true)
        stack.liftCard(id, by: -90)
        XCTAssertFalse(stack.gallery?.leaving.contains(id) == true)
        XCTAssertEqual(stack.gallery?.lift, -90)
        Motion.disabled = true
        stack.releaseCard(id, dy: -90, velocity: 0)
        XCTAssertNotNil(app.browser.tab(id))
        XCTAssertNil(stack.gallery?.lifted)
        stack.dismissGallery()
    }

    func testTheLastCardDoesNotLoseItsTouchTargetToSearchWhileFlying() throws {
        let old = Motion.disabled
        let oldSheet = FieldModel.sheetInTests
        Motion.disabled = true
        FieldModel.sheetInTests = true
        defer { Motion.disabled = old; FieldModel.sheetInTests = oldSheet }
        let tab = Tab(id: "last", title: "Last", site: "Example", icon: "globe", url: "https://example.test")
        let app = AppModel(world: World(name: "one", space: "s", spaces: [
            Space(id: "s", name: "Tabs", emoji: "", tint: RGB(240, 240, 240), today: [tab], current: tab.id)
        ]), privateLockEnabled: { false })
        let stack = TabStack.of(app)
        stack.openGallery()
        Motion.disabled = false
        stack.liftCard(tab.id, by: -150)
        stack.releaseCard(tab.id, dy: -150, velocity: -600)
        XCTAssertTrue(stack.gallery?.leaving.contains(tab.id) == true)
        XCTAssertNil(app.surfaces.field, "search must not cover a card that can still be caught")
        stack.liftCard(tab.id, by: -60)
        Motion.disabled = true
        stack.releaseCard(tab.id, dy: -60, velocity: 0)
        XCTAssertNotNil(app.browser.tab(tab.id))
        XCTAssertNil(app.surfaces.field)
        stack.dismissGallery()
    }
}
