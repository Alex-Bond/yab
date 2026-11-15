import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct InspectorOpeningTests {
    init() throws {
        try #require(Store.testing && Store.world != nil)
        _ = NSApplication.shared
    }

    @Test func openingWaitsForTheCardToEnterAWindow() async throws {
        try #require(Store.testing && Store.world != nil)
        let browser = Browser(windowID: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, bench: true, configuration: configuration)
        tab.restore(url: URL(string: "https://inspect-opening.example/")!, title: "Inspector opening")
        browser.lay([tab])
        browser.activeID = tab.id
        defer {
            browser.closeDevTools()
            tab.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        #expect(browser.inspectorDock.window == nil)
        var forwarded = false
        browser.openDevTools(.elements) { _, _ in forwarded = true }
        // The SwiftUI card is mounted later. Starting WebKit here lets a
        // warm frontend bring itself forward in a different (or no) window.
        #expect(browser.inspected == nil)
        #expect(!forwarded)
        browser.closeDevTools()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!browser.devOpen && !browser.devComing)
        #expect(browser.inspected == nil)
        #expect(!forwarded)
    }
}

@MainActor @Suite(.serialized)
struct InspectorClosingTests {
    init() throws {
        try #require(Store.testing && Store.world != nil)
        _ = NSApplication.shared
    }

    @Test func nativeCloseClearsCardDockAndDeviceAfterWebKitReturns() async throws {
        let browser = Browser(windowID: UUID())
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, bench: true, configuration: config)
        browser.lay([tab]); browser.activeID = tab.id
        let web = tab.webKitOnly("Inspector fixture")!
        let inspector = NSObject() // Not visible after WebKit's close stack returns.
        browser.inspected = tab
        browser.devOpen = true
        browser.inspectorDock.connectionStartedAt = 1
        tab.setDevice(DeviceMode(name: "Responsive", width: 400, height: 800), remember: false)
        let leftover = NSView()
        browser.inspectorDock.addSubview(leftover)
        defer {
            browser.closeDevTools(); tab.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        browser.willCloseLocalInspector(web, inspector: inspector)
        // No reentry while WebKit is still detaching its frontend.
        #expect(browser.inspected === tab)
        #expect(leftover.superview != nil)
        // Teardown schedules the docked card's departure on the next run-loop
        // frame. Under concurrent WebKit tests, resuming one fixed sleep can
        // precede that timer even though the native close callback has run.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (browser.devOpen || browser.devComing) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(browser.inspected == nil)
        #expect(!browser.devOpen && !browser.devComing)
        #expect(tab.device == nil)
        #expect(DeviceStage.scale(of: web) == 1)
        #expect(leftover.superview == nil)
    }

    @Test func detachedCloseNeverExposesADockedCardOrCompletesAPendingOpen() async throws {
        let browser = Browser(windowID: UUID())
        defer {
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        // A window closing while moveDev's opening turn is still queued.
        browser.devDetached = true
        browser.moveDev(open: true, side: .right)
        browser.devOpen = true
        browser.closeDevTools()
        #expect(!browser.devOpen && !browser.devDetached && !browser.devMoving)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!browser.devOpen && !browser.devDetached && !browser.devMoving)
        #expect(browser.devFloating.window == nil)
    }

    @Test func detachedWindowIsPreparedBeforeItCanAppear() throws {
        let browser = Browser(windowID: UUID())
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let frame = NSWindow(contentRect: page.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        frame.isReleasedWhenClosed = false
        browser.devDetached = true
        browser.devOpen = true
        defer {
            browser.closeDevTools()
            frame.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        browser.devFloating.prepare(page: page)
        frame.contentView?.addSubview(page)
        #expect(!frame.isVisible)
        #expect(frame.alphaValue == 0)
        #expect(frame.animationBehavior == .none)
        frame.title = "Web Inspector — test"
        #expect(frame.title == "Developer Tools")
    }

    @Test func delayedNativeCloseCannotTearDownANewerConnection() async throws {
        let browser = Browser(windowID: UUID())
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, bench: true, configuration: config)
        browser.lay([tab]); browser.activeID = tab.id
        let web = tab.webKitOnly("Inspector fixture")!
        let inspector = NSObject()
        browser.inspected = tab
        browser.devOpen = true
        browser.inspectorDock.connectionStartedAt = 1
        defer {
            browser.closeDevTools(); tab.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        browser.willCloseLocalInspector(web, inspector: inspector)
        browser.inspectorDock.connectionStartedAt = 2
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.inspected === tab && browser.devOpen)
        let other = WKWebView(frame: .zero, configuration: config)
        browser.willCloseLocalInspector(other, inspector: inspector)
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.inspected === tab && browser.devOpen)
    }
}
