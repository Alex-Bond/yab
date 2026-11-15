import AppKit
import Testing
import WebKit
@testable import Fast

/// A site's own Picture-in-Picture button (FloatPiP.swift), in real WebKit
/// pages of a real Browser: the standard API puts only the video, WebKit's
/// own view of it, in Yab's window, the page stays in its tab, and it works
/// again after it came back. Before, WebKit's own was off in a WKWebView,
/// then (0.0.17) the whole page went into Yab's window, the tab left black,
/// and from 2026-10-08 to 10-13 the video went to the system's window.
@MainActor
@Suite(.serialized)
struct FloatPiPTests {
    @MainActor
    private final class Fixture {
        let browser: Browser
        let tabs: [Tab]
        let window: NSWindow
        let windowID = UUID()

        init() {
            browser = Browser(windowID: windowID)
            // This fixture exercises WebKit's native video PiP callbacks.
            tabs = [Tab(bench: true, factory: .webKitOnly), Tab(bench: true, factory: .webKitOnly)]
            for (i, tab) in tabs.enumerated() {
                browser.prepare(tab)
                browser.lay(browser.tabs + [tab])
                tab.go(to: URL(string: "about:blank#float-pip-\(i)")!)
            }
            browser.activeID = tabs[0].id
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let both = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
            for (i, tab) in tabs.enumerated() {
                requireNativeWebKitFixture(tab, "FloatPiPTests").frame = NSRect(x: i * 500, y: 0, width: 500, height: 600)
                both.addSubview(requireNativeWebKitFixture(tab, "FloatPiPTests"))
            }
            window.contentView = both
            window.orderFront(nil)
        }

        /// Back beside the other, after Yab's window let go of it.
        func house(_ tab: Tab) {
            guard requireNativeWebKitFixture(tab, "FloatPiPTests").window == nil, let both = window.contentView else { return }
            requireNativeWebKitFixture(tab, "FloatPiPTests").frame = NSRect(x: tabs.firstIndex { $0 === tab }! * 500, y: 0, width: 500, height: 600)
            both.addSubview(requireNativeWebKitFixture(tab, "FloatPiPTests"))
        }

        func close() {
            browser.land()
            for tab in browser.tabs + browser.outside + browser.parkedTabs { tab.close() }
            window.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
        }
    }

    /// A playing video from a canvas, so nothing is fetched, and the events
    /// a player listens for, written down.
    private let page =
"""
        <!doctype html><html><body style="margin:0">
        <video muted autoplay playsinline style="width:480px;height:270px"></video>
        <script>
          window.heard = [];
          const canvas = document.createElement('canvas');
          canvas.width = 320; canvas.height = 180;
          const paint = canvas.getContext('2d');
          let n = 0;
          setInterval(() => { paint.fillStyle = 'hsl(' + (n++ * 7 % 360) + ',80%,50%)'; paint.fillRect(0, 0, 320, 180); }, 33);
          for (const v of document.querySelectorAll('video')) {
            v.srcObject = canvas.captureStream(30);
            v.play().catch(() => {});
          }
          const video = document.querySelector('video');
          video.addEventListener('enterpictureinpicture', e => heard.push('enter:' + (e.pictureInPictureWindow ? 'window' : 'none')));
          video.addEventListener('leavepictureinpicture', () => heard.push('leave'));
          window.fixtureReady = true;
        </script></body></html>
        """

    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(try await condition(), "WebKit fixture did not settle")
    }

    private func make() async throws -> Fixture {
        let fixture = Fixture()
        do {
            for (i, tab) in fixture.tabs.enumerated() {
                let url = URL(string: "https://float-pip.test/watch/\(i)")!
                requireNativeWebKitFixture(tab, "FloatPiPTests").loadHTMLString(page, baseURL: url)
                try await wait {
                    (try? await requireNativeWebKitFixture(tab, "FloatPiPTests").evaluateJavaScript(
                        "window.fixtureReady === true && document.querySelector('video').readyState >= 2")) as? Bool == true
                }
                tab.setAddressOptimistically(url)
            }
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    /// Where the test stands, in its log: a round that waits for good says
    /// on what.
    private func step(_ what: String) {
        FileHandle.standardError.write(Data("FLOAT_PIP_STEP \(String(format: "%.3f", CACurrentMediaTime())) \(what)\n".utf8))
    }

    private func run(_ script: String, in tab: Tab) async throws -> Any? {
        try await requireNativeWebKitFixture(tab, "FloatPiPTests").callAsyncJavaScript(script, contentWorld: .page)
    }

    /// WebKit settles the promise first and tells the page a moment later.
    private func enter(_ tab: Tab) async throws -> [Any]? {
        try await run("""
            const video = document.querySelector('video');
            await new Promise(done => setTimeout(done, 50));
            const told = new Promise(done => video.addEventListener('enterpictureinpicture', done, { once: true }));
            const shown = await video.requestPictureInPicture();
            await told;
            return [document.pictureInPictureElement === video, shown.width > 0 && shown.height > 0, heard.join(',')];
            """, in: tab) as? [Any]
    }

    private func gone(_ tab: Tab) async throws -> Bool {
        try await run("return document.pictureInPictureElement === null", in: tab) as? Bool == true
    }

    /// The press, then the request a moment later as X makes it: only the
    /// video out, the page still in its tab and told, back by
    /// exitPictureInPicture, and out again on the next press.
    @Test func thePagesButtonPutsOnlyItsVideoOutAndAgain() async throws {
        step("button: make")
        let fixture = try await make()
        defer { fixture.close() }
        let tab = fixture.tabs[0]

        step("button: enter")
        let opened = try await enter(tab)
        step("button: entered")
        #expect(opened?[0] as? Bool == true)
        #expect(opened?[1] as? Bool == true)
        #expect(opened?[2] as? String == "enter:window")
        try await wait { tab.pictureInPicture }
        #expect(fixture.browser.floating == tab.id)
        #expect(fixture.browser.floater.showing)
        #expect(fixture.browser.picturing != nil)
        #expect(!tab.floating)
        #expect(requireNativeWebKitFixture(tab, "FloatPiPTests").window === fixture.window)
        // WebKit's view of the video alone, in Yab's window.
        #expect(fixture.browser.picturing?.view.window != nil)
        #expect(fixture.browser.picturing?.view.window !== fixture.window)
        // The window's bar and times read that video: asked too early, the
        // page didn't know it yet and X's window had no bar.
        step("button: progress")
        try await wait {
            await withCheckedContinuation { done in
                fixture.browser.floater.onProgress? { head in done.resume(returning: head != nil) }
            }
        }

        step("button: exit")
        let closed = try await run("""
            const video = document.querySelector('video');
            const told = new Promise(done => video.addEventListener('leavepictureinpicture', done, { once: true }));
            await document.exitPictureInPicture();
            await told;
            return [document.pictureInPictureElement === null, heard.join(',')];
            """, in: tab) as? [Any]
        #expect(closed?[0] as? Bool == true)
        #expect(closed?[1] as? String == "enter:window,leave")
        try await wait { !tab.pictureInPicture }
        try await wait { fixture.browser.floating == nil && !fixture.browser.floater.showing }

        // The second press, which failed with the window of 0.0.17.
        step("button: enter again")
        let again = try await enter(tab)
        step("button: entered again")
        #expect(again?[0] as? Bool == true)
        #expect(again?[2] as? String == "enter:window,leave,enter:window")
        try await wait { tab.pictureInPicture && fixture.browser.floating == tab.id }

        // Yab's ×: the video goes home, and the page hears it left.
        step("button: dismiss")
        fixture.browser.floater.onDismiss?()
        try await wait { !tab.pictureInPicture && fixture.browser.floating == nil }
        try await wait { try await gone(tab) }
        step("button: done")
    }

    /// One picture at a time, either way round: a video out in Yab's window
    /// goes home when another page puts its own out, and ⇧⌘P's window puts
    /// a page's back into its page.
    @Test func onePictureAtATime() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (a, b) = (fixture.tabs[0], fixture.tabs[1])
        fixture.browser.activeID = b.id

        fixture.browser.float(a)
        try await wait { fixture.browser.floating == a.id }
        _ = try await enter(b)
        try await wait { b.pictureInPicture && fixture.browser.floating == b.id && fixture.browser.picturing != nil }

        fixture.house(a)
        fixture.browser.float(a)
        try await wait { fixture.browser.floating == a.id && !b.pictureInPicture }
        try await wait { try await gone(b) }
    }

    /// ⇧⌘P on the tab in front puts only its video out, in Yab's window: the
    /// page stays in its tab, and ⇧⌘P again brings it back. Until 2026-10-12
    /// the whole page went into Yab's window.
    @Test func shortcutPutsOnlyTheVideoOut() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let tab = fixture.tabs[0]
        fixture.browser.activeID = tab.id

        fixture.browser.toggleFloat()
        try await wait { tab.pictureInPicture }
        #expect(fixture.browser.floating == tab.id)
        #expect(fixture.browser.floater.showing)
        #expect(!tab.floating)
        #expect(requireNativeWebKitFixture(tab, "FloatPiPTests").window === fixture.window)
        try await wait { (try await run("return heard.join(',')", in: tab)) as? String == "enter:window" }

        fixture.browser.toggleFloat()
        try await wait { !tab.pictureInPicture }
        try await wait { try await gone(tab) }
    }

    /// ⇧⌘P on a paused video puts it out too, as the button does:
    /// until register 899 it said "Nothing playing".
    @Test func shortcutPutsAPausedVideoOut() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let tab = fixture.tabs[0]
        fixture.browser.activeID = tab.id
        _ = try await run("document.querySelector('video').pause(); return true", in: tab)
        try await wait { (try await run("return document.querySelector('video').paused", in: tab)) as? Bool == true }

        fixture.browser.toggleFloat()
        try await wait { tab.pictureInPicture }
        #expect(fixture.browser.floating == tab.id)
        fixture.browser.toggleFloat()
        try await wait { !tab.pictureInPicture }
    }

    /// ⇧⌘P on the tab whose video is out asks for it back.
    @Test func shortcutOnItsTabBringsItBack() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let tab = fixture.tabs[1]

        _ = try await enter(tab)
        try await wait { tab.pictureInPicture }
        fixture.browser.activeID = tab.id
        fixture.browser.toggleFloat()
        try await wait { !tab.pictureInPicture }
        #expect(fixture.browser.floating == nil)
        try await wait { (try await run("return heard.join(',')", in: tab)) as? String == "enter:window,leave" }
    }

    /// WebKit's own refusals: nothing out to leave, and a request with no
    /// press behind it. (A video's disablepictureinpicture only hides
    /// buttons in WebKit, Safari's too: the request still opens.)
    @Test func refusalsAreTheSpecifications() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let tab = fixture.tabs[0]

        let exit = try await run("""
            try { await document.exitPictureInPicture(); return 'left'; } catch (e) { return e.name; }
            """, in: tab) as? String
        #expect(exit == "InvalidStateError")

        // A native evaluation is a press to WebKit, for a few seconds: this
        // request comes from the page's own timer after it has gone.
        _ = try await run("""
            const video = document.querySelector('video');
            window.plain = 'waiting';
            setTimeout(() => {
              video.requestPictureInPicture().then(() => { plain = 'opened'; }, e => { plain = e.name; });
            }, 5500);
            return true;
            """, in: tab)
        try await Task.sleep(for: .milliseconds(6000))
        try await wait {
            (try? await run("return window.plain", in: tab)) as? String != "waiting"
        }
        #expect(try await run("return window.plain", in: tab) as? String == "NotAllowedError")
        #expect(!tab.pictureInPicture)
    }
}
