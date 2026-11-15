import AppKit
import Testing
import WebKit
@testable import Fast

/// A mouse's wheel over a page (rows 761 and 493, feedback #661: a Logitech
/// wheel would not scroll Netflix or yetanotherbrowser.com, a trackpad
/// would). Line notches and a smooth wheel's phaseless points, handed to the
/// page as AppKit hands them, scroll it whether or not the page listens to
/// the wheel, in a whole tab as in a bare WKWebView.
///
/// Until 9104fcc6 every tab carried a user style sheet with
/// `overscroll-behavior-y: none` on the root, and WebKit then scrolls no
/// phaseless wheel event on a page with a wheel listener that is not
/// passive (Netflix and our site have one): "tab listener" stood at 0 here
/// while the trackpad, which has phases, still scrolled.
@Suite(.serialized)
@MainActor
struct WheelNotchTests {
    private static let words = (0..<300).map { "<p style='margin:0;height:28px'>Line \($0)</p>" }.joined()

    private enum Page: String, CaseIterable {
        case plain, listener, nested
        var html: String {
            switch self {
            case .plain: return "<body style='margin:0'>\(WheelNotchTests.words)"
            // Hears every wheel, cancels none, as analytics and carousels do.
            case .listener: return "<body style='margin:0'>\(WheelNotchTests.words)<script>addEventListener('wheel', e => { window.seen = (window.seen || 0) + 1 }, {passive: false})</script>"
            case .nested: return "<style>html,body{margin:0;height:100%;overflow:hidden}#s{height:100%;overflow-y:auto}</style><body><div id=s>\(WheelNotchTests.words)</div><script>document.getElementById('s').addEventListener('wheel', () => {}, {passive: false})</script>"
            }
        }
    }

    /// Where the page is shown: a bare WKWebView, Yab's PageView with the
    /// scroll animator, or a whole private tab with all of Yab's scripts.
    private enum View: String, CaseIterable { case bare, page, tab }

    private var tabs: [Tab] = []

    private mutating func open(_ page: Page, in kind: View) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let web: WKWebView
        switch kind {
        case .bare:
            web = WKWebView(frame: frame, configuration: config)
        case .page:
            Web.smoothScrolling(config.preferences)
            let view = PageView(frame: frame, configuration: config)
            view.keepSeen = true
            view.seenOffscreen = true
            web = view
        case .tab:
            let tab = Tab(shy: true, configuration: Web.configuration(shy: true), factory: .webKitOnly)
            tabs.append(tab)
            requireNativeWebKitFixture(tab, "WheelNotchTests").keepSeen = true
            requireNativeWebKitFixture(tab, "WheelNotchTests").seenOffscreen = true
            web = requireNativeWebKitFixture(tab, "WheelNotchTests")
        }
        // On a screen: Yab's wheel glide (WheelGlide, 2e34483a5) sends a
        // notch on from its view's display link, which never ticks for a
        // window on no screen, so off at -30000 a PageView's notches stood
        // still while a bare WKWebView's scrolled.
        let room = TestScreen.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: room.minX, y: room.maxY - 600, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        web.loadHTMLString("<!doctype html><html>\(page.html)</html>", baseURL: URL(string: "https://wheel.example.test/"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" {
                try await Task.sleep(for: .milliseconds(300))
                return web
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        close(web)
        throw CocoaError(.fileReadUnknown)
    }

    private func close(_ web: WKWebView) {
        web.window?.orderOut(nil)
        web.window?.contentView = nil
    }

    /// One wheel event over the page's middle: `dy` lines, or points with
    /// `smooth`, no phase, as a mouse sends it.
    private func wheel(_ web: WKWebView, dy: Int32, smooth: Bool) {
        guard let window = web.window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: smooth ? .pixel : .line, wheelCount: 1,
                                  wheel1: dy, wheel2: 0, wheel3: 0) else { return }
        if smooth { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        let point = NSPoint(x: 400, y: 300)
        let screen = window.convertPoint(toScreen: point)
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
        typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") {
            unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: point.x, y: 600 - point.y))
        }
        guard let ns = NSEvent(cgEvent: event) else { return }
        web.scrollWheel(with: ns)
    }

    private func moved(_ web: WKWebView) async throws -> Int {
        let got = try await web.evaluateJavaScript("""
        Math.round(scrollY + (document.getElementById('s') ? document.getElementById('s').scrollTop : 0))
        """)
        return (got as? NSNumber)?.intValue ?? -1
    }

    private mutating func take(_ page: Page, in kind: View, smooth: Bool) async throws -> Int {
        let web = try await open(page, in: kind)
        defer { close(web) }
        for _ in 0..<3 {
            wheel(web, dy: smooth ? -40 : -1, smooth: smooth)
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(900))
        if let glide = (web as? PageView)?.glide {
            print("WheelNotchTests \(kind.rawValue) \(page.rawValue) smooth=\(smooth): notches \(glide.notches), events \(glide.events), passed \(glide.passed)")
        }
        return try await moved(web)
    }

    @Test(.enabled("needs a screen for the glide's display link") { await TestScreen.available }, arguments: [false, true])
    func notchesScrollEveryPage(smooth: Bool) async throws {
        var test = self
        defer { for tab in test.tabs { tab.close() } }
        var results: [String: Int] = [:]
        for page in Page.allCases {
            for kind in View.allCases {
                results["\(kind.rawValue) \(page.rawValue)"] = try await test.take(page, in: kind, smooth: smooth)
            }
        }
        print("WheelNotchTests smooth=\(smooth)", results.sorted { $0.key < $1.key })
        for (name, y) in results {
            #expect(y > 0, "\(name) stood still under \(smooth ? "a smooth wheel" : "line notches")")
        }
    }
}
