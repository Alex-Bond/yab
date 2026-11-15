import AppKit
import Testing
import WebKit
@testable import Fast

/// Page ownership of horizontal gestures, including spreadsheet-style canvas
/// scrolling. Synthetic DOM events test the injected script; native events
/// separately test how PageView handles a delayed reply from that script.
@Suite(.serialized)
@MainActor
struct SwipePageTests {
    private final class Replies: NSObject, WKScriptMessageHandler {
        var sides: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], let side = body["side"] as? String {
                sides.append(side)
            }
        }
    }

    /// A page as one is swiped on: in a window and seen, so it draws its
    /// frames, the frame the answer waits for among them. Off every screen,
    /// and seen all the same (PageView.seenOffscreen), wherever the Mac's
    /// screens are and whatever covers them.
    private func page(_ body: String) async throws -> (WKWebView, Replies) {
        let replies = Replies()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(replies, contentWorld: Web.world, name: "yabScroll")
        config.userContentController.addUserScript(WKUserScript(source: Swipe.watch,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world))
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.swipeTrackingEnabled = { true }
        web.keepSeen = true
        web.seenOffscreen = true
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        web.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://sheets.example.test/"))
        var state: Any?
        for _ in 0..<200 {
            state = try? await web.evaluateJavaScript("[document.readyState, !!document.getElementById('target'), document.visibilityState].join(' ')")
            if state as? String == "complete true visible" {
                // A gesture's begin, as PageView sends it before WebKit's
                // first wheel: the script listens to the wheel only from
                // then on (feedback #175).
                _ = try await web.evaluateJavaScript("window.__yabSwipe.begin(1); true", in: nil, in: Web.world)
                return (web, replies)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        done(web)
        Issue.record("the page never stood seen and loaded: \(String(describing: state))")
        throw CocoaError(.fileReadUnknown)
    }

    /// The page's handler and its window gone with the test.
    private func done(_ web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "yabScroll", contentWorld: Web.world)
        SwipePageTests.close(web)
    }

    static func close(_ web: WKWebView) {
        web.window?.orderOut(nil)
        web.window?.contentView = nil
    }

    private func side(_ body: String, setup: String = "", dx: Int = 40) async throws -> String {
        let (web, replies) = try await page(body)
        defer { done(web) }
        _ = try await web.evaluateJavaScript("""
        \(setup);
        document.getElementById('target').dispatchEvent(new WheelEvent('wheel', {
            deltaX: \(dx), deltaY: 0, bubbles: true, cancelable: true, composed: true
        })); true
        """)
        for _ in 0..<300 {
            if let side = replies.sides.last { return side }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }

    private let grid = """
    <div id=target style="width:300px;height:150px;overflow:auto">
      <div style="width:1200px;height:100px">Wide table</div>
    </div>
    """

    @Test func wideTableKeepsBothDirectionsAwayFromEdges() async throws {
        for dx in [-40, 40] {
            #expect(try await side(grid, setup: "document.getElementById('target').scrollLeft = 300", dx: dx) == "taken")
        }
    }

    @Test func ordinaryTableEdgeAllowsHistoryNavigation() async throws {
        #expect(try await side(grid, dx: -40) == "free")
    }

    @Test func canvasPreventDefaultIsVisibleAcrossContentWorlds() async throws {
        let body = "<canvas id=target width=600 height=300></canvas>"
        #expect(try await side(body, setup: "document.getElementById('target').addEventListener('wheel', e => e.preventDefault(), {passive:false})") == "taken")
    }

    @Test func canvasThatMovesSiblingScrollerKeepsGesture() async throws {
        let body = """
        <canvas id=target width=600 height=300></canvas>
        <div id=scroll style="width:300px;overflow:auto"><div style="width:1200px;height:10px"></div></div>
        """
        #expect(try await side(body, setup: "document.getElementById('target').addEventListener('wheel', e => { document.getElementById('scroll').scrollLeft += e.deltaX; })") == "taken")
    }

    @Test func sheetsStyleLegacyWheelScrollKeepsGesture() async throws {
        let (web, replies) = try await page("""
        <div id=target style="width:600px;height:300px;overflow:hidden">Grid</div>
        <div id=scroll style="width:300px;overflow:scroll"><div style="width:1200px;height:10px"></div></div>
        <script>
        document.getElementById('target').addEventListener('mousewheel', e => {
            document.getElementById('scroll').scrollLeft -= e.wheelDeltaX;
        });
        </script>
        """)
        defer { done(web) }
        _ = try await web.evaluateJavaScript("""
        const target = document.getElementById('target');
        target.dispatchEvent(new WheelEvent('wheel', {deltaX:100, bubbles:true, cancelable:true}));
        target.dispatchEvent(new WheelEvent('mousewheel', {wheelDeltaX:-120, bubbles:true, cancelable:true}));
        true
        """)
        for _ in 0..<300 {
            if !replies.sides.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await web.evaluateJavaScript("document.getElementById('scroll').scrollLeft") as? Int == 120)
        #expect(replies.sides.last == "taken")
    }

    @Test func containedTableEdgeKeepsGesture() async throws {
        for behavior in ["contain", "none"] {
            #expect(try await side(grid, setup: "document.getElementById('target').style.overscrollBehaviorX = '\(behavior)'", dx: -40) == "taken")
        }
    }

    @Test func pageCanCancelAfterInitiallyAllowingGesture() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 20, phase: 2))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(x: 120, phase: 2))
        web.answer(free: false, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        #expect(navigations == 0)
    }

    @Test func busyPageMustReplyBeforeBrowserNavigates() async throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 20, phase: 2))
        try await Task.sleep(for: .milliseconds(230))
        web.scrollWheel(with: try wheel(x: 120, phase: 2))
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.answer(free: false, gesture: web.swipeGesture)
        #expect(navigations == 0)
    }

    @Test func viewportPolicyWithoutHorizontalOverflowAllowsHistory() async throws {
        for behavior in ["contain", "none"] {
            #expect(try await side("<div id=target>Sheet</div>", setup:
                "document.documentElement.style.overscrollBehaviorX = '\(behavior)'") == "free")
        }
    }

    @Test func viewportPolicyKeepsHorizontallyScrollablePageAtEdge() async throws {
        for behavior in ["contain", "none"] {
            #expect(try await side("<div id=target style='width:1600px'>Wide page</div>", setup:
                "document.documentElement.style.overscrollBehaviorX = '\(behavior)'", dx: -40) == "taken")
        }
    }

    @Test func verticalOnlyContainerPolicyAllowsHistory() async throws {
        for behavior in ["contain", "none"] {
            #expect(try await side("""
                <div id=target style="width:300px;height:150px;overflow:auto;overscroll-behavior-x:\(behavior)">
                  <div style="height:1200px">Timeline</div>
                </div>
                """) == "free")
        }
    }

    @Test func verticalPageMovementDuringSidewaysWheelAllowsHistory() async throws {
        #expect(try await side("<div id=target style='height:3000px'>Timeline</div>", setup:
            "document.getElementById('target').addEventListener('wheel', () => window.scrollBy(0, 40))") == "free")
    }

    @Test func verticalSiblingMovementDuringSidewaysWheelAllowsHistory() async throws {
        #expect(try await side("""
            <div id=target>Timeline</div>
            <div id=scroll style="width:300px;height:100px;overflow:auto"><div style="height:1200px"></div></div>
            """, setup:
            "document.getElementById('target').addEventListener('wheel', () => { document.getElementById('scroll').scrollTop += 40; })") == "free")
    }

    /// A sibling scrolled across before the gesture is read when the wheel
    /// comes, not taken for one the gesture moved from nothing.
    @Test func siblingScrolledAcrossEarlierThenMovedDownAllowsHistory() async throws {
        let (web, replies) = try await page("""
        <div id=target>Timeline</div>
        <div id=scroll style="width:300px;height:100px;overflow:auto"><div style="width:1200px;height:1200px"></div></div>
        """)
        defer { done(web) }
        let scrolled = try await web.callAsyncJavaScript("""
            const s = document.getElementById('scroll');
            const heard = new Promise(r => s.addEventListener('scroll', r, { once: true }));
            s.scrollLeft = 300;
            await heard;
            return s.scrollLeft;
            """, contentWorld: .page) as? Int
        #expect(scrolled == 300)
        _ = try await web.evaluateJavaScript("""
        document.getElementById('target').addEventListener('wheel', () => { document.getElementById('scroll').scrollTop += 40; });
        document.getElementById('target').dispatchEvent(new WheelEvent('wheel', {deltaX: 40, bubbles: true, cancelable: true})); true
        """)
        for _ in 0..<300 {
            if !replies.sides.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.sides.last == "free")
    }

    /// More scrollers scrolled across before the gesture than the few the
    /// script keeps before it lets go of collected ones: each one still on
    /// the page is read at the wheel. The same scrollers moved across in a
    /// second gesture show the replies come in time to be taken.
    @Test func manyScrollersScrolledAcrossEarlierThenMovedDownAllowHistory() async throws {
        let rows = String(repeating: """
        <div class=s style="width:300px;height:100px;overflow:auto"><div style="width:1200px;height:1200px"></div></div>
        """, count: 20)
        let (web, replies) = try await page("<div id=target>Timeline</div>" + rows)
        defer { done(web) }
        let scrolled = try await web.callAsyncJavaScript("""
            const all = [...document.querySelectorAll('.s')];
            const heard = all.map(s => new Promise(r => s.addEventListener('scroll', r, { once: true })));
            for (const s of all) s.scrollLeft = 300;
            await Promise.all(heard);
            return all.filter(s => s.scrollLeft === 300).length;
            """, contentWorld: .page) as? Int
        #expect(scrolled == 20)
        _ = try await web.evaluateJavaScript("""
        window.sideways = false;
        document.getElementById('target').addEventListener('wheel', () => {
            for (const s of document.querySelectorAll('.s')) sideways ? s.scrollLeft += 40 : s.scrollTop += 40;
        });
        document.getElementById('target').dispatchEvent(new WheelEvent('wheel', {deltaX: 40, bubbles: true, cancelable: true})); true
        """)
        for _ in 0..<300 {
            if !replies.sides.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.sides.last == "free")
        try await begin(web, gesture: 2)
        replies.sides = []
        _ = try await web.evaluateJavaScript("""
        window.sideways = true;
        document.getElementById('target').dispatchEvent(new WheelEvent('wheel', {deltaX: 40, bubbles: true, cancelable: true})); true
        """)
        for _ in 0..<300 {
            if !replies.sides.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.sides.last == "taken")
    }

    /// Scrolling down with no sideways wheel to answer reads no widths or
    /// positions: each read lays the page out, on every scroll event. A
    /// scroller that moved is read at the next sideways wheel, wherever
    /// that wheel is.
    @Test func scrollingDownReadsNothingUntilASidewaysWheel() async throws {
        let (web, _) = try await page("""
        <div id=target>Feed</div>
        <div id=feed style="height:300px;overflow:auto"><div style="height:5000px"></div></div>
        <div style="height:5000px"></div>
        """)
        defer { done(web) }
        // Every read of a width or a position in yab's world, counted, and
        // the feed's apart: the wheel's own path never takes it in.
        _ = try await web.callAsyncJavaScript("""
            window.reads = 0; window.feedReads = 0;
            for (const name of ['scrollWidth', 'clientWidth', 'scrollLeft']) {
                const own = Object.getOwnPropertyDescriptor(Element.prototype, name);
                Object.defineProperty(Element.prototype, name, { configurable: true, set: own.set, get() {
                    window.reads++;
                    if (this.id === 'feed') window.feedReads++;
                    return own.get.call(this);
                } });
            }
            """, contentWorld: Web.world)
        let scrolls = try await web.callAsyncJavaScript("""
            const feed = document.getElementById('feed');
            let page = 0, inner = 0;
            addEventListener('scroll', e => e.target === feed ? inner++ : page++, true);
            for (let i = 0; i < 5; i++) {
                scrollBy(0, 200);
                feed.scrollTop += 200;
                await new Promise(r => setTimeout(r, 50));
            }
            return [page, inner];
            """, contentWorld: .page) as? [Int]
        #expect(scrolls?.count == 2)
        #expect(scrolls?.allSatisfy({ $0 > 0 }) == true)
        #expect(try await web.callAsyncJavaScript("return window.reads", contentWorld: Web.world) as? Int == 0)
        _ = try await web.evaluateJavaScript("""
        document.getElementById('target').dispatchEvent(new WheelEvent('wheel', {deltaX: 40, bubbles: true})); true
        """)
        #expect((try await web.callAsyncJavaScript("return window.feedReads", contentWorld: Web.world) as? Int ?? 0) > 0)
    }

    /// A scroller noted as it scrolled and then dropped by the page is not
    /// kept alive from yab's world, and with it the page's own wrapper of
    /// it, which a hold there would keep (the control, `held`).
    @Test func scrollerGoneFromThePageIsLetGo() async throws {
        let (web, _) = try await page("""
        <div id=target>Feed</div>
        <div id=gone style="height:100px;overflow:auto"><div style="height:1200px"></div></div>
        <div id=held style="height:100px;overflow:auto"><div style="height:1200px"></div></div>
        """)
        defer { done(web) }
        _ = try await web.callAsyncJavaScript("window.held = document.getElementById('held')", contentWorld: Web.world)
        _ = try await web.callAsyncJavaScript("""
            window.refs = {};
            for (const id of ['gone', 'held']) {
                const s = document.getElementById(id);
                s.mark = {};
                const heard = new Promise(r => s.addEventListener('scroll', () => r(), { once: true }));
                s.scrollTop = 200;
                await heard;
                s.remove();
                refs[id] = new WeakRef(s);
            }
            """, contentWorld: .page)
        // WebKit's own hook for a collection now, in every web process.
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "WKContextGarbageCollectJavaScriptObjects"))
        let collect = unsafeBitCast(symbol, to: (@convention(c) (UnsafeRawPointer) -> Void).self)
        let pool = try #require(web.configuration.value(forKey: "processPool") as AnyObject?)
        var left: [Bool]?
        for _ in 0..<30 {
            collect(UnsafeRawPointer(Unmanaged.passUnretained(pool).toOpaque()))
            try await Task.sleep(for: .milliseconds(100))
            left = try await web.evaluateJavaScript("[!!refs.gone.deref(), !!refs.held.deref()]") as? [Bool]
            if left == [false, true] { break }
        }
        #expect(left == [false, true])
    }

    @Test func ordinaryNonScrollingElementDoesNotBlockHistory() async throws {
        #expect(try await side("<div id=target style='overscroll-behavior-x:contain'>Text</div>") == "free")
    }

    private let clippedArticle = """
    <div id=clip style="width:300px;overflow-x:hidden">
      <div id=target style="width:1200px">Article text</div>
    </div>
    """

    @Test func clippedArticleOverflowAllowsHistoryInBothDirections() async throws {
        for dx in [-40, 40] {
            #expect(try await side(clippedArticle, dx: dx) == "free")
        }
    }

    @Test func hiddenOverflowThatActuallyScrollsKeepsGesture() async throws {
        #expect(try await side(clippedArticle, setup:
            "document.getElementById('target').addEventListener('wheel', e => { document.getElementById('clip').scrollLeft += e.deltaX; })") == "taken")
    }

    @Test func clippedArticleCanExplicitlyTakeGesture() async throws {
        #expect(try await side(clippedArticle, setup:
            "document.getElementById('target').addEventListener('wheel', e => e.preventDefault(), {passive:false})") == "taken")
    }

    @Test func rtlTableKeepsBothDirectionsAwayFromEdges() async throws {
        for dx in [-40, 40] {
            #expect(try await side(grid, setup:
                "const t = document.getElementById('target'); t.style.direction = 'rtl'; t.scrollLeft = -300", dx: dx) == "taken")
        }
    }

    @Test func modernWheelMovingSiblingScrollerKeepsGesture() async throws {
        let body = """
        <div id=target>Custom grid</div>
        <div id=scroll style="width:300px;overflow:auto"><div style="width:1200px;height:10px"></div></div>
        """
        #expect(try await side(body, setup:
            "document.getElementById('target').addEventListener('wheel', e => { document.getElementById('scroll').scrollLeft += e.deltaX; })") == "taken")
    }

    @Test func ownershipRemainsAtEdgeUntilNextGesture() async throws {
        let (web, replies) = try await page(grid)
        defer { done(web) }
        try await begin(web, gesture: 1)
        var heard = replies.sides.count
        _ = try await web.evaluateJavaScript("""
        const t = document.getElementById('target');
        t.scrollLeft = 300;
        t.dispatchEvent(new WheelEvent('wheel', {deltaX:-40, bubbles:true})); true
        """)
        #expect(try await answer(replies, after: heard) == "taken")
        heard = replies.sides.count
        _ = try await web.evaluateJavaScript("""
        t.scrollLeft = 0;
        t.dispatchEvent(new WheelEvent('wheel', {deltaX:-40, bubbles:true})); true
        """)
        #expect(try await answer(replies, after: heard) == "taken")
        // The table back at its edge before the next gesture, as the page
        // sees it frame after frame: in a page that is seen, WebKit's own
        // scrolling can answer two quick jumps a frame late, and once left
        // it 40 short of the edge (at 260, farm 49365e1b5d194946).
        let still = try await web.callAsyncJavaScript("""
            const t = document.getElementById('target');
            const frame = () => new Promise(r => requestAnimationFrame(r));
            for (let i = 0, run = 0; i < 100; i++) {
                if (t.scrollLeft !== 0) { t.scrollLeft = 0; run = 0; } else if (++run === 3) return true;
                await frame();
            }
            return t.scrollLeft;
            """, contentWorld: .page)
        #expect(still as? Bool == true, "the table at \(String(describing: still))")
        try await begin(web, gesture: 2)
        heard = replies.sides.count
        _ = try await web.evaluateJavaScript("t.dispatchEvent(new WheelEvent('wheel', {deltaX:-40, bubbles:true})); true")
        let last = try await answer(replies, after: heard)
        let left = try await web.evaluateJavaScript("t.scrollLeft") as? Double
        #expect(last == "free", "answers \(replies.sides), heard \(heard), the table at \(String(describing: left))")
    }

    /// The page's next answer after the `count` already heard.
    private func answer(_ replies: Replies, after count: Int) async throws -> String? {
        for _ in 0..<300 {
            if replies.sides.count > count { return replies.sides.last }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func finalPermissionStillAllowsOrdinaryHistorySwipe() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 140, phase: 2))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        #expect(navigations == 0)
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        #expect(navigations == 1)
    }

    /// A Magic Mouse's finger, or a quick flick, lifts short of the arm and
    /// leaves the rest to the glide macOS sends after (feedback #1177, #1268).
    @Test func glideAfterAShortLiftCarriesTheSwipeBack() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 20, phase: 2))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(x: 30, phase: 2))
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        #expect(navigations == 0)
        for (n, dx) in [30, 30, 25, 20, 15].enumerated() {
            web.scrollWheel(with: try wheel(x: Int32(dx), phase: 0, momentum: n == 0 ? 1 : 2))
        }
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        #expect(navigations == 1)
        web.scrollWheel(with: try wheel(x: 5, phase: 0, momentum: 2))
        web.scrollWheel(with: try wheel(x: 0, phase: 0, momentum: 3))
        #expect(navigations == 1)
    }

    @Test func shortOrBackwardGlideStaysOnThePage() throws {
        for glide in [[10, 8, 5], [-30, -30, -20]] {
            let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
            web.swipeTrackingEnabled = { true }
            var navigations = 0
            web.fromTitle = { "Previous tab" }
            web.onFrom = { navigations += 1 }
            web.scrollWheel(with: try wheel(x: 0, phase: 1))
            web.scrollWheel(with: try wheel(x: 20, phase: 2))
            web.answer(free: true, gesture: web.swipeGesture)
            web.scrollWheel(with: try wheel(x: 30, phase: 2))
            web.scrollWheel(with: try wheel(x: 0, phase: 4))
            for (n, dx) in glide.enumerated() {
                web.scrollWheel(with: try wheel(x: Int32(dx), phase: 0, momentum: n == 0 ? 1 : 2))
            }
            web.scrollWheel(with: try wheel(x: 0, phase: 0, momentum: 3))
            web.answer(free: true, gesture: web.swipeGesture, finished: true)
            #expect(navigations == 0)
            #expect(web.swipeSettled)
        }
    }

    @Test func fingersDownAgainStopTheGlidingSwipe() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 20, phase: 2))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(x: 30, phase: 2))
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.scrollWheel(with: try wheel(x: 20, phase: 0, momentum: 1))
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 0, phase: 0, momentum: 2))
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        #expect(navigations == 0)
    }

    @Test func pinchedInPagePansInsteadOfNavigating() throws {
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        web.allowsMagnification = true
        web.magnification = 2
        #expect(web.magnification > 1.01)
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 140, phase: 2))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        #expect(navigations == 0)
    }

    @Test func lateDenialAfterFingerLiftPreventsNavigation() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 140, phase: 2))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.answer(free: false, gesture: web.swipeGesture, finished: true)
        #expect(navigations == 0)
    }

    @Test func noFinalReplyCancelsAndIgnoresLatePermission() async throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 140, phase: 2))
        let gesture = web.swipeGesture
        web.answer(free: true, gesture: gesture)
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        try await Task.sleep(for: .milliseconds(850))
        web.answer(free: true, gesture: gesture, finished: true)
        #expect(navigations == 0)
    }

    @Test func previousGestureAndDocumentRepliesAreIgnored() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        let old = web.swipeGesture
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 140, phase: 2))
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.answer(free: true, gesture: old, finished: true)
        #expect(navigations == 0)
        let current = web.swipeGesture
        web.cancelSwipe()
        web.answer(free: true, gesture: current, finished: true)
        #expect(navigations == 0)
    }

    @Test func busyArticleCanConfirmAfterWheelHandlersFinish() async throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        web.scrollWheel(with: try wheel(x: 140, phase: 2))
        let gesture = web.swipeGesture
        web.answer(free: true, gesture: gesture)
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        try await Task.sleep(for: .milliseconds(250))
        #expect(navigations == 0)
        web.answer(free: true, gesture: gesture, finished: true)
        #expect(navigations == 1)
    }

    @Test(arguments: [false, true])
    func nativeWheelReachesWebKitAndRespectsPageOwnership(single: Bool) async throws {
        for policy in ["auto", "none", "sibling", "vertical", "cancel", "table", "edge"] {
            let tab = Tab(bench: true, factory: .webKitOnly)
            let web = requireNativeWebKitFixture(tab, "SwipePageTests")
            web.swipeTrackingEnabled = { true }
            web.keepSeen = true
            web.seenOffscreen = true
            let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 800, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = web
            window.orderFront(nil)
            defer { SwipePageTests.close(web) }
            web.loadHTMLString("""
            <html style="overscroll-behavior-x:\(policy == "none" ? "none" : "auto")">
            <body style="margin:0"><div id=target style="height:3000px;width:300px;overflow:auto">
            <div style="width:\(policy == "table" || policy == "edge" ? 1200 : 300)px">Swipe here</div></div>
            <div id=scroll style="position:fixed;bottom:0;width:300px;overflow:auto"><div style="width:1200px;height:10px"></div></div>
            <script>
            window.trustedWheels = 0;
            const bar = document.getElementById('scroll'); bar.scrollLeft = 300;
            if ('\(policy)' === 'table') document.getElementById('target').scrollLeft = 300;
            window.addEventListener('wheel', e => {
                if (e.isTrusted && e.deltaX) window.trustedWheels++;
                if ('\(policy)' === 'sibling') bar.scrollLeft += e.deltaX;
                if ('\(policy)' === 'vertical') window.scrollBy(0, 40);
                if ('\(policy)' === 'cancel') e.preventDefault();
            }, {passive:false});
            </script></body></html>
            """, baseURL: URL(string: "https://swipe.example.test/"))
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("document.readyState === 'complete' && typeof trustedWheels === 'number'")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            var navigations = 0
            web.fromTitle = { "Previous tab" }
            web.onFrom = { navigations += 1 }
            // A short gesture can carry all its travel in its first
            // horizontal wheel. The listener must already hear that wheel.
            let phases: [(Int64, Int32)] = single ? [(1, 0), (2, 140), (4, 0)] : [(1, 0), (2, 20), (2, 120), (4, 0)]
            for (phase, dx) in phases {
                let event = try #require(try wheel(x: dx, phase: phase).cgEvent)
                event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
                typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
                let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
                unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: 100, y: 100))
                web.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
                try await Task.sleep(for: .milliseconds(40))
            }
            // Until the page's last word on the gesture is in, or the wait
            // for it is given up on.
            for _ in 0..<300 where !web.swipeSettled {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(web.swipeSettled, "Policy: \(policy)")
            let count = try #require(try await web.evaluateJavaScript("trustedWheels") as? Int)
            #expect(count > 0, "WebKit must receive trusted horizontal wheels: \(policy)")
            let taken = ["sibling", "cancel", "table"].contains(policy)
            #expect(navigations == (taken ? 0 : 1), "Policy: \(policy), single wheel: \(single)")
            if policy == "sibling" {
                #expect(try await web.evaluateJavaScript("document.getElementById('scroll').scrollLeft") as? Int != 300)
            }
        }
    }

    private func begin(_ web: WKWebView, gesture: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            web.evaluateJavaScript("window.__yabSwipe.begin(\(gesture))", in: nil, in: Web.world) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    private func wheel(x: Int32, phase: Int64, momentum: Int64 = 0) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: x, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try #require(NSEvent(cgEvent: event))
    }
}
