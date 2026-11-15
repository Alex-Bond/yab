import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct PageFullScreenMoveTests {
    @MainActor
    private final class Room {
        let center = NotificationCenter()
        let host: NSWindow
        let source: NSWindow
        let move: PageFullScreenMove
        let web: WKWebView

        init(automatic: Bool = true, transparent: Bool = false) {
            _ = NSApplication.shared
            host = Self.window()
            source = Self.window()
            host.titlebarAppearsTransparent = transparent
            host.collectionBehavior = [.fullScreenPrimary, .managed]
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
            PageFullScreenMove.set(automatic, automaticOf: web)
            let fullScreenHost = host
            move = PageFullScreenMove(center: center, isWebKits: { $0 === fullScreenHost }, hasFullScreenWindow: { _ in true })
            move.start()
            move.start()
        }

        private static func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }

        func enter() {
            host.contentView?.addSubview(web)
            move.didMove(web)
            center.post(name: NSWindow.didBecomeKeyNotification, object: host)
        }

        func giveBack() {
            source.contentView?.addSubview(web)
            move.didMove(web)
        }

        func close() {
            move.close(web)
            web.removeFromSuperview()
            Tab.end(web)
            host.close()
            source.close()
        }
    }

    @Test func repeatedSessionsRestoreOnlyTheirOwnChanges() throws {
        let room = Room()
        defer { room.close() }
        let automatic = try #require(PageFullScreenMove.automatic(of: room.web))
        #expect(automatic)
        for _ in 0..<30 {
            room.enter()
            #expect(room.move.sessionCount == 1)
            #expect(room.host.titlebarAppearsTransparent)
            #expect(!room.host.collectionBehavior.contains(.fullScreenPrimary))
            #expect(PageFullScreenMove.automatic(of: room.web) == false)
            room.center.post(name: NSWindow.willEnterFullScreenNotification, object: room.host)
            #expect(room.host.collectionBehavior.contains(.fullScreenPrimary))
            room.center.post(name: NSWindow.didExitFullScreenNotification, object: room.host)
            // Keep the inset disabled until WebKit returns the page.
            #expect(PageFullScreenMove.automatic(of: room.web) == false)
            room.giveBack()
            #expect(PageFullScreenMove.automatic(of: room.web) == true)
            #expect(!room.host.titlebarAppearsTransparent)
            #expect(room.host.collectionBehavior == [.fullScreenPrimary, .managed])
            #expect(room.move.sessionCount == 0)
            #expect(room.host.contentView?.subviews.isEmpty == true)
            #expect(room.source.contentView?.subviews.count == 1)
            #expect(!room.host.ignoresMouseEvents && !room.source.ignoresMouseEvents)
        }
    }

    @Test func returningWithoutDidExitCleansUpAnInterruptedEntry() {
        let room = Room()
        defer { room.close() }
        room.enter()
        room.giveBack()
        #expect(room.move.sessionCount == 0)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(!room.host.titlebarAppearsTransparent)
        #expect(room.host.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test func anExitForAnotherWindowCannotReleaseTheLoan() {
        let room = Room()
        defer { room.close() }
        room.enter()
        room.center.post(name: NSWindow.didExitFullScreenNotification, object: room.source)
        #expect(room.move.sessionCount == 1)
        #expect(PageFullScreenMove.automatic(of: room.web) == false)
        #expect(room.host.titlebarAppearsTransparent)
        room.giveBack()
        #expect(room.move.sessionCount == 0)
    }

    @Test func aTransientDetachDuringANewEntryKeepsItsOwnLoan() {
        let room = Room()
        defer { room.close() }
        room.enter()
        room.center.post(name: NSWindow.didExitFullScreenNotification, object: room.host)
        room.giveBack()
        room.enter()
        // Detachment on the way in is not an exit. Only this session's
        // return, close or completed exit can give its settings back.
        room.web.removeFromSuperview()
        room.move.didMove(room.web)
        #expect(room.move.sessionCount == 1)
        #expect(PageFullScreenMove.automatic(of: room.web) == false)
        room.host.contentView?.addSubview(room.web)
        room.move.didMove(room.web)
        room.giveBack()
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(room.move.sessionCount == 0)
    }

    @Test func detachedPagesAndClosedHostsDoNotKeepALoan() {
        let room = Room()
        defer { room.close() }
        room.enter()
        room.web.removeFromSuperview()
        room.move.didMove(room.web)
        room.center.post(name: NSWindow.didExitFullScreenNotification, object: room.host)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(room.move.sessionCount == 0)
        room.enter()
        room.center.post(name: NSWindow.willCloseNotification, object: room.host)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(room.move.sessionCount == 0)
        #expect(!room.host.titlebarAppearsTransparent)
        #expect(room.host.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test func endingAPageRestoresItsLoanBeforeWebKitCloses() {
        let room = Room()
        defer { room.close() }
        room.enter()
        room.move.close(room.web)
        #expect(room.move.sessionCount == 0)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(!room.host.titlebarAppearsTransparent)
        #expect(room.host.collectionBehavior.contains(.fullScreenPrimary))
        room.move.close(room.web)
        #expect(room.move.sessionCount == 0)
    }


    @Test func reentryBeforeThePreviousReturnStartsAFreshLoan() {
        let room = Room()
        defer { room.close() }
        room.enter()
        room.center.post(name: NSWindow.didExitFullScreenNotification, object: room.host)
        room.center.post(name: NSWindow.willEnterFullScreenNotification, object: room.host)
        #expect(room.move.sessionCount == 1)
        #expect(room.host.titlebarAppearsTransparent)
        #expect(PageFullScreenMove.automatic(of: room.web) == false)
        room.giveBack()
        #expect(room.move.sessionCount == 0)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(!room.host.titlebarAppearsTransparent)
    }

    @Test func aReusedHostRestoresThePreviousPagesSettings() {
        let room = Room()
        defer { room.close() }
        room.enter()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let next = WKWebView(frame: .zero, configuration: config)
        PageFullScreenMove.set(true, automaticOf: next)
        defer { room.move.close(next); Tab.end(next) }
        room.web.removeFromSuperview()
        room.host.contentView?.addSubview(next)
        room.move.didMove(next)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(PageFullScreenMove.automatic(of: next) == false)
        #expect(room.move.sessionCount == 1)
        room.source.contentView?.addSubview(next)
        room.move.didMove(next)
        #expect(PageFullScreenMove.automatic(of: next) == true)
        #expect(!room.host.titlebarAppearsTransparent)
        #expect(room.move.sessionCount == 0)
    }

    @Test func fullscreenStateCompletionAlsoCleansUpADetachedPage() {
        let room = Room()
        defer { room.close() }
        room.enter()
        room.web.removeFromSuperview()
        room.move.didMove(room.web)
        // Deliver the read-only state's completion through the same KVO
        // channel WebKit uses, without a native full screen transition.
        room.web.willChangeValue(forKey: "fullscreenState")
        room.web.didChangeValue(forKey: "fullscreenState")
        #expect(room.move.sessionCount == 0)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
        #expect(!room.host.titlebarAppearsTransparent)
        #expect(room.host.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test func preexistingSettingsAndUnrelatedWindowStateArePreserved() {
        let room = Room(automatic: false, transparent: true)
        defer { room.close() }
        room.host.collectionBehavior = [.managed]
        room.host.ignoresMouseEvents = true
        room.enter()
        room.giveBack()
        #expect(PageFullScreenMove.automatic(of: room.web) == false)
        #expect(room.host.titlebarAppearsTransparent)
        #expect(room.host.collectionBehavior == [.managed])
        #expect(room.host.ignoresMouseEvents)
        #expect(room.move.sessionCount == 0)
    }

    // The matching rule: a loan belongs to one WebKit host window and one
    // page, by identity. Other windows, full screen or not, and other live
    // loans are never touched by its cleanup (register 1467).

    private static func page() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
        PageFullScreenMove.set(true, automaticOf: web)
        return web
    }

    private static func host() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        return window
    }

    @Test func otherWindowsCannotEndOrRestoreALiveLoan() {
        let room = Room()
        defer { room.close() }
        room.enter()
        // A browser window of Yab's own and a PiP or Small Window style
        // panel: neither is WebKit's host, so neither holds a loan.
        let browser = Self.host()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let panelWeb = Self.page()
        panel.contentView?.addSubview(panelWeb)
        room.move.didMove(panelWeb)
        defer { panelWeb.removeFromSuperview(); Tab.end(panelWeb); browser.close(); panel.close() }
        for other in [browser, panel as NSWindow] {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.willEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification] {
                room.center.post(name: name, object: other)
            }
        }
        #expect(room.move.sessionCount == 1)
        #expect(room.move.isLending(room.host))
        #expect(!room.move.isLending(browser) && !room.move.isLending(panel))
        #expect(PageFullScreenMove.automatic(of: room.web) == false)
        #expect(room.host.titlebarAppearsTransparent)
        #expect(!browser.titlebarAppearsTransparent && !panel.titlebarAppearsTransparent)
        #expect(browser.collectionBehavior == [.fullScreenPrimary, .managed])
        #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
        #expect(PageFullScreenMove.automatic(of: panelWeb) == true)
        room.giveBack()
        #expect(room.move.sessionCount == 0)
        #expect(PageFullScreenMove.automatic(of: room.web) == true)
    }

    @Test func twoLiveLoansEndOnlyTheirOwn() {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let first = Self.host(), second = Self.host(), source = Self.host()
        let one = Self.page(), two = Self.page()
        let move = PageFullScreenMove(center: center, isWebKits: { $0 === first || $0 === second },
                                      hasFullScreenWindow: { _ in true })
        move.start()
        defer {
            for web in [one, two] { move.close(web); web.removeFromSuperview(); Tab.end(web) }
            for window in [first, second, source] { window.close() }
        }
        // Two tabs, or two Yab windows, each with a page in full screen,
        // on their own Spaces or displays.
        first.contentView?.addSubview(one)
        move.didMove(one)
        center.post(name: NSWindow.didBecomeKeyNotification, object: first)
        second.contentView?.addSubview(two)
        move.didMove(two)
        center.post(name: NSWindow.didBecomeKeyNotification, object: second)
        #expect(move.sessionCount == 2)
        #expect(move.isLending(first) && move.isLending(second))
        #expect(!second.collectionBehavior.contains(.fullScreenPrimary))

        // The first ends and its page goes home; the second stays as it was.
        center.post(name: NSWindow.didExitFullScreenNotification, object: first)
        source.contentView?.addSubview(one)
        move.didMove(one)
        // Its tab's window takes the keyboard back, which prunes.
        center.post(name: NSWindow.didBecomeKeyNotification, object: source)
        #expect(move.sessionCount == 1)
        #expect(!move.isLending(first) && move.isLending(second))
        #expect(PageFullScreenMove.automatic(of: one) == true)
        #expect(!first.titlebarAppearsTransparent)
        #expect(PageFullScreenMove.automatic(of: two) == false)
        #expect(second.titlebarAppearsTransparent)
        #expect(!second.collectionBehavior.contains(.fullScreenPrimary))

        // Closing the first page's tab leaves the second's loan too.
        move.close(one)
        #expect(move.isLending(second))
        center.post(name: NSWindow.willCloseNotification, object: first)
        #expect(move.isLending(second))

        center.post(name: NSWindow.didExitFullScreenNotification, object: second)
        source.contentView?.addSubview(two)
        move.didMove(two)
        #expect(move.sessionCount == 0)
        #expect(PageFullScreenMove.automatic(of: two) == true)
        #expect(!second.titlebarAppearsTransparent)
        #expect(second.collectionBehavior == [.fullScreenPrimary, .managed])
    }
}
