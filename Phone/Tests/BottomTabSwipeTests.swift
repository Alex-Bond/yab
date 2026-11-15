import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Actual native controls and installed recognizer policy. Calling the
/// production state handler qualifies cancellation/ownership, not finger UI.
@MainActor
final class BottomTabSwipeTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var oldDisabled = false

    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }
    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil; Motion.disabled = oldDisabled
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func host(privately: Bool = false) async throws -> (AppModel, PlateGestures, UIPanGestureRecognizer, ToolbarLeftButton, ChromePlusControl) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let first = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/swipe-one")!, id: "one", isPrivate: privately)
        let second = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/swipe-two")!, id: "two", isPrivate: privately)
        let other = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/other")!, id: "other")
        let app = AppModel(world: World(name: "bottom-tab-swipe", space: "source", spaces: [
            Space(id: "source", name: "Source", emoji: "", tint: RGB(238, 233, 226), today: [first, second], current: first.id, isPrivate: privately),
            Space(id: "other", name: "Other", emoji: "", tint: RGB(238, 233, 226), today: [other], current: other.id)
        ], mac: World.Mac(joined: false)), fixturesEnabled: false, privateLockEnabled: { false })
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window = owned
        let host = UIHostingController(rootView: RootView().environment(app))
        host.safeAreaRegions = []
        owned.rootViewController = host
        owned.makeKeyAndVisible(); owned.layoutIfNeeded()
        let ready = await until {
            self.views(owned).contains { $0 is ToolbarLeftButton }
                && self.views(owned).contains { $0 is ChromePlusControl }
                && owned.gestureRecognizers?.contains { $0.delegate is PlateGestures } == true
        }
        XCTAssertTrue(ready, "real root must install the window's paging recognizer and retained side controls")
        let pan = try XCTUnwrap(owned.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first { $0.delegate is PlateGestures })
        let gestures = try XCTUnwrap(pan.delegate as? PlateGestures)
        return (app, gestures, pan, try XCTUnwrap(views(owned).compactMap { $0 as? ToolbarLeftButton }.first),
                try XCTUnwrap(views(owned).compactMap { $0 as? ChromePlusControl }.first))
    }

    private func begin(_ gestures: PlateGestures, pan: UIPanGestureRecognizer, view: UIView, translation: CGPoint) throws {
        let owned = try XCTUnwrap(window)
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: owned)
        XCTAssertTrue(gestures.receive(at: point, touched: view, in: owned))
        XCTAssertTrue(pan.delegate === gestures)
        XCTAssertTrue(gestures.begin(translation: translation, velocity: .zero))
        gestures.follow(.began, translation: translation, velocity: .zero)
    }

    func testActualBackAndPlusStartTheSamePagingRecognizerWithoutTakingUnrelatedPageTouches() async throws {
        let (app, gestures, pan, back, plus) = try await host()
        let owned = try XCTUnwrap(window)
        XCTAssertTrue(pan.cancelsTouchesInView)
        XCTAssertFalse(pan.delaysTouchesBegan); XCTAssertFalse(pan.delaysTouchesEnded)
        XCTAssertEqual(pan.maximumNumberOfTouches, 1)
        for control in [back as UIView, plus as UIView] {
            let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: owned)
            XCTAssertTrue(gestures.receive(at: point, touched: control, in: owned))
            XCTAssertFalse(gestures.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()))
        }
        let outsider = UIView(frame: plus.convert(plus.bounds, to: owned)); owned.addSubview(outsider)
        XCTAssertFalse(gestures.receive(at: CGPoint(x: outsider.frame.midX, y: outsider.frame.midY), touched: outsider, in: owned))
        outsider.removeFromSuperview()
        app.chrome.setFolded(true)
        XCTAssertFalse(gestures.receive(at: plus.convert(.zero, to: owned), touched: plus, in: owned))
        app.chrome.setFolded(false)
        app.surfaces.settings = true
        XCTAssertFalse(gestures.receive(at: plus.convert(.zero, to: owned), touched: plus, in: owned))
    }

    func testCancelledSidePanPastTheCommitDistanceReturnsWithoutSelectingOrOpeningNewTab() async throws {
        let (app, gestures, pan, _, plus) = try await host()
        try begin(gestures, pan: pan, view: plus, translation: CGPoint(x: -200, y: 0))
        XCTAssertNotNil(app.surfaces.pageSwipe)
        XCTAssertEqual(app.surfaces.pageSwipe?.offset, -200)
        gestures.follow(.cancelled, translation: CGPoint(x: -240, y: 0), velocity: CGPoint(x: -1200, y: 0))
        XCTAssertNil(app.surfaces.pageSwipe); XCTAssertEqual(app.browser.tab?.id, "one")
        XCTAssertNil(app.surfaces.field)
        app.browser.select("two")
        try begin(gestures, pan: pan, view: plus, translation: CGPoint(x: -200, y: 0))
        XCTAssertNotNil(app.surfaces.pageSwipe); XCTAssertEqual(app.surfaces.pageSwipe?.offset, -200)
        gestures.follow(.failed, translation: CGPoint(x: -240, y: 0), velocity: .zero)
        XCTAssertEqual(app.browser.tab?.id, "two"); XCTAssertNil(app.surfaces.field)
        XCTAssertNil(app.surfaces.pageSwipe)
    }

    func testVerticalBackPansAndDownwardStackPansDoNotLiftSpacesPageOrSendTheirTap() async throws {
        let (app, gestures, pan, back, plus) = try await host()
        var backTaps = 0, plusTaps = 0
        back.onTap = { backTaps += 1 }; plus.onTap = { plusTaps += 1 }
        for (control, dy) in [(back as UIView, CGFloat(-200)), (back as UIView, 200), (plus as UIView, 200)] {
            try begin(gestures, pan: pan, view: control, translation: CGPoint(x: 0, y: dy))
            gestures.follow(.ended, translation: CGPoint(x: 0, y: dy), velocity: CGPoint(x: 0, y: dy * 3))
            XCTAssertNil(app.surfaces.pageSwipe)
            XCTAssertNil(app.surfaces.field); XCTAssertEqual(app.browser.tab?.id, "one")
            XCTAssertNil(TabStack.of(app).flick)
        }
        XCTAssertEqual(backTaps, 0); XCTAssertEqual(plusTaps, 0)
    }

    /// Up from the tab stack: the previous tab, and up again the one left,
    /// never the spaces, the field or the button's own tap.
    func testUpwardStackPansFlickToThePreviousTabAndBackWithoutTheirTap() async throws {
        let (app, gestures, pan, _, plus) = try await host()
        var plusTaps = 0
        plus.onTap = { plusTaps += 1 }
        XCTAssertEqual(TabStack.of(app).previous?.id, "two")
        try begin(gestures, pan: pan, view: plus, translation: CGPoint(x: 0, y: -30))
        XCTAssertNotNil(TabStack.of(app).flick)
        XCTAssertEqual(plus.stackView.lift, 30)
        gestures.follow(.changed, translation: CGPoint(x: 0, y: -90), velocity: CGPoint(x: 0, y: -400))
        gestures.follow(.ended, translation: CGPoint(x: 0, y: -90), velocity: CGPoint(x: 0, y: -400))
        XCTAssertEqual(app.browser.tab?.id, "two")
        XCTAssertNil(TabStack.of(app).flick)
        XCTAssertNil(app.surfaces.pageSwipe); XCTAssertNil(app.surfaces.field)
        let back = await until { TabStack.of(app).previous?.id == "one" }
        XCTAssertTrue(back, "the tab left is the stack's front card")
        try begin(gestures, pan: pan, view: plus, translation: CGPoint(x: 0, y: -120))
        gestures.follow(.ended, translation: CGPoint(x: 0, y: -120), velocity: .zero)
        XCTAssertEqual(app.browser.tab?.id, "one")
        // Short and slow, the card goes back and the tab stays.
        try begin(gestures, pan: pan, view: plus, translation: CGPoint(x: 0, y: -12))
        gestures.follow(.ended, translation: CGPoint(x: 0, y: -12), velocity: CGPoint(x: 0, y: -40))
        XCTAssertEqual(app.browser.tab?.id, "one")
        XCTAssertNil(TabStack.of(app).flick)
        XCTAssertEqual(plusTaps, 0)
    }

    func testCapturedSidePanRejectsChangedSpaceAndPrivateCurtainWithoutSelectingItsOldNeighbor() async throws {
        let (app, gestures, pan, _, plus) = try await host(privately: true)
        try begin(gestures, pan: pan, view: plus, translation: CGPoint(x: -20, y: 0))
        XCTAssertNotNil(app.surfaces.pageSwipe); XCTAssertEqual(app.surfaces.pageSwipe?.offset, -20)
        app.privateLock.willResignActive()
        XCTAssertTrue(app.privateContentBlocked)
        gestures.follow(.ended, translation: CGPoint(x: -240, y: 0), velocity: CGPoint(x: -1000, y: 0))
        XCTAssertEqual(app.browser.tab?.id, "one"); XCTAssertNil(app.surfaces.pageSwipe)
        app.privateLock.didBecomeActive()
        try begin(gestures, pan: pan, view: plus, translation: CGPoint(x: -20, y: 0))
        XCTAssertNotNil(app.surfaces.pageSwipe); XCTAssertEqual(app.surfaces.pageSwipe?.offset, -20)
        app.browser.showSpace("other")
        gestures.follow(.ended, translation: CGPoint(x: -240, y: 0), velocity: CGPoint(x: -1000, y: 0))
        XCTAssertEqual(app.browser.spaceID, "other"); XCTAssertEqual(app.browser.tab?.id, "other")
        XCTAssertNil(app.surfaces.pageSwipe); XCTAssertNil(app.surfaces.field)
    }

    func testFinishedSpringCannotSelectItsOldNeighborAfterTheCurrentSpaceChanges() async throws {
        let (app, _, _, _, _) = try await host()
        Motion.disabled = false
        let pager = Pager.of(app)
        XCTAssertFalse(Motion.reduced, "this case requires the actual native spring rather than a reduced-motion immediate completion")
        pager.start(); pager.follow(by: -200); pager.finish(-200, velocity: -600)
        XCTAssertNotNil(app.surfaces.pageSwipe, "the production spring must still own its asynchronous completion")
        app.browser.showSpace("other")
        let returned = await until { app.surfaces.pageSwipe == nil }
        XCTAssertTrue(returned)
        XCTAssertEqual(app.browser.spaceID, "other"); XCTAssertEqual(app.browser.tab?.id, "other")
        XCTAssertNil(app.surfaces.field)
    }
}
