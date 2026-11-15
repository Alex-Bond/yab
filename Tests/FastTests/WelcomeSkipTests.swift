import AppKit
import XCTest
@testable import Fast

@MainActor
final class WelcomeSkipTests: XCTestCase {
    func testEveryReplayBeatKeepsTheSkipControlInTheSameCorner() throws {
        _ = NSApplication.shared
        let chrome = WelcomeChromeView()
        let window = try host(chrome, size: CGSize(width: 1180, height: 780))
        defer { window.orderOut(nil) }
        var pinned: CGRect?
        for beat in WelcomeStage.Beat.allCases {
            let frame: WelcomeWords.Frame = beat == .welcome ? .welcome : beat == .finish ? .finish : .chapter
            chrome.show(WelcomeChrome(words: WelcomeWords(frame: frame), skip: true), animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            chrome.layoutSubtreeIfNeeded()
            let rect = try XCTUnwrap(chrome.skipFrame)
            XCTAssert(rect.width > 0 && rect.height > 0, "\(beat): \(rect)")
            XCTAssert(rect.maxX == 1180 - (WelcomeChromeView.lightsAt - Lights.lead))
            XCTAssert(rect.midY == Metrics.strip / 2)
            if let pinned { XCTAssert(rect == pinned) }
            pinned = rect
            // Unlike the footer, it takes a press even before the intro's button arrives.
            let point = chrome.convert(CGPoint(x: rect.midX, y: rect.midY), to: chrome.superview)
            XCTAssert(chrome.hitTest(point) != nil, "\(beat): \(rect)")
        }
    }

    func testFirstRunHasNoNewControlAndResizingKeepsTheReplayControlPinned() throws {
        _ = NSApplication.shared
        let chrome = WelcomeChromeView()
        let window = try host(chrome, size: CGSize(width: 1000, height: 700))
        defer { window.orderOut(nil) }
        chrome.show(WelcomeChrome(), animated: false)
        chrome.layoutSubtreeIfNeeded()
        XCTAssert(chrome.skipFrame == nil)
        chrome.show(WelcomeChrome(skip: true, menuDown: 20), animated: false)
        chrome.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        chrome.layoutSubtreeIfNeeded()
        let rect = try XCTUnwrap(chrome.skipFrame)
        XCTAssert(rect.width > 0 && rect.height > 0, "\(rect)")
        XCTAssert(rect.maxX == 1000 - (WelcomeChromeView.lightsAt - Lights.lead))
        XCTAssert(rect.midY == 20 + Metrics.strip / 2)
    }

    private func host(_ chrome: WelcomeChromeView, size: CGSize) throws -> NSWindow {
        let screen = try XCTUnwrap(TestScreen.screen)
        let window = NSWindow(contentRect: CGRect(origin: screen.visibleFrame.origin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        window.orderFront(nil)
        return window
    }
}
