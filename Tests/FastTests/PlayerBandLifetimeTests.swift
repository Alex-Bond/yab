import AppKit
import QuartzCore
import Testing
import WebKit
@testable import Fast

/// An expanded card reads its source page every two seconds. Its own
/// hover work ends when the native view leaves its window, even when the
/// old view stays alive while another view takes over the player.
@MainActor
@Suite(.serialized)
struct PlayerBandLifetimeTests {
    @MainActor
    private final class Fixture {
        let id = UUID()
        let browser: Browser
        let source = Fast.Tab(shy: true, configuration: Web.configuration(shy: true, extensions: false), factory: .webKitOnly)
        let notes = Fast.Tab(shy: true, configuration: Web.configuration(shy: true, extensions: false), factory: .webKitOnly)
        let first = BandView(frame: NSRect(x: 0, y: 0, width: 270, height: Band.reach))
        let sibling = BandView(frame: NSRect(x: 300, y: 0, width: 270, height: Band.reach))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        let window: NSWindow
        let savedDeaf = BandView.deaf

        init() {
            browser = Browser(windowID: id)
            window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            BandView.deaf = true
            // These watches belong to this fixture, not another window.
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.stuck.agentTimer?.invalidate()
            browser.stuck.frontTimer?.invalidate()
            browser.pressure?.cancel()
            for (tab, name) in [(source, "source"), (notes, "notes")] {
                tab.restore(url: URL(string: "about:blank#player-band-" + name)!, title: name)
                browser.prepare(tab)
            }
            browser.lay([source, notes])
            browser.activeID = notes.id
            sibling.attach(browser.player)
            first.attach(browser.player)
        }

        func prepare() async throws {
            try #require(TuneWatch.works, "the real WebKit media watcher must be available")
            let web = requireNativeWebKitFixture(source, "PlayerBandLifetimeTests")
            try #require(!web.configuration.websiteDataStore.isPersistent)
            web.loadHTMLString("<!doctype html><title>Owned source</title><p id=ready>Local fixture</p>",
                               baseURL: URL(string: "about:blank")!)
            let loaded = try await Loaded.until(3, every: .milliseconds(50)) {
                guard !web.isLoading else { return false }
                return try await web.evaluateJavaScript("document.getElementById('ready') !== null",
                                                       in: nil, contentWorld: Web.world) as? Bool == true
            }
            try #require(loaded, "the fixture HTML must finish loading")
            // Observe the real probe's DOM query in its actual isolated
            // world. Forward the original receiver and arguments unchanged.
            // No seeking, go-live, media playback or other poller runs here.
            let installed = try await web.evaluateJavaScript("""
            (() => {
              const original = document.querySelectorAll;
              window.__playerBandProbes = 0;
              document.querySelectorAll = function(selector) {
                if (selector === 'video, audio') ++window.__playerBandProbes;
                return Reflect.apply(original, this, arguments);
              };
              return document.querySelectorAll !== original;
            })()
            """, in: nil, contentWorld: Web.world)
            try #require(installed as? Bool == true)
            var tune = Tune(title: "Owned source", duration: 240, elapsed: 20,
                            stamp: CACurrentMediaTime(), playing: true)
            tune.accent = .systemBlue
            source.tune = tune
            browser.player.heard(source)
            browser.player.restage(immediate: true)
            // The first view binds last; the sibling is already eligible
            // to take over when the first view leaves the native window.
            root.addSubview(sibling)
            root.addSubview(first)
            try await bound(first)
            try #require(first.report["title"] as? String == "Owned source")
            try #require(source.tune?.playing == true && source.tune?.live == false)
        }

        func bound(_ view: BandView) async throws {
            let ready = try await Loaded.until(1) { BandView.last === view && view.window === self.window }
            try #require(ready, "the intended native BandView must own the player listener")
        }

        func probes() async throws -> Int {
            let value = try await requireNativeWebKitFixture(source, "PlayerBandLifetimeTests").evaluateJavaScript("window.__playerBandProbes",
                                                               in: nil, contentWorld: Web.world)
            return try #require(value as? Int)
        }

        func laterProbe(after count: Int) async throws -> Int {
            let advanced = try await Loaded.until(2.8, every: .milliseconds(100)) {
                try await self.probes() > count
            }
            try #require(advanced, "an attached expanded card must perform its real repeating WebKit probe")
            return try await probes()
        }

        func close() {
            // Also stop baseline timers after the semantic assertions fail.
            first.bench("close")
            sibling.bench("close")
            first.removeFromSuperview()
            sibling.removeFromSuperview()
            window.contentView = nil
            window.close()
            BandView.deaf = savedDeaf
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.stuck.agentTimer?.invalidate()
            browser.stuck.frontTimer?.invalidate()
            browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            let session = Store.file("session-window-\(id.uuidString).json")
            if FileManager.default.fileExists(atPath: session.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: session) }
            }
        }
    }

    private func emit(_ phase: String, _ fields: [String: Any]) throws {
        var fields = fields
        fields["phase"] = phase
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("PLAYER_BAND_LIFETIME " + String(decoding: data, as: UTF8.self))
    }

    @Test func detachedCardsStopTheirOwnHoverProbesAndCanReattach() async throws {
        _ = NSApplication.shared
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.prepare()

        // A closed attached card is quiet; opening it performs an immediate
        // probe and then another from the actual one-second native timer.
        let closed = try await fixture.probes()
        try await Task.sleep(for: .milliseconds(250))
        try #require(try await fixture.probes() == closed, "the fixture must have no unrelated media queries")
        fixture.first.bench("open")
        let opened = try await fixture.laterProbe(after: closed)
        let repeating = try await fixture.laterProbe(after: opened)
        try #require(fixture.first.report["open"] as? Bool == true)
        try emit("attached", ["before": closed, "opened": opened, "repeating": repeating])

        // Keep both view objects strongly alive. Only the first leaves its
        // window; the source page and the sibling stay available throughout.
        fixture.first.removeFromSuperview()
        try await fixture.bound(fixture.sibling)
        fixture.source.tune?.title = "After handoff"
        fixture.browser.player.heard(fixture.source)
        fixture.browser.player.restage(immediate: true)
        try #require(fixture.sibling.report["title"] as? String == "After handoff")
        let detachedBefore = try await fixture.probes()
        try await Task.sleep(for: .milliseconds(2250))
        let detachedAfter = try await fixture.probes()
        let detachedPass = fixture.first.window == nil
            && fixture.first.report["open"] as? Bool == false
            && fixture.first.report["hovering"] as? Bool == false
            && detachedAfter == detachedBefore
        try emit("detached", ["before": detachedBefore, "after": detachedAfter,
                               "open": fixture.first.report["open"] as? Bool ?? true,
                               "sibling_bound": BandView.last === fixture.sibling, "semantic_pass": detachedPass])
        #expect(detachedPass, "PLAYER_BAND_SEMANTIC_DETACH: retained detached card must stop its own timer and rereads")
        fixture.first.bench("close")

        // Detachment during the normal hover delay must cancel the pending
        // opening too, rather than start a fresh timer out of the window.
        fixture.root.addSubview(fixture.first)
        try await fixture.bound(fixture.first)
        let pendingBefore = try await fixture.probes()
        fixture.first.bench("hover")
        fixture.first.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(250))
        try await fixture.bound(fixture.sibling)
        let pendingAfter = try await fixture.probes()
        let pendingPass = fixture.first.report["open"] as? Bool == false
            && fixture.first.report["hovering"] as? Bool == false && pendingAfter == pendingBefore
        try emit("pending", ["before": pendingBefore, "after": pendingAfter, "semantic_pass": pendingPass])
        #expect(pendingPass, "PLAYER_BAND_SEMANTIC_PENDING: detachment must cancel a pending hover opening")
        fixture.first.bench("close")

        // Reattaching starts closed, can open normally, and can still close
        // normally. This also proves the listener handoff is reversible.
        fixture.root.addSubview(fixture.first)
        try await fixture.bound(fixture.first)
        try #require(fixture.first.report["open"] as? Bool == false)
        try #require(fixture.first.report["title"] as? String == "After handoff")
        let reattachBefore = try await fixture.probes()
        fixture.first.bench("hover")
        let reattachOpen = try await fixture.laterProbe(after: reattachBefore)
        let reattachRepeat = try await fixture.laterProbe(after: reattachOpen)
        try #require(fixture.first.report["open"] as? Bool == true)
        fixture.first.bench("close")
        let closeBefore = try await fixture.probes()
        try await Task.sleep(for: .milliseconds(2250))
        let closeAfter = try await fixture.probes()
        try #require(fixture.first.report["open"] as? Bool == false && closeAfter == closeBefore,
                     "ordinary attached closing must stop the same probe source")
        try emit("reattached", ["before": reattachBefore, "opened": reattachOpen, "repeating": reattachRepeat,
                                 "closed_before": closeBefore, "closed_after": closeAfter])
    }
}
