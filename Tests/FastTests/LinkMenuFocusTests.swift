import AppKit
import Testing
import WebKit
@testable import Fast

// The existing menu target forwards into a real WK createWebView delegate.
// This is headless integration proof; the native tracked menu is checked by
// evals/link-background separately. No new production API is used here.
@Suite(.serialized) @MainActor
struct LinkMenuFocusTests {
    private let first = "http://127.0.0.1:9/menu-a"
    private let second = "http://127.0.0.1:9/script-b"

    private final class OriginalAction: NSObject {
        var run: (() -> Void)?
        var calls = 0
        var context: String?
        @objc func open(_ item: NSMenuItem) {
            calls += 1
            context = item.representedObject as? String
            run?()
        }
    }

    private func page() async throws -> (Browser, Tab) {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        // This fixture calls WK navigation/menu delegates directly.
        let source = Tab(shy: true, factory: .webKitOnly)
        browser.prepare(source)
        browser.lay([source])
        source.go(to: URL(string: "about:blank")!)
        requireNativeWebKitFixture(source, "LinkMenuFocusTests").configuration.preferences.inactiveSchedulingPolicy = .none
        #expect(!requireNativeWebKitFixture(source, "LinkMenuFocusTests").configuration.websiteDataStore.isPersistent)
        browser.activeID = source.id
        #expect(browser.tabs.count == 1 && browser.active === source)
        requireNativeWebKitFixture(source, "LinkMenuFocusTests").seenOffscreen = true
        requireNativeWebKitFixture(source, "LinkMenuFocusTests").loadHTMLString("<title>Source</title><p>Menu fixture</p>", baseURL: URL(string: "http://127.0.0.1:9/source"))
        for _ in 0..<200 {
            if !requireNativeWebKitFixture(source, "LinkMenuFocusTests").isLoading,
               (try? await requireNativeWebKitFixture(source, "LinkMenuFocusTests").evaluateJavaScript("document.title === 'Source' && document.readyState === 'complete'")) as? Bool == true { return (browser, source) }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.noDocument
    }

    private func stop(_ browser: Browser) {
        for tab in browser.tabs { tab.built?.stopLoading() }
        browser.letGo()
        if let id = browser.windowID {
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
    }

    private enum Failure: Error { case noDocument, noWindow }

    private func open(_ href: String, on source: Tab) {
        requireNativeWebKitFixture(source, "LinkMenuFocusTests").evaluateJavaScript("window.open('\(href)', '_blank'); true") { _, _ in }
    }

    private func added(to browser: Browser, after count: Int) async throws -> Tab {
        for _ in 0..<200 {
            if browser.tabs.count == count + 1, let last = browser.tabs.last {
                #expect(last.id != browser.tabs.first?.id)
                return last
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.noWindow
    }

    private func menu(on source: Tab, target: OriginalAction, link: String?, shift: Bool = false,
                      stale: Bool = false) async throws -> (NSMenu, NSEvent) {
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        if let link {
            _ = try await requireNativeWebKitFixture(source, "LinkMenuFocusTests").callAsyncJavaScript("window.webkit.messageHandlers.yabImages.postMessage({contextLink: link, contextAt: Date.now() - age}); return true",
                arguments: ["link": link, "age": stale ? 2000 : 0], in: nil, contentWorld: Web.world)
            try await Task.sleep(for: .milliseconds(25))
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Open Link in New Window", action: #selector(OriginalAction.open(_:)), keyEquivalent: "")
        item.target = target
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        item.representedObject = "original WebKit context"
        menu.addItem(item)
        requireNativeWebKitFixture(source, "LinkMenuFocusTests").willOpenMenu(menu, with: event)
        return (menu, event)
    }

    private func choose(_ menu: NSMenu, event: NSEvent, on source: Tab) {
        requireNativeWebKitFixture(source, "LinkMenuFocusTests").didCloseMenu(menu, with: event)
        menu.performActionForItem(at: 0)
    }

    @Test(arguments: [false, true])
    func nativeMenuKeepsSourceUnlessShift(shift: Bool) async throws {
        let (browser, source) = try await page()
        defer { stop(browser) }
        let target = OriginalAction()
        target.run = { open(first, on: source) }
        let (menu, event) = try await menu(on: source, target: target, link: first, shift: shift)
        browser.editing = true
        choose(menu, event: event, on: source)
        let destination = try await added(to: browser, after: 1)
        #expect(destination.address?.absoluteString == first)
        #expect(browser.activeID == (shift ? destination.id : source.id))
        #expect(browser.editing == !shift)
        #expect(target.calls == 1 && target.context == "original WebKit context")
    }

    @Test(arguments: ["different", "blank", "expired", "missing", "stale"])
    func absentOrUnmatchedMenuIntentLeavesScriptForeground(mode: String) async throws {
        let (browser, source) = try await page()
        defer { stop(browser) }
        let target = OriginalAction() // Original action accepted, but no window.
        let (menu, event) = try await menu(on: source, target: target, link: mode == "missing" ? nil : first, stale: mode == "stale")
        choose(menu, event: event, on: source)
        if mode == "expired" { try await Task.sleep(for: .milliseconds(1200)) }
        let href = mode == "different" ? second : mode == "blank" ? "about:blank" : first
        open(href, on: source)
        let destination = try await added(to: browser, after: 1)
        #expect(browser.activeID == destination.id)
        #expect(target.calls == 1)
    }

    @Test func repeatedMenuRetainsOriginalActionOnce() async throws {
        let (browser, source) = try await page()
        defer { stop(browser) }
        let target = OriginalAction()
        target.run = { open(first, on: source) }
        let (menu, event) = try await menu(on: source, target: target, link: first)
        let originalTarget = menu.items[0].target
        let originalAction = menu.items[0].action
        requireNativeWebKitFixture(source, "LinkMenuFocusTests").willOpenMenu(menu, with: event)
        #expect(menu.items[0].target === originalTarget && menu.items[0].action == originalAction)
        choose(menu, event: event, on: source)
        _ = try await added(to: browser, after: 1)
        #expect(target.calls == 1 && target.context == "original WebKit context")
        #expect(browser.activeID == source.id)
    }
}
