import AppKit
import Testing
import WebKit
@testable import Fast

/// #263: opening a closed MacBook, before Touch ID, videos played sound.
/// WebKit plays again on wake what the Mac's sleep stopped; Yab pauses every
/// page as the Mac goes to sleep, and again on wake.
@MainActor
@Suite(.serialized)
struct SleepHushTests {
    @Test func sleepAndWakeAlsoPauseAttachedChromiumPages() {
        let center = NotificationCenter(), hush = SleepHush(center: center)
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        var live = [page], paused: [ObjectIdentifier] = []
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        hush.remotePages = { live }
        hush.pauseRemote = { paused.append(ObjectIdentifier($0)) }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(paused == [ObjectIdentifier(page), ObjectIdentifier(page)])
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(paused.count == 2)
        live = []
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(paused.count == 2, "a detached page is not recreated on wake")
    }

    @Test func sleepAndWakePauseEveryLivePage() {
        let center = NotificationCenter()
        let hush = SleepHush(center: center)
        var paused: [ObjectIdentifier] = []
        hush.pause = { paused.append(ObjectIdentifier($0)) }
        let config = WKWebViewConfiguration()
        let one = WKWebView(frame: .zero, configuration: config)
        let two = WKWebView(frame: .zero, configuration: config)
        hush.pages.add(one)
        hush.pages.add(two)
        // Nothing is touched until the Mac sleeps.
        #expect(paused.isEmpty)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(Set(paused) == [ObjectIdentifier(one), ObjectIdentifier(two)])
        #expect(paused.count == 2)
        // On wake, again: a pause that left as the Mac went down may land
        // after WebKit's own resume.
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(paused.count == 4)
        #expect(hush.hushes == 2)
        // A lock or a display asleep with the Mac awake leaves music alone.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            center.post(name: name, object: nil)
        }
        #expect(paused.count == 4)
    }

    @Test func everyPageViewIsKnown() {
        let page = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(SleepHush.shared.pages.contains(page))
    }

    /// The real thing: a page playing in a tab's web view is paused by the
    /// Mac's sleep, and wake leaves it paused.
    @Test func playingPageIsPausedBySleepAndStaysPausedOnWake() async throws {
        let center = NotificationCenter()
        let hush = SleepHush(center: center)
        let config = Web.configuration(shy: true)
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        hush.pages.add(web)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        // A silent WAV plays indefinitely, without network or audible output.
        web.loadHTMLString("""
        <audio id="audio" loop></audio><script>
        const data = new Uint8Array(8044), v = new DataView(data.buffer);
        for (const [p,s] of [[0,'RIFF'],[8,'WAVE'],[12,'fmt '],[36,'data']]) for(let i=0;i<s.length;i++) data[p+i]=s.charCodeAt(i);
        v.setUint32(4,8036,true); v.setUint32(16,16,true); v.setUint16(20,1,true); v.setUint16(22,1,true);
        v.setUint32(24,8000,true); v.setUint32(28,8000,true); v.setUint16(32,1,true); v.setUint16(34,8,true); v.setUint32(40,8000,true);
        data.fill(128,44); const player=document.getElementById('audio');
        player.src=URL.createObjectURL(new Blob([data],{type:'audio/wav'}));
        player.play().catch(e=>window.playbackFailure=e.message);
        </script>
        """, baseURL: URL(string: "https://example.test/sleep"))
        for _ in 0..<100 {
            if await web.requestMediaPlaybackState() == .playing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let before = await web.requestMediaPlaybackState()
        let diagnostic = try? await web.evaluateJavaScript("JSON.stringify({failure:window.playbackFailure, ready:document.querySelector('audio')?.readyState, paused:document.querySelector('audio')?.paused})")
        #expect(before == .playing, "Media fixture: \(String(describing: diagnostic))")

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<60 {
            if await web.requestMediaPlaybackState() == .paused { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await web.requestMediaPlaybackState() == .paused)
        #expect(try await web.evaluateJavaScript("document.querySelector('audio').paused") as? Bool == true)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await web.requestMediaPlaybackState() == .paused)
        #expect(try await web.evaluateJavaScript("document.querySelector('audio').paused") as? Bool == true)
    }
}
