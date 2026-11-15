import XCTest
@testable import YabPhone

@MainActor
final class ChromeStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Motion.disabled = true
    }

    override func tearDown() {
        Motion.disabled = false
        super.tearDown()
    }

    func testSlowScrollFoldsAndUnfoldsTheChrome() {
        let chrome = ChromeState()
        for y in 0...100 { chrome.scrolled(to: CGFloat(y)) }
        XCTAssertTrue(chrome.folded, "Small WebKit samples still represent a downward swipe")
        for y in stride(from: 100, through: 90, by: -1) { chrome.scrolled(to: CGFloat(y)) }
        XCTAssertFalse(chrome.folded, "A slow upward swipe brings the buttons back")
    }

    func testLayoutRebasePreservesFoldAndResetsTheDirectionAnchor() {
        let chrome = ChromeState()
        chrome.scrolled(to: 100)
        chrome.rebaseScroll(by: -29)
        chrome.scrolled(to: 70)
        XCTAssertTrue(chrome.folded, "The inset correction is not an upward swipe")
        chrome.scrolled(to: 66)
        XCTAssertFalse(chrome.folded, "Real upward movement still unfolds")
        chrome.rebaseScroll(by: 29)
        chrome.scrolled(to: 100)
        XCTAssertTrue(chrome.folded, "Real downward movement still folds")
        chrome.rebaseScroll(by: -90)
        XCTAssertTrue(chrome.folded, "Layout near the top must not decide the fold")
        chrome.scrolled(to: 9)
        XCTAssertFalse(chrome.folded, "A real scroll at the top unfolds")
    }

    func testStationaryOuterViewportKeepsInnerScrollerDirection() {
        let chrome = ChromeState()
        chrome.scrolled(to: 500)
        chrome.rebaseScroll(by: 0)
        chrome.scrolled(to: 490)
        XCTAssertFalse(chrome.folded, "Viewport layout must not replace an inner scroller's position with zero")
    }

    /// The field crashes (0x8BADF00D): every fold moved the page's insets, the
    /// page reported a scroll the other way, and the chrome folded again,
    /// with no rebase to explain it. The guard must break any such loop.
    func testScrollThatKeepsFlippingTheChromeIsIgnoredForAWhile() {
        let chrome = ChromeState()
        var clock: TimeInterval = 100
        chrome.now = { clock }
        var flips = 0
        var last = chrome.folded
        for pass in 0..<10_000 {
            // The layout's answer to the previous fold, alternating.
            chrome.scrolled(to: pass % 2 == 0 ? 200 : 100)
            if chrome.folded != last { flips += 1; last = chrome.folded }
            clock += 0.0001
        }
        XCTAssertLessThanOrEqual(flips, ChromeState.flipLimit + 1, "A loop must run out of flips")
        // After the pause a person's swipe works again.
        clock += ChromeState.freeze + 1
        chrome.scrolled(to: 0)
        chrome.scrolled(to: 200)
        XCTAssertTrue(chrome.folded)
        clock += 0.5
        chrome.scrolled(to: 100)
        XCTAssertFalse(chrome.folded)
    }

    func testOrdinaryScrollingNeverHitsTheGuard() {
        let chrome = ChromeState()
        var clock: TimeInterval = 100
        chrome.now = { clock }
        for _ in 0..<20 {
            chrome.scrolled(to: 300); clock += 0.4
            chrome.scrolled(to: 200); clock += 0.4
        }
        XCTAssertFalse(chrome.folded)
        chrome.scrolled(to: 400)
        XCTAssertTrue(chrome.folded)
    }

    func testTrembleKeepsTheChromeFolded() {
        let chrome = ChromeState()
        chrome.scrolled(to: 100)
        for y in [101, 100, 99, 100, 102, 101, 100] { chrome.scrolled(to: CGFloat(y)) }
        XCTAssertTrue(chrome.folded)
        chrome.scrolled(to: 0)
        XCTAssertFalse(chrome.folded, "Returning to the top always unfolds")
    }
}
