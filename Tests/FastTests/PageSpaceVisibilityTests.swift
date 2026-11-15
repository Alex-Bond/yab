import AppKit
import Testing
import WebKit
@testable import Fast

/// A Space can replace the page branch while its new stage already has
/// its final frame. No later resize or tab selection should be needed to
/// put the selected page in the window (feedback #740, request #1188).
@Suite(.serialized)
@MainActor
struct PageSpaceVisibilityTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        return window
    }

    @Test func aPageSelectedBeforeItsStageJoinsTheWindowIsMountedAtOnce() throws {
        let window = window()
        let content = try #require(window.contentView)
        let stage = StageView(frame: content.bounds)
        stage.autoresizesSubviews = false
        let page = NSView(frame: content.bounds)
        let owner = UUID()
        stage.show(page, of: owner)
        #expect(page.superview == nil)
        content.addSubview(stage)
        // Intentionally no layoutSubtreeIfNeeded or repeated show here.
        #expect(stage.shows == owner)
        #expect(page.superview === stage)
        #expect(page.window === window)
        #expect(page.frame == stage.bounds)
    }

    @Test func aLoadedWebViewSelectedOffWindowJoinsItsStageWithoutAnotherTabSwitch() throws {
        let window = window()
        let content = try #require(window.contentView)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: content.bounds, configuration: configuration)
        let stage = StageView(frame: content.bounds)
        stage.autoresizesSubviews = false
        stage.show(page, of: UUID())
        content.addSubview(stage)
        #expect(page.superview === stage)
        #expect(page.window === window)
        #expect(page.frame == stage.bounds)
    }

    @Test func returningTheSameStageToAWindowRemountsItsSelectedPage() throws {
        let window = window()
        let content = try #require(window.contentView)
        let stage = StageView(frame: content.bounds)
        content.addSubview(stage)
        let page = NSView(frame: content.bounds)
        stage.show(page, of: UUID())
        stage.removeFromSuperview()
        page.removeFromSuperview()
        content.addSubview(stage)
        #expect(page.superview === stage)
        #expect(page.window === window)
    }

    @Test func aPageLentAwayIsNotReclaimedWhenItsOldStageJoinsAWindow() throws {
        let window = window()
        let content = try #require(window.contentView)
        let holder = NSView(frame: content.bounds)
        content.addSubview(holder)
        let page = NSView(frame: content.bounds)
        holder.addSubview(page)
        let stage = StageView(frame: content.bounds)
        stage.away = true
        stage.show(page, of: UUID())
        content.addSubview(stage)
        #expect(page.superview === holder)
    }
}
