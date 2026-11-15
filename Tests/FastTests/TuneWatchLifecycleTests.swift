import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// Real WebKit evaluation and native playback, without replacing either API.
@MainActor
@Suite(.serialized)
struct TuneWatchLifecycleTests {
    @Test func stoppingDuringAnActualPlayReplyDoesNotPauseTheRetainedPage() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["YAB_FARM_WORKER"] == "1" && env["YAB_HISTORY"] == "own")
        try #require(Store.testing && Store.unitTests && Store.world?.hasPrefix("appkit-gate-") == true,
                     "Use the isolated AppKit host, never a user's profile")
        try #require(NSApp?.isRunning == true && TuneWatch.works)

        let configuration = Web.configuration(shy: true, extensions: false)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        try #require(!configuration.websiteDataStore.isPersistent)
        let source = Fast.Tab(shy: true, configuration: configuration)
        let web = try #require(source.page.webKit)
        let watcher = TuneWatch()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        watcher.watch(web, tab: source)
        defer {
            watcher.stop()
            source.close()
            web.stopLoading()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let clip = try Data(contentsOf: root.appendingPathComponent("evals/player-pause/clip.mp4"))
        let html = """
        <!doctype html><title>Owned transport lifetime</title>
        <video id="media" loop controls src="data:video/mp4;base64,\(clip.base64EncodedString())"></video>
        <script>
        const media = document.getElementById('media');
        media.volume = 0.1;
        window.pauseEvents = 0;
        media.addEventListener('pause', () => ++window.pauseEvents);
        navigator.mediaSession.metadata = new MediaMetadata({title:'Owned transport lifetime',artist:'Local fixture'});
        navigator.mediaSession.setActionHandler('play', () => media.play());
        navigator.mediaSession.setActionHandler('pause', () => media.pause());
        </script>
        """
        web.loadHTMLString(html, baseURL: URL(string: "about:blank")!)
        let loaded = try await Loaded.until(10, every: .milliseconds(100)) {
            guard !web.isLoading else { return false }
            return try await web.evaluateJavaScript("!!window.media && media.readyState >= 2",
                                                   in: nil, contentWorld: .page) as? Bool == true
        }
        try #require(loaded, "The real local media must load")
        _ = try await web.evaluateJavaScript("media.play().catch(e => window.playError=String(e)); true",
                                            in: nil, contentWorld: .page)
        let active = try await Loaded.until(10, every: .milliseconds(100)) {
            guard web.value(forKey: "_hasActiveNowPlayingSession") as? Bool == true else { return false }
            return try await web.evaluateJavaScript("!media.paused && media.currentTime > 0",
                                                   in: nil, contentWorld: .page) as? Bool == true
        }
        try #require(active, "Actual WebKit must own a playing native session")

        func paused(_ value: Bool) async throws -> Bool {
            try await Loaded.until(6, every: .milliseconds(100)) {
                try await web.evaluateJavaScript("media.paused === \(value)",
                                                in: nil, contentWorld: .page) as? Bool == true
            }
        }
        // Positive controls establish that this watcher really reaches the
        // native fallback and that the page's playback changes through it.
        watcher.play(false)
        try #require(try await paused(true), "Current native pause must work")
        watcher.play(true)
        try #require(try await paused(false), "Current native play must work")
        let before = try await web.evaluateJavaScript("window.pauseEvents", in: nil, contentWorld: .page) as? Int
        try #require(before != nil && before! > 0)

        // No await between the real async evaluation and production stop:
        // its completion has to arrive after this lifetime ended. The page
        // stays alive and playing, so a stale native pause is observable.
        watcher.play(false)
        watcher.stop()
        _ = try await web.evaluateJavaScript("true", in: nil, contentWorld: Web.world)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            let stillPlaying = try await web.evaluateJavaScript("!media.paused", in: nil, contentWorld: .page) as? Bool
            let count = try await web.evaluateJavaScript("window.pauseEvents", in: nil, contentWorld: .page) as? Int
            #expect(stillPlaying == true && count == before,
                    "TUNE_STOP_REAL_REPLY: stopped watcher must not pause retained real media")
        }
        let after = try await web.evaluateJavaScript("window.pauseEvents", in: nil, contentWorld: .page) as? Int
        print("TUNE_STOP_REAL_REPLY before=\(before ?? -1) after=\(after ?? -1)")

        watcher.watch(web, tab: source)
        try await Task.sleep(for: .milliseconds(100))
        watcher.play(false)
        try #require(try await paused(true), "Reattached current native pause must work")
        watcher.play(true)
        try #require(try await paused(false), "Reattached current native play must work")
    }
}
