import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Going back (Back/): where ‹ and the left edge lead, the pull's commit and
/// rubber band, the tab a link opened returning to its opener, and Undo
/// bringing a closed tab back where it stood, from the edge and the column.
@MainActor
final class BackStackTests: XCTestCase {
    private var oldDisabled = false
    private var window: UIWindow?
    private weak var previousKey: UIWindow?

    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }
    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil
        Motion.disabled = oldDisabled
    }

    private func mira() throws -> AppModel { AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false }) }

    /// Lisbon's Wikipedia in front, then Time Out opened from it by a link.
    private func openedByLink(_ app: AppModel) throws -> YabPhone.Tab {
        app.browser.select("lisbon-wiki")
        let tab = PageFixtures.tab(for: try XCTUnwrap(URL(string: "https://timeout.com")), in: app.world)
        app.browser.open(tab, in: "lisbon", deduplicate: false)
        app.backStack.opened(tab.id, by: "lisbon-wiki")
        XCTAssertEqual(app.browser.tab?.id, tab.id)
        return tab
    }

    private func firstPage(_ app: AppModel) { app.pageStateOverride = WebPool.PageState(canGoBack: false) }

    // MARK: - where Back leads

    func testTheRouteIsThePagesBackThenItsOpenerThenNothing() {
        XCTAssertEqual(BackRoute.decide(canGoBack: true, opener: "a"), .history)
        XCTAssertEqual(BackRoute.decide(canGoBack: true, opener: nil), .history)
        XCTAssertEqual(BackRoute.decide(canGoBack: false, opener: "a"), .opener("a"))
        XCTAssertEqual(BackRoute.decide(canGoBack: false, opener: nil), .nowhere)
    }

    func testAFirstPageGoesToItsOpenerAndAPageWithHistoryKeepsItsOwnBack() throws {
        let app = try mira()
        let child = try openedByLink(app)
        firstPage(app)
        XCTAssertEqual(app.backStack.route(for: app.browser.tab), .opener("lisbon-wiki"))
        XCTAssertTrue(app.backStack.mayPull, "at a first page the left edge is the pull's")
        app.pageStateOverride = WebPool.PageState(canGoBack: true)
        XCTAssertEqual(app.backStack.route(for: app.browser.tab), .history)
        XCTAssertFalse(app.backStack.mayPull, "with a Back of its own the edge is WebKit's swipe")
        app.pageStateOverride = WebPool.PageState(readerEnabled: true)
        XCTAssertEqual(app.backStack.route(for: app.browser.tab), .history, "Back leaves Reader first")
        // Not the tab in front: nowhere.
        firstPage(app)
        XCTAssertEqual(app.backStack.route(for: app.browser.tab("lisbon-wiki")), .nowhere)
        XCTAssertEqual(app.backStack.route(for: child), .opener("lisbon-wiki"))
    }

    func testEveryPageHasWebKitsOwnEdgeSwipe() throws {
        let app = try mira()
        let tab = try XCTUnwrap(app.browser.tab)
        XCTAssertTrue(app.pages.activate(tab).allowsBackForwardNavigationGestures, "a made page swipes back and forward")
        let other = try XCTUnwrap(app.browser.tab("work-hn"))
        let made = WKWebView(frame: .zero, configuration: app.pages.configurationForPage(for: other))
        XCTAssertFalse(made.allowsBackForwardNavigationGestures)
        XCTAssertTrue(app.pages.adopt(made, for: other))
        XCTAssertTrue(made.allowsBackForwardNavigationGestures, "an adopted page too")
    }

    func testEveryPageSwipesFromAnywhereWithWebKitsOwnSwipe() throws {
        let app = try mira()
        let tab = try XCTUnwrap(app.browser.tab)
        let view = app.pages.activate(tab)
        let swipe = try XCTUnwrap(SwipeAnywhere.of(view), "a made page swipes from anywhere")
        XCTAssertTrue(swipe.drivesWebKit, "UIKit's content swipe of WebKit's back and forward transitions is on")
        let other = try XCTUnwrap(app.browser.tab("work-hn"))
        let made = WKWebView(frame: .zero, configuration: app.pages.configurationForPage(for: other))
        XCTAssertNil(SwipeAnywhere.of(made))
        XCTAssertTrue(app.pages.adopt(made, for: other))
        XCTAssertNotNil(SwipeAnywhere.of(made), "an adopted page too")
        XCTAssertEqual(view.gestureRecognizers?.filter { $0.name?.hasPrefix("yab.swipeAnywhere") == true }.count, 3, "back, forward and the pull to the opener")
        XCTAssertTrue(app.backStack.maySwipeAnywhere)
        SettingsStore.shared.swipeAnywhere = false
        defer { SettingsStore.shared.swipeAnywhere = true }
        XCTAssertFalse(app.backStack.maySwipeAnywhere, "off, only the edges")
    }

    func testAScrollerThatCanStillMoveKeepsTheSwipe() {
        let scroller = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        scroller.contentSize = CGSize(width: 900, height: 100)
        XCTAssertFalse(SwipeAnywhere.canScroll(scroller, right: true), "at its start a right swipe is Back")
        XCTAssertTrue(SwipeAnywhere.canScroll(scroller, right: false))
        scroller.contentOffset.x = 600
        XCTAssertTrue(SwipeAnywhere.canScroll(scroller, right: true))
        XCTAssertFalse(SwipeAnywhere.canScroll(scroller, right: false), "at its end a left swipe is Forward")
        scroller.contentSize.width = 300
        XCTAssertFalse(SwipeAnywhere.canScroll(scroller, right: true), "a page as wide as the screen never holds it")
    }

    func testAnUnshownPageIsNeverClosedOnAGuess() throws {
        let app = try mira()
        _ = try openedByLink(app)
        // No override and no web view of its own yet: its Back is unknown.
        XCTAssertEqual(app.backStack.route(for: app.browser.tab), .nowhere)
        app.backStack.pullBegan()
        XCTAssertEqual(app.backStack.swipe?.kind, .nothing, "a pull only gives, it never closes")
        app.backStack.cancelPull(animated: false)
        XCTAssertNil(app.backStack.swipe)
    }

    func testTheOpenerCountsOnlyWhileItIsThereInTheSameSpaceAndPrivacy() throws {
        let app = try mira()
        let child = try openedByLink(app)
        XCTAssertEqual(app.backStack.opener(of: child.id), "lisbon-wiki")
        app.browser.move("lisbon-wiki", to: "work")
        XCTAssertNil(app.backStack.opener(of: child.id), "an opener moved to another space isn't behind this tab")
        app.browser.move("lisbon-wiki", to: "lisbon")
        XCTAssertEqual(app.backStack.opener(of: child.id), "lisbon-wiki")
        app.browser.close("lisbon-wiki")
        XCTAssertNil(app.backStack.opener(of: child.id), "a closed opener leaves nothing to go back to")
        firstPage(app)
        app.browser.select(child.id)
        XCTAssertEqual(app.backStack.route(for: app.browser.tab), .nowhere)
        app.backStack.opened("work-hn", by: "work-hn")
        XCTAssertNil(app.backStack.openers["work-hn"], "a tab is never its own opener")
    }

    // MARK: - back to the opener

    func testBackToTheOpenerClosesTheTabAndUndoBringsItBackInFront() throws {
        let app = try mira()
        let child = try openedByLink(app)
        firstPage(app)
        let felt = Haptics.played.count
        app.goBack()
        XCTAssertNil(app.browser.tab(child.id), "the tab a link opened closes")
        XCTAssertEqual(app.browser.tab?.id, "lisbon-wiki", "its opener comes in front")
        XCTAssertNil(app.backStack.swipe)
        let played = Haptics.played.dropFirst(felt).map { "\($0.kind.rawValue) \($0.reason)" }
        XCTAssertEqual(played, ["soft back to opener"], "one soft impact as the tab closes")
        XCTAssertNil(app.surfaces.toast, "a close says nothing")
        let closed = try XCTUnwrap(app.backStack.closed?.id)
        XCTAssertTrue(app.backStack.undo(closed))
        XCTAssertEqual(app.browser.tab?.id, child.id, "Undo brings it back in front")
        XCTAssertEqual(app.browser.space("lisbon")?.today.first?.id, child.id, "where it stood")
        XCTAssertEqual(app.backStack.opener(of: child.id), "lisbon-wiki", "and still knows where it came from")
        XCTAssertFalse(app.backStack.undo(closed))
        XCTAssertEqual(app.browser.space("lisbon")?.allTabs.filter { $0.id == child.id }.count, 1, "Undo works once")
    }

    func testAPullShortOfHalfSpringsBackAndPastHalfOrThrownGoesToTheOpener() throws {
        let app = try mira()
        let child = try openedByLink(app)
        firstPage(app)
        let stack = app.backStack
        stack.width = 402
        stack.pullBegan()
        XCTAssertEqual(stack.swipe?.kind, .opener("lisbon-wiki"))
        stack.pulled(by: 150)
        XCTAssertEqual(stack.swipe?.offset, 150, "the page follows the finger to its opener")
        stack.pullEnded(velocity: 100)
        XCTAssertNil(stack.swipe)
        XCTAssertEqual(app.browser.tab?.id, child.id, "let go before half: back in place")
        XCTAssertNil(app.surfaces.toast)

        stack.pullBegan()
        stack.pulled(by: 60)
        stack.pullEnded(velocity: 800)
        XCTAssertEqual(app.browser.tab?.id, "lisbon-wiki", "thrown: it goes")
        XCTAssertNil(app.browser.tab(child.id))

        let other = try openedByLink(app)
        firstPage(app)
        stack.pullBegan()
        stack.pulled(by: 230)
        stack.pullEnded(velocity: 0)
        XCTAssertEqual(app.browser.tab?.id, "lisbon-wiki", "past half: it goes")
        XCTAssertNil(app.browser.tab(other.id))
    }

    func testWithNothingBehindThePageGivesAgainstTheRubberBandAndSpringsBack() throws {
        let app = try mira()
        app.browser.select("lisbon-wiki")
        firstPage(app)
        let stack = app.backStack
        stack.width = 402
        XCTAssertEqual(stack.route(for: app.browser.tab), .nowhere)
        // Only the left edge of the page above the plate meets the pull.
        XCTAssertTrue(stack.mayPull(at: CGPoint(x: 6, y: 400), in: Metrics.screen))
        XCTAssertFalse(stack.mayPull(at: CGPoint(x: 120, y: 400), in: Metrics.screen), "the page's own touches")
        XCTAssertFalse(stack.mayPull(at: CGPoint(x: 6, y: 822), in: Metrics.screen), "the plate's swipes")
        stack.pullBegan()
        XCTAssertEqual(stack.swipe?.kind, .nothing)
        stack.pulled(by: 170)
        // iOS's rubber band, (1 - 1 / (x * 0.55 / W + 1)) * W: 170 in, 76 along.
        XCTAssertEqual(try XCTUnwrap(stack.swipe?.offset), (1 - 1 / (170 * 0.55 / 402 + 1)) * 402, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(stack.swipe?.offset), 76, accuracy: 1)
        stack.pullEnded(velocity: 3000)
        XCTAssertNil(stack.swipe)
        XCTAssertEqual(app.browser.tab?.id, "lisbon-wiki", "nothing behind: never a close")
        XCTAssertNil(app.surfaces.toast)
        // The reveal's pose with nothing behind: no card, the page's shadow only once it moves.
        let pose = BackPose(swipe: BackSwipe(kind: .nothing, tab: "lisbon-wiki", offset: 76), width: 402)
        XCTAssertEqual(pose.shadow, 1)
        XCTAssertEqual(pose.pageRadius, 0)
    }

    func testTheCardGrowsFromNinetyTwoPercentAsThePageLeaves() {
        let start = BackPose(swipe: BackSwipe(kind: .opener("a"), tab: "b", offset: 0), width: 402)
        XCTAssertEqual(start.cardScale, 0.92, accuracy: 0.0001)
        XCTAssertEqual(start.cardRadius, 40)
        XCTAssertEqual(start.cardDim, 0.18, accuracy: 0.0001)
        XCTAssertEqual(start.pageRadius, 0)
        XCTAssertEqual(start.shadow, 1)
        let third = BackPose(swipe: BackSwipe(kind: .opener("a"), tab: "b", offset: 134), width: 402)
        XCTAssertEqual(third.pageRadius, 40, accuracy: 0.01, "the page's corners are round by its first third")
        let half = BackPose(swipe: BackSwipe(kind: .opener("a"), tab: "b", offset: 201), width: 402)
        XCTAssertEqual(half.cardScale, 0.96, accuracy: 0.0001)
        XCTAssertEqual(half.cardRadius, 20, accuracy: 0.01)
        XCTAssertEqual(half.shadow, 0.8, accuracy: 0.0001)
        let gone = BackPose(swipe: BackSwipe(kind: .opener("a"), tab: "b", offset: 402), width: 402)
        XCTAssertEqual(gone.cardScale, 1)
        XCTAssertEqual(gone.cardRadius, 0)
        XCTAssertEqual(gone.cardDim, 0)
    }

    // MARK: - Undo after a close

    func testAColumnCloseIsQuietAndUndoPutsTheTabBackWithoutTakingTheFront() throws {
        let app = try mira()
        let front = app.browser.tab?.id
        let before = try XCTUnwrap(app.browser.space("work"))
        ColumnState.of(app).close("work-hn")
        XCTAssertNil(app.browser.tab("work-hn"))
        XCTAssertNil(app.surfaces.toast, "a close says nothing")
        XCTAssertTrue(app.backStack.undo(try XCTUnwrap(app.backStack.closed?.id)))
        XCTAssertEqual(app.browser.space("work")?.today.map(\.id), before.today.map(\.id), "back where it stood")
        XCTAssertEqual(app.browser.tab?.id, front, "a tab that wasn't in front stays behind")
    }

    func testClosingTheTabInFrontShowsNoToastAndUndoSelectsItAgain() throws {
        let app = try mira()
        app.browser.select("work-gh-pr")
        ColumnState.of(app).close("work-gh-pr")
        XCTAssertNotEqual(app.browser.tab?.id, "work-gh-pr")
        XCTAssertNil(app.surfaces.toast, "a close says nothing")
        XCTAssertTrue(app.backStack.undo(try XCTUnwrap(app.backStack.closed?.id)))
        XCTAssertEqual(app.browser.tab?.id, "work-gh-pr")
    }

    func testOnlyTheLastCloseIsUndoneAndAnIdInUseRefuses() throws {
        let app = try mira()
        let stack = app.backStack
        let first = try XCTUnwrap(stack.remember("work-hn"))
        app.browser.close("work-hn")
        stack.offer(first)
        let second = try XCTUnwrap(stack.remember("work-lumen"))
        app.browser.close("work-lumen")
        stack.offer(second)
        XCTAssertFalse(stack.undo(first.id), "a newer close took the toast")
        XCTAssertTrue(stack.undo(second.id))
        XCTAssertNotNil(app.browser.tab("work-lumen"))
        XCTAssertNil(app.browser.tab("work-hn"))
        // The same id back meanwhile (sync, another open): Undo refuses.
        let third = try XCTUnwrap(stack.remember("work-lumen"))
        let tab = try XCTUnwrap(app.browser.tab("work-lumen"))
        app.browser.close("work-lumen")
        stack.offer(third)
        app.browser.open(tab, in: "work", deduplicate: false)
        XCTAssertFalse(stack.undo(third.id))
        XCTAssertEqual(app.browser.allTabs.filter { $0.id == "work-lumen" }.count, 1)
    }

    func testReinsertPutsTodaysPinnedAndFolderTabsBackInTheirPlaces() throws {
        let app = try mira()
        let work = try XCTUnwrap(app.browser.space("work"))
        for id in ["work-gh-pr", "work-pin-linear", "work-onb-spec", "work-ledger"] {
            let tab = try XCTUnwrap(work.tab(id))
            let spot = try XCTUnwrap(BrowserStore.spot(of: id, in: work))
            app.browser.close(id)
            XCTAssertNil(app.browser.tab(id))
            XCTAssertTrue(app.browser.reinsert(tab, in: "work", at: spot))
            XCTAssertFalse(app.browser.reinsert(tab, in: "work", at: spot), "never twice")
            let now = try XCTUnwrap(app.browser.space("work"))
            XCTAssertEqual(now.today, work.today, id)
            XCTAssertEqual(now.pins, work.pins, id)
            XCTAssertEqual(now.kept, work.kept, id)
        }
        XCTAssertEqual(BrowserStore.spot(of: "work-onb-spec", in: work), .kept(folder: "work-onboarding", index: 1))
        XCTAssertEqual(BrowserStore.spot(of: "work-ledger", in: work), .kept(folder: nil, index: 2))
        // Its folder gone meanwhile: among the kept, where the folder was asked.
        var stray = try XCTUnwrap(work.tab("work-onb-spec"))
        stray.id = "stray"
        XCTAssertTrue(app.browser.reinsert(stray, in: "work", at: .kept(folder: "gone", index: 0)))
        XCTAssertEqual(app.browser.space("work")?.kept.first?.id, "tab:stray")
        stray.id = "stray-2"
        XCTAssertFalse(app.browser.reinsert(stray, in: "nowhere", at: .today(0)), "its space gone: nowhere to go back to")
    }

    func testTheToastsUndoRunsOnceAndAnOrdinaryToastTakesNoTouch() {
        let surfaces = Surfaces()
        var ran = 0
        surfaces.showToast("Closed figma.com", glyph: .crossMedium, place: .bottom, undo: { ran += 1 })
        let id = surfaces.toast!.id
        XCTAssertTrue(surfaces.toast!.undoable)
        surfaces.undoToast(UUID())
        XCTAssertEqual(ran, 0, "another toast's Undo does nothing")
        surfaces.undoToast(id)
        surfaces.undoToast(id)
        XCTAssertEqual(ran, 1)
        XCTAssertNil(surfaces.toast)
        surfaces.showToast("Link copied", glyph: .chainLink1)
        XCTAssertFalse(surfaces.toast!.undoable)
        surfaces.undoToast(surfaces.toast!.id)
        XCTAssertNotNil(surfaces.toast, "no Undo to run")
    }

    // MARK: - ‹ held

    func testTheWayBackIsTheTimelineNewestFirstWithTitlesAndSites() throws {
        let app = try mira()
        let tab = try XCTUnwrap(app.browser.tab)
        let entries: [BrowserNavigation.Entry] = [
            .init(url: "yab-page://wikipedia-lisbon", title: ""),
            .init(url: "https://www.timeout.com/lisbon", title: "Lisbon things"),
            .init(url: "https://example.org/", title: ""),
            .init(url: "yab-page://figma", title: "Onboarding v3 · Welcome screens"),
        ]
        app.pages.restoreClearMemory(WebPool.ClearMemory(navigation: BrowserNavigation(entries: entries, index: 3),
            interaction: nil, store: ObjectIdentifier(app.websiteDataStore), session: UUID(), isPrivate: false), for: tab.id)
        let list = app.pages.backList(tab.id)
        XCTAssertEqual(list.map(\.steps), [1, 2, 3])
        let rows = BackHistoryMenu.rows(list)
        XCTAssertEqual(rows.map(\.title), ["example.org", "Lisbon things", "Lisbon · Wikipedia"])
        XCTAssertEqual(rows.map(\.site), ["example.org", "timeout.com", "wikipedia.com"])
        let menu = BackHistoryMenu.make(rows, isPrivate: false) { _ in }
        XCTAssertEqual(menu.count, 1, "the pages are one section; All History comes after it")
        let section = try XCTUnwrap(menu.first as? UIMenu)
        XCTAssertTrue(section.options.contains(.displayInline))
        let actions = section.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["example.org", "Lisbon things", "Lisbon · Wikipedia"])
        XCTAssertEqual(actions.map(\.subtitle), ["example.org", "timeout.com", "wikipedia.com"])
        XCTAssertEqual(actions.map(\.identifier.rawValue), ["chrome.back.history.1", "chrome.back.history.2", "chrome.back.history.3"])
        XCTAssertTrue(actions.allSatisfy { $0.image != nil }, "an icon or the globe on every row")
        // The app's menu: the pages, then All History under a line.
        let full = app.backHistoryMenu(for: tab.id)
        XCTAssertEqual(full.count, 2)
        let last = try XCTUnwrap(full.last as? UIMenu)
        XCTAssertTrue(last.options.contains(.displayInline))
        let all = try XCTUnwrap(last.children.first as? UIAction)
        XCTAssertEqual(all.title, "All History")
        XCTAssertEqual(all.identifier.rawValue, BackHistoryMenu.allHistory)
        XCTAssertNotNil(all.image, "History's glyph")
        XCTAssertEqual((full.first as? UIMenu)?.children.count, 3)
    }

    // MARK: - the real ‹

    private func host() async throws -> (AppModel, ToolbarLeftButton) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(origin: .zero, size: Metrics.screen)
        window = owned
        let app = try mira()
        let host = UIHostingController(rootView: RootView().environment(app))
        host.safeAreaRegions = []
        owned.rootViewController = host
        owned.makeKeyAndVisible(); owned.layoutIfNeeded()
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let ready = await until { views(owned).contains { $0 is ToolbarLeftButton } }
        XCTAssertTrue(ready)
        return (app, try XCTUnwrap(views(owned).compactMap { $0 as? ToolbarLeftButton }.first))
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testBackDimsWithNowhereToGoAndSaysWhereItGoesOtherwise() async throws {
        let (app, back) = try await host()
        firstPage(app)
        let dimmed = await until { abs(back.foreground.alpha - Metrics.Back.dimmed) < 0.01 && !back.isEnabled }
        XCTAssertTrue(dimmed, "no Back and no opener: ‹ dimmed, \(back.foreground.alpha)")
        XCTAssertNil(back.menu)
        _ = try openedByLink(app)
        firstPage(app)
        let lit = await until { back.foreground.alpha > 0.99 && back.isEnabled }
        XCTAssertTrue(lit, "an opener: ‹ goes there")
        XCTAssertEqual(back.accessibilityHint, "Closes this tab and goes back to wikipedia.org")
        XCTAssertEqual(back.accessibilityCustomActions?.map(\.name), ["Back to wikipedia.org"])
        XCTAssertNil(back.menu, "no pages behind: no menu")
        let tab = try XCTUnwrap(app.browser.tab)
        app.pages.restoreClearMemory(WebPool.ClearMemory(navigation: BrowserNavigation(entries: [
            .init(url: "yab-page://wikipedia-lisbon", title: "Lisbon · Wikipedia"),
            .init(url: "yab-page://timeout", title: "The best things to do in Lisbon"),
        ], index: 1), interaction: nil, store: ObjectIdentifier(app.websiteDataStore), session: UUID(), isPrivate: false),
            for: tab.id)
        app.pageStateOverride = WebPool.PageState(canGoBack: true)
        let held = await until { back.menu != nil && back.accessibilityHint == nil }
        XCTAssertTrue(held, "a Back of its own: held, its pages")
        XCTAssertNil(back.accessibilityCustomActions)
    }
}
