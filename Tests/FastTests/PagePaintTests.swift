import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct PagePaintTests {
    private final class BusySignal: NSObject, WKScriptMessageHandler {
        var started = false
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            started = true
        }
    }

    /// The old test inspected only the eventual picture. Block the real
    /// content process and observe the transition after its old 140 ms
    /// timer; cancellation and lending must also survive the delayed reply.
    @Test(arguments: ["ready", "return", "replace", "transfer", "detach"])
    func busyPageKeepsItsDepartingSurface(until action: String) async throws {
        let signal = BusySignal()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(signal, name: "paintBusy")
        try #require(PagePaint.configure(configuration))
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "paintBusy") }
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let web = WKWebView(frame: frame, configuration: configuration)
        let stage = StageView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        // Layer-backed now, as WebStage's `round` makes it before its first
        // show, not at a window display the other suites may put off.
        stage.wantsLayer = true
        window.orderFront(nil)
        defer { window.close() }
        let webID = UUID(), oldID = UUID()
        stage.show(web, of: webID)
        web.loadHTMLString("<body style='background:#20b060;height:1800px'><input id='draft' value='kept'><script>window.token='retained'</script></body>", baseURL: nil)
        _ = try await Loaded.until(30) {
            (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!window.token")) as? Bool == true
        }
        try #require(try await web.evaluateJavaScript("window.token") as? String == "retained")
        _ = try await web.evaluateJavaScript("scrollTo(0,250);true")
        _ = try await web.takeSnapshot(configuration: nil)
        let old = NSView(frame: frame)
        old.wantsLayer = true
        old.layer?.backgroundColor = NSColor.blue.cgColor
        stage.show(old, of: oldID)
        _ = try await Loaded.until(10) { web.window == nil }
        try #require(web.window == nil)

        // The page's busy loop begins no sooner than it is asked for, so it
        // lasts at least until 0.9 s after this.
        let asked = CACurrentMediaTime()
        let busy = Task {
            try await web.evaluateJavaScript("window.webkit.messageHandlers.paintBusy.postMessage('started'); const end=performance.now()+900; while(performance.now()<end){}; true") as? Bool
        }
        _ = try await Loaded.until(10, every: .milliseconds(5)) { signal.started }
        try #require(signal.started)
        stage.show(web, of: webID)
        try await Task.sleep(for: .milliseconds(225))
        // A duplicate SwiftUI update cannot discard the departing picture.
        stage.show(web, of: webID)
        #expect(web.superview === stage)
        // Only while the page is surely still busy: a run loaded by other
        // suites can wake past the busy loop (0.9 s) or the paint wait
        // (1 s), and then the page has rightly been shown and the page
        // left let go. Counted from the ask, not from the show: the
        // page's word that it began reaches a main thread held by other
        // suites late, the loop already running (in the N-Z shard on
        // adhd the page was in, old page gone, well inside 0.6 s of the
        // show, which this counted from).
        let center = stage.convert(NSPoint(x: stage.bounds.midX, y: stage.bounds.midY), to: stage.superview)
        if CACurrentMediaTime() - asked < 0.6 {
            #expect(old.superview === stage)
            #expect(web.layer?.opacity == 0)
            #expect(stage.hitTest(center) === stage)
        }

        let third = NSView(frame: frame)
        third.wantsLayer = true
        let borrowed = NSView(frame: frame)
        let second = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        defer { second.close() }
        switch action {
        case "return": stage.show(old, of: oldID)
        case "replace": stage.show(third, of: UUID())
        case "transfer":
            second.contentView = borrowed
            second.orderFront(nil)
            borrowed.addSubview(web)
            stage.away = true
            stage.show(web, of: webID)
            #expect(web.layer?.opacity == 1)
        case "detach":
            window.contentView = NSView(frame: frame)
            #expect(web.layer?.opacity == 1)
        default: break
        }
        #expect(try await busy.value == true)
        // Drawn: the page in, and what it stood behind gone.
        _ = try await Loaded.until(15) {
            guard web.layer?.opacity == 1 else { return false }
            switch action {
            case "return": return web.superview == nil
            case "replace": return web.superview == nil
            case "ready": return old.superview == nil
            default: return true
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(web.layer?.opacity == 1)
        switch action {
        case "return":
            #expect(old.superview === stage && web.superview == nil)
            #expect(old.layer?.opacity == 1)
        case "replace":
            #expect(third.superview === stage && web.superview == nil)
        case "transfer":
            #expect(web.superview === borrowed)
            #expect(!(web.layer?.animationKeys() ?? []).contains { $0.hasPrefix("turn.") })
        case "detach": #expect(stage.window == nil)
        default:
            #expect(web.superview === stage && old.superview == nil)
            let hit = try #require(stage.hitTest(center))
            #expect(hit === web || hit.isDescendant(of: web))
            let image = try await web.takeSnapshot(configuration: nil)
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(color.greenComponent > 0.5 && color.redComponent < 0.3)
        }
        #expect(try await web.evaluateJavaScript("window.token + ':' + document.getElementById('draft').value + ':' + scrollY") as? String == "retained:kept:250")
    }

    /// Answers nothing until told to: a page whose first document has not
    /// arrived yet, as any page opened from the field is for a while.
    private final class SlowScheme: NSObject, WKURLSchemeHandler {
        var task: (any WKURLSchemeTask)?
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) { self.task = task }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { self.task = nil }
        func answer() {
            guard let task, let url = task.request.url else { return }
            let body = Data("<body style='background:#20b060'></body>".utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: body.count, textEncodingName: "utf-8"))
            task.didReceive(body)
            task.didFinish()
            self.task = nil
        }
    }

    /// A page opened while loading: the page left goes within the stage's
    /// paint wait, however long the site takes (StageView.paintWait,
    /// e62d59e5), and the page coming stays unseen over the stage's ground
    /// until it has drawn, never WebKit's white (feedback #205).
    @Test func loadingPageDoesNotKeepThePageLeft() async throws {
        let scheme = SlowScheme()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "slow")
        try #require(PagePaint.configure(configuration))
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let stage = StageView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFront(nil)
        defer { window.close() }
        let old = NSView(frame: frame)
        old.wantsLayer = true
        old.layer?.backgroundColor = NSColor.blue.cgColor
        stage.show(old, of: UUID())
        let web = WKWebView(frame: frame, configuration: configuration)
        web.load(URLRequest(url: URL(string: "slow://site/")!))
        for _ in 0..<200 {
            if scheme.task != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(scheme.task != nil)
        stage.show(web, of: UUID())
        let shown = CACurrentMediaTime(), punctual = Punctuality()
        defer { punctual.stop() }
        // The page left gone without the document ever arriving; within
        // the paint wait where the Mac kept time.
        _ = try await Loaded.until(StageView.paintWait + 10) { old.superview == nil }
        #expect(old.superview == nil)
        if punctual.held() { #expect(CACurrentMediaTime() - shown < StageView.paintWait + 0.3) }
        #expect(scheme.task != nil)
        // Not drawn yet: unseen, the stage's own ground in its place.
        #expect(web.layer?.opacity == 0)
        #expect(stage.layer?.backgroundColor != nil)
        let center = stage.convert(NSPoint(x: stage.bounds.midX, y: stage.bounds.midY), to: stage.superview)
        #expect(stage.hitTest(center) !== stage)
        // Seen once it has drawn, well before `groundWait`.
        scheme.answer()
        let answered = CACurrentMediaTime()
        // Its commit, as Browser's didCommit tells the stage.
        _ = try await Loaded.until(5) { web.backForwardList.currentItem != nil }
        stage.documentCommitted(web)
        _ = try await Loaded.until(StageView.groundWait + 5) { web.layer?.opacity == 1 }
        #expect(web.layer?.opacity == 1)
        if punctual.held() { #expect(CACurrentMediaTime() - answered < StageView.groundWait - 1) }
    }

    /// A tab just opened in front (Browser.open, StageView.willOpen) is in
    /// at once: the page left goes within the stage's turn, not when the
    /// site answers, and WebKit's white ground stays off until the page has
    /// drawn (feedback #206).
    @Test func openedTabIsInAtOnce() async throws {
        let scheme = SlowScheme()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "slow")
        try #require(PagePaint.configure(configuration))
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let stage = StageView(frame: frame)
        stage.wantsLayer = true
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFront(nil)
        defer { window.close() }
        let old = NSView(frame: frame)
        old.wantsLayer = true
        old.layer?.backgroundColor = NSColor.blue.cgColor
        stage.show(old, of: UUID())
        let web = WKWebView(frame: frame, configuration: configuration)
        web.load(URLRequest(url: URL(string: "slow://site/")!))
        for _ in 0..<200 {
            if scheme.task != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(scheme.task != nil)
        let id = UUID()
        StageView.willOpen(id)
        stage.show(web, of: id)
        let shown = CACurrentMediaTime(), punctual = Punctuality()
        defer { punctual.stop() }
        #expect(web.superview === stage)
        #expect(web.layer?.opacity == 1)
        #expect(web.value(forKey: "drawsBackground") as? Bool == false)
        _ = try await Loaded.until(2) { old.superview == nil }
        #expect(old.superview == nil)
        if punctual.held() { #expect(CACurrentMediaTime() - shown < 0.5) }
        // The site still hasn't answered.
        #expect(scheme.task != nil)
        scheme.answer()
        _ = try await Loaded.until(5) { web.value(forKey: "drawsBackground") as? Bool == true }
        #expect(web.value(forKey: "drawsBackground") as? Bool == true)
    }

    @Test func configurationSurvivesWebKitCopy() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        #expect(PagePaint.configure(configuration))
        let web = WKWebView(frame: .zero, configuration: configuration)
        let getter = NSSelectorFromString("_waitsForPaintAfterViewDidMoveToWindow")
        let copy = web.configuration
        try #require(copy.responds(to: getter))
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        #expect(!unsafeBitCast(copy.method(for: getter), to: Get.self)(copy, getter))
        #expect(copy.websiteDataStore === configuration.websiteDataStore)
        #expect(copy.preferences.inactiveSchedulingPolicy == configuration.preferences.inactiveSchedulingPolicy)
    }

    @Test func returningPagePreservesDocumentAndPaint() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        try #require(PagePaint.configure(configuration))
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        let stage = StageView(frame: page.frame)
        let window = NSWindow(contentRect: page.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFront(nil)
        defer { window.close() }
        let id = UUID()
        stage.show(page, of: id)
        page.loadHTMLString("<body style='background:#20b060;height:1800px'><input id='value'><script>window.token='same-document'</script></body>", baseURL: nil)
        let loaded = try await Loaded.until(30) {
            (try? await page.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('value')")) as? Bool == true
        }
        try #require(loaded)
        _ = try await page.evaluateJavaScript("document.getElementById('value').value='kept'; scrollTo(0, 250); true")
        let other = NSView(frame: stage.bounds)
        stage.show(other, of: UUID())
        _ = try await Loaded.until(10) { page.window == nil }
        #expect(page.window == nil)
        stage.show(page, of: id)
        _ = try await Loaded.until(10) { page.superview === stage && other.superview == nil }
        #expect(page.superview === stage)
        #expect(other.superview == nil)
        #expect(try await page.evaluateJavaScript("window.token + ':' + document.getElementById('value').value") as? String == "same-document:kept")
        #expect(try await page.evaluateJavaScript("scrollY") as? Int == 250)
        let image = try await page.takeSnapshot(configuration: nil)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(color.greenComponent > 0.5 && color.redComponent < 0.3)
    }
}
