import AppKit
import Testing
import WebKit
@testable import Fast

// Explicit navigation metadata drives the actual Browser delegates and tab
// state. This fixture does not assert that WebKit produced those modifiers
// from a native click; that requires the separate HTML/input eval.
@Suite(.serialized) @MainActor
struct ModifiedLinkFocusTests {
    enum Click: String, CaseIterable, Sendable {
        case command, middle, shiftCommand, shiftMiddle

        var flags: NSEvent.ModifierFlags {
            switch self {
            case .command: .command
            case .middle: []
            case .shiftCommand: [.command, .shift]
            case .shiftMiddle: .shift
            }
        }

        // WKNavigationAction uses a mask: 4 is the middle button.
        var button: Int { self == .middle || self == .shiftMiddle ? 4 : 1 }
        var foreground: Bool { self == .shiftCommand || self == .shiftMiddle }
    }

    enum Kind: String, CaseIterable, Sendable {
        case link, script
        var navigation: WKNavigationType { self == .link ? .linkActivated : .other }
    }

    enum Source: String, Sendable { case ordinary, pinned, kept }

    /// Every property the delegates read is supplied explicitly. In
    /// particular, WindowGate never reads an uninitialized WebKit frame or
    /// private action payload from this metadata-only fixture.
    private final class Action: WKNavigationAction {
        let destination: URL
        let kind: Kind
        let flags: NSEvent.ModifierFlags
        let button: Int

        init(_ destination: URL, kind: Kind, flags: NSEvent.ModifierFlags = [], button: Int = 1) {
            self.destination = destination
            self.kind = kind
            self.flags = flags
            self.button = button
            super.init()
        }

        override var request: URLRequest { URLRequest(url: destination) }
        override var navigationType: WKNavigationType { kind.navigation }
        override var modifierFlags: NSEvent.ModifierFlags { flags }
        override var buttonNumber: Int { button }
        override var targetFrame: WKFrameInfo? { nil }
        override var shouldPerformDownload: Bool { false }

        @objc(_isUserInitiated) func userInitiated() -> Bool { true }

        override func value(forKey key: String) -> Any? {
            if key == "sourceFrame" { return nil }
            return super.value(forKey: key)
        }
    }

    private func withSource(_ kind: Source = .ordinary,
                            _ check: (Browser, Tab) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        defer {
            for tab in browser.tabs + browser.outside { tab.built?.stopLoading() }
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        // This fixture calls WK navigation/menu delegates directly.
        let source = Tab(shy: true, factory: .webKitOnly)
        browser.prepare(source)
        browser.lay([source])
        source.go(to: URL(string: "about:blank")!)
        if kind == .pinned { source.pin = "S" }
        if kind == .kept { source.kept = true }
        browser.activeID = source.id
        browser.editing = true
        #expect(!source.bench && source.shy)
        #expect(browser.tabs.count == 1 && browser.active === source)
        try check(browser, source)
    }

    private func opened(in browser: Browser, from source: Tab, url: URL, foreground: Bool) throws -> Tab {
        #expect(browser.tabs.count == 2)
        let destination = try #require(browser.tabs.first { $0 !== source })
        #expect(destination.address == url)
        #expect(destination.shy)
        #expect(destination.linkedFrom == source.id)
        #expect(browser.tabs.map(\.id) == [source.id, destination.id])
        #expect(browser.activeID == (foreground ? destination.id : source.id))
        #expect(browser.editing == !foreground)
        #expect(source.address?.absoluteString == "about:blank")
        #expect(browser.peeking == nil)
        return destination
    }

    @Test(arguments: Click.allCases)
    func modifiedNavigationPolicyOpensBesideAndCancelsTheOriginal(click: Click) throws {
        try withSource { browser, source in
            let url = URL(string: "http://127.0.0.1:9/policy-\(click.rawValue)")!
            let action = Action(url, kind: .link, flags: click.flags, button: click.button)
            var decisions: [WKNavigationActionPolicy] = []
            let delegate = try #require(requireNativeWebKitFixture(source, "ModifiedLinkFocusTests").navigationDelegate)
            delegate.webView?(requireNativeWebKitFixture(source, "ModifiedLinkFocusTests"), decidePolicyFor: action) { decisions.append($0) }
            #expect(decisions == [.cancel])
            _ = try opened(in: browser, from: source, url: url, foreground: click.foreground)
        }
    }

    private func create(_ browser: Browser, from source: Tab, action: Action) {
        let configuration = requireNativeWebKitFixture(source, "ModifiedLinkFocusTests").configuration.copy() as! WKWebViewConfiguration
        _ = browser.webView(requireNativeWebKitFixture(source, "ModifiedLinkFocusTests"), createWebViewWith: configuration,
                            for: action, windowFeatures: WKWindowFeatures())
    }

    @Test(arguments: Kind.allCases, Click.allCases)
    func modifiedNewWindowActionPreservesItsRequestedFocus(kind: Kind, click: Click) throws {
        try withSource { browser, source in
            let url = URL(string: "http://127.0.0.1:9/create-\(kind.rawValue)-\(click.rawValue)")!
            create(browser, from: source, action: Action(url, kind: kind, flags: click.flags, button: click.button))
            let destination = try opened(in: browser, from: source, url: url, foreground: click.foreground)
            #expect(destination.opener == source.id)
        }
    }

    @Test(arguments: [Source.pinned, .kept], Click.allCases)
    func modifiedNewWindowFromPinnedOrKeptSourceOpensATab(sourceKind: Source, click: Click) throws {
        try withSource(sourceKind) { browser, source in
            let url = URL(string: "http://127.0.0.1:9/kept-\(sourceKind.rawValue)-\(click.rawValue)")!
            create(browser, from: source, action: Action(url, kind: .link, flags: click.flags, button: click.button))
            let destination = try opened(in: browser, from: source, url: url, foreground: click.foreground)
            #expect(destination.opener == source.id)
            #expect(source.pin != nil || source.kept)
        }
    }

    @Test(arguments: Kind.allCases)
    func unmodifiedNewWindowStillSelectsItsDestination(kind: Kind) throws {
        try withSource { browser, source in
            let url = URL(string: "http://127.0.0.1:9/plain-\(kind.rawValue)")!
            create(browser, from: source, action: Action(url, kind: kind))
            _ = try opened(in: browser, from: source, url: url, foreground: true)
        }
    }
}
