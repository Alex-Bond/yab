import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumPopupAnchorTests {
    @Test func picksThePressedCopyRatherThanHashTableOrder() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false,
                              screen: TestScreen.screen)
        window.isReleasedWhenClosed = false
        defer { window.close(); tab.close() }
        let content = try #require(window.contentView)
        let column = ChromiumPopupAnchor.View(tab: tab, id: "extension")
        let band = ChromiumPopupAnchor.View(tab: tab, id: "extension")
        column.frame = CGRect(x: 20, y: 20, width: 24, height: 24)
        band.frame = CGRect(x: 450, y: 150, width: 24, height: 24)
        content.addSubview(band)
        content.addSubview(column)
        let bandPoint = window.convertPoint(toScreen: band.convert(CGPoint(x: 12, y: 12), to: nil))
        let columnPoint = window.convertPoint(toScreen: column.convert(CGPoint(x: 12, y: 12), to: nil))
        for _ in 0..<20 {
            #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: window, at: bandPoint) === band)
            #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: window, at: columnPoint) === column)
        }
        band.alphaValue = 0
        #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: window, at: bandPoint) === column)
        column.isHidden = true
        #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: window, at: columnPoint) == nil)
    }

    @Test func offscreenSidebarCopyCannotAnchorAPopup() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false, screen: TestScreen.screen)
        window.isReleasedWhenClosed = false
        defer { window.close(); tab.close() }
        let content = try #require(window.contentView)
        let sidebar = ChromiumPopupAnchor.View(tab: tab, id: "extension")
        sidebar.frame = CGRect(x: -10_000, y: 20, width: 24, height: 24)
        let band = ChromiumPopupAnchor.View(tab: tab, id: "extension")
        band.frame = CGRect(x: 450, y: 150, width: 24, height: 24)
        content.addSubview(sidebar); content.addSubview(band)
        #expect(!sidebar.usable(in: window))
        #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: window) === band)
        band.isHidden = true
        #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: window) == nil)
    }

    @Test func anotherWindowAndEmptyAnchorCannotWin() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let windows = (0..<2).map { _ in NSWindow(contentRect: CGRect(x: 100, y: 100, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false, screen: TestScreen.screen) }
        for window in windows { window.isReleasedWhenClosed = false }
        defer { for window in windows { window.close() }; tab.close() }
        let first = ChromiumPopupAnchor.View(tab: tab, id: "extension")
        let other = ChromiumPopupAnchor.View(tab: tab, id: "extension")
        first.frame = CGRect(x: 10, y: 10, width: 24, height: 24)
        other.frame = first.frame
        windows[0].contentView?.addSubview(first)
        windows[1].contentView?.addSubview(other)
        let point = windows[0].convertPoint(toScreen: CGPoint(x: 20, y: 20))
        #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: windows[0], at: point) === first)
        first.frame.size = .zero
        #expect(ChromiumPopupAnchor.View.find(tab: tab, id: "extension", window: windows[0], at: point) == nil)
    }
}
