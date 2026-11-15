import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Runs the real pool observer and chrome rule with deterministic UIKit
/// bottom anchoring while a swipe is still decelerating.
@MainActor
final class PageViewportFoldTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Motion.disabled = true
    }

    override func tearDown() {
        Motion.disabled = false
        super.tearDown()
    }

    func testOwnInsetChangesDuringDecelerationSettleAtBottom() throws {
        try exerciseBottom(contentHeight: 1400)
    }

    func testOwnInsetChangesSettleOnBarelyScrollablePage() throws {
        try exerciseBottom(contentHeight: 870)
    }

    /// Real WebKit: a full-height inner scroller whose content is a little
    /// taller than it. Our 29-point inset change resizes it and clamps its
    /// scrollTop at the bottom; the page script reports that as a scroll. It
    /// must not fold the chrome back and forth.
    func testInnerScrollerClampedByOurInsetsDoesNotFlipTheChromeAgain() async throws {
        let space = Space(id: "inner-loop", name: "Inner loop", emoji: "", tint: RGB(238, 233, 226))
        let app = AppModel(world: World(name: UUID().uuidString, space: space.id, spaces: [space]),
                           fixturesEnabled: false, privateLockEnabled: { false })
        let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: "about:blank")), id: "inner-loop.page")
        app.browser.open(tab)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932),
                             configuration: app.pages.configurationForPage(for: tab))
        let window = UIWindow(frame: view.frame)
        window.addSubview(view)
        window.isHidden = false
        XCTAssertTrue(app.pages.adopt(view, for: tab))
        XCTAssertTrue(app.pages.activate(tab) === view)
        defer { app.pages.forget(tab.id); window.isHidden = true }
        view.loadHTMLString("""
            <meta name='viewport' content='width=device-width,initial-scale=1'>
            <body style='margin:0;overflow:hidden'>
            <div id='s' style='position:fixed;inset:0;overflow:auto'><div style='height:calc(100vh + 400px)'>inner</div></div>
            </body>
            """, baseURL: nil)
        for _ in 0..<100 where view.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        func viewport(_ folded: Bool) -> PageViewport {
            PageViewport(size: view.bounds.size, hardware: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                         chrome: .init(folded: folded, hasNow: false, visible: true))
        }
        viewport(false).apply(to: view)
        try await Task.sleep(for: .milliseconds(900))
        var flips = 0
        let receive = try XCTUnwrap(app.pages.onScroll)
        app.pages.onScroll = { id, y in
            let wasFolded = app.chrome.folded
            receive(id, y)
            guard wasFolded != app.chrome.folded else { return }
            flips += 1
            if flips < 12 { viewport(app.chrome.folded).apply(to: view) }
        }
        _ = try await view.evaluateJavaScript("document.getElementById('s').scrollTop = 1e6; 0")
        try await Task.sleep(for: .seconds(3))
        XCTAssertLessThanOrEqual(flips, 1, "Folding once is the swipe; the clamp that follows our insets is not another")
        XCTAssertTrue(app.chrome.folded)
    }

    private func exerciseBottom(contentHeight: CGFloat) throws {
        let space = Space(id: "fold-loop", name: "Fold loop", emoji: "", tint: RGB(238, 233, 226))
        let app = AppModel(world: World(name: UUID().uuidString, space: space.id, spaces: [space]),
                           fixturesEnabled: false, privateLockEnabled: { false })
        let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: "about:blank")), id: "fold-loop.page")
        app.browser.open(tab)
        let view = BottomAnchoredPage(frame: CGRect(x: 0, y: 0, width: 430, height: 932),
                                      configuration: app.pages.configurationForPage(for: tab))
        view.drivenScroll.frame = view.bounds
        view.drivenScroll.contentSize = CGSize(width: 430, height: contentHeight)
        view.drivenScroll.contentInsetAdjustmentBehavior = .never
        XCTAssertTrue(app.pages.adopt(view, for: tab))
        XCTAssertTrue(app.pages.activate(tab) === view)
        defer { app.pages.forget(tab.id) }
        func viewport(_ folded: Bool) -> PageViewport {
            PageViewport(size: view.bounds.size, hardware: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                         chrome: .init(folded: folded, hasNow: false, visible: true))
        }
        XCTAssertEqual(viewport(false).current.bottom, 76)
        XCTAssertEqual(viewport(true).current.bottom, 47)
        viewport(false).apply(to: view)
        view.drivenScroll.contentOffset.y = view.drivenScroll.bottom - 10
        var flips = 0
        let receive = try XCTUnwrap(app.pages.onScroll)
        app.pages.onScroll = { id, y in
            let wasFolded = app.chrome.folded
            receive(id, y)
            guard wasFolded != app.chrome.folded else { return }
            flips += 1
            // A bounded substitute for SwiftUI's next PageHost update: a
            // broken baseline must fail the assertion, not hang XCTest.
            if flips < 12 { viewport(app.chrome.folded).apply(to: view) }
        }
        view.drivenScroll.simulatesDeceleration = true
        view.drivenScroll.contentOffset.y = view.drivenScroll.bottom
        XCTAssertEqual(flips, 1, "Our 76/47 inset writes must not feed a chrome fold loop")
        XCTAssertTrue(app.chrome.folded)
        for _ in 0..<10 { viewport(app.chrome.folded).apply(to: view) }
        XCTAssertEqual(flips, 1, "Repeated layout must settle")

        // The first real upward movement after rebasing still unfolds.
        view.drivenScroll.contentOffset.y -= 10
        XCTAssertFalse(app.chrome.folded, "A real upward scroll must still unfold the chrome")
        view.drivenScroll.contentOffset.y = -59
        XCTAssertFalse(app.chrome.folded, "The top still unfolds the chrome")
    }
}

@MainActor
private final class BottomAnchoredPage: WKWebView {
    let drivenScroll = BottomAnchoredScroll()
    override var scrollView: UIScrollView { drivenScroll }
}

@MainActor
private final class BottomAnchoredScroll: UIScrollView {
    var simulatesDeceleration = false
    override var isDecelerating: Bool { simulatesDeceleration }
    var bottom: CGFloat { max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom) }
    override var contentInset: UIEdgeInsets {
        didSet {
            guard simulatesDeceleration, contentInset != oldValue else { return }
            // Model the bottom offset correction made while WebKit changes
            // its viewport. This is not an additional finger movement.
            contentOffset.y += contentInset.bottom - oldValue.bottom
        }
    }
}
