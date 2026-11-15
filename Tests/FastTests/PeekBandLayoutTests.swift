import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PeekBandLayoutTests {
    @Test(arguments: [CGFloat(0), 8, 36])
    func bandAndViewportMeetUnderTheWindowTitlebar(topMargin: CGFloat) async throws {
        _ = NSApplication.shared
        let screen = try #require(TestScreen.screen)
        let browser = Browser(windowID: UUID())
        let previous = browser.prefs.peekAddress
        browser.prefs.peekAddress = true
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: "https://example.test/peek")!, title: "Peek page")
        browser.prepare(tab)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: content.frame.offsetBy(dx: screen.visibleFrame.minX + 40,
                                                                 dy: screen.visibleFrame.minY + 40),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = content
        let view = PeekView()
        view.frame = content.bounds.insetBy(dx: 0, dy: topMargin)
        view.depth.padding = [0, topMargin, 0, 0]
        view.browser = browser
        content.addSubview(view)
        window.orderFront(nil)
        defer {
            view.drop()
            window.orderOut(nil)
            window.contentView = nil
            tab.close()
            browser.prefs.peekAddress = previous
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        view.present(tab, shy: false, instant: true)
        content.layoutSubtreeIfNeeded()
        let panel = try #require(view.subviews.first { $0.subviews.contains { $0 is PageHolder } })
        let holder = try #require(panel.subviews.first { $0 is PageHolder } as? PageHolder)
        let band = try #require(holder.band)
        // A separately positioned band must not inset its SwiftUI content
        // for the window titlebar a second time. That content spills below
        // the reserved 36-point frame if the inherited safe area is applied.
        func caption(in view: NSView) -> NSView? {
            if view is ClickZone.Zone { return view }
            return view.subviews.lazy.compactMap { caption(in: $0) }.first
        }
        // Wait only for the fixture's representable to exist, never for
        // the geometry assertion to become true.
        for _ in 0..<200 {
            band.layoutSubtreeIfNeeded()
            if let text = caption(in: band), text.bounds.height > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        band.layoutSubtreeIfNeeded()
        let text = try #require(caption(in: band))
        let textFrame = band.convert(text.bounds, from: text)
        #expect(abs(textFrame.midY - band.bounds.midY) < 0.5)
        #expect(textFrame.minY >= band.bounds.minY)
        #expect(textFrame.maxY <= band.bounds.maxY)
        #expect(tab.page.superview === holder)
        #expect(tab.page.frame == holder.pageFrame)
        #expect(abs(tab.page.frame.maxY - band.frame.minY) < 0.001)
        #expect(abs(band.frame.maxY - holder.bounds.maxY) < 0.001)
        #expect(abs(band.frame.height - PeekBand.height) < 0.001)
        #expect(abs(panel.frame.maxY - view.bounds.maxY) <= Backdrop.inset)
    }
}
