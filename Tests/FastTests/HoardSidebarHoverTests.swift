import AppKit
import Testing
@testable import Fast

/// Request #595: a layer-hidden sidebar's Downloads tracking must not
/// open files over the page. Exercise Hoard's real delayed hover path.
@MainActor @Suite(.serialized)
struct HoardSidebarHoverTests {
    private func world(shown: Bool, _ check: (Browser, ColumnView) async throws -> Void) async throws {
        let screen = try #require(TestScreen.screen)
        let windowID = UUID(), browser = Browser(windowID: windowID)
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut)
        prefs.sidebar = true
        prefs.sideShut = true
        browser.fullScreen = true
        browser.sidePeek = shown

        let frame = NSRect(x: screen.frame.minX + 32, y: screen.frame.minY + 32, width: 900, height: 650)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        window.contentView = root
        let column = ColumnView(browser: browser)
        column.frame = root.bounds
        root.addSubview(column)
        root.layoutSubtreeIfNeeded()
        column.slide(out: shown, animated: false)

        let hoard = browser.hoard
        hoard.watch(window)
        hoard.frames[.side] = CGRect(x: 8, y: 610, width: 28, height: 28)
        hoard.frames[.chip] = CGRect(x: 10, y: 610, width: 28, height: 28)
        hoard.pretend(name: "sidebar-hover-595.txt", from: "fixture.invalid", got: 1, total: 2)
        defer {
            hoard.hover(.side, false)
            hoard.openAt = nil
            hoard.stackWindow?.close()
            hoard.listWindow?.close()
            hoard.forgetPretended()
            window.close()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            prefs.sidebar = old.0
            prefs.sideShut = old.1
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
        }
        #expect(hoard.anything)
        #expect(column.shown == shown)
        try await check(browser, column)
    }

    @Test func hiddenFootCannotQueueFilesForTheNextEdgeReveal() async throws {
        try await world(shown: false) { browser, column in
            let hoard = browser.hoard
            // Native hover can still arrive while the drawing is offscreen.
            hoard.hover(.side, true)
            // Brim brings the column out before the files' dwell would end.
            browser.sidePeek = true
            column.slide(out: true, animated: false)
            try await Task.sleep(nanoseconds: 250_000_000)
            #expect(hoard.openAt == nil)
            #expect(hoard.stackWindow == nil)
        }
    }

    @Test func aFootThatHidesDuringTheDwellDoesNotOpenFiles() async throws {
        try await world(shown: true) { browser, column in
            let hoard = browser.hoard
            hoard.hover(.side, true)
            browser.sidePeek = false
            column.slide(out: false, animated: false)
            try await Task.sleep(nanoseconds: 250_000_000)
            #expect(hoard.openAt == nil)
            #expect(hoard.stackWindow == nil)
        }
    }

    @Test func visibleFootStillOpensFilesAndHiddenChipStillOpensItsList() async throws {
        try await world(shown: true) { browser, column in
            let hoard = browser.hoard
            hoard.hover(.side, true)
            try await Task.sleep(nanoseconds: 250_000_000)
            #expect(hoard.openAt == .side)
            #expect(hoard.stackWindow != nil)
            hoard.openAt = nil
            browser.sidePeek = false
            column.slide(out: false, animated: false)
            // The active-download chip uses its own place and click path.
            hoard.toggle(.chip)
            #expect(hoard.openAt == .chip)
            #expect(hoard.listWindow != nil)
        }
    }
}
