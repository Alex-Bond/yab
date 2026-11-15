import AppKit
import WebKit

// A tab's sound for an extension: chrome.tabCapture with audio, and
// getUserMedia with {audio: {mandatory: {chromeMediaSource: "tab",
// chromeMediaSourceId}}} for a stream id ExtensionCapture gave (Loom with
// sound, Volume Master, Transpose's tab mode, meeting recorders).
//
// Chrome takes a tab's sound from its output. WebKit gives an app no one
// tab's sound (ScreenCaptureKit hears Yab as a whole, and asks for Screen
// Recording), so it is taken in the page: tab-audio.js, put into each of
// the tab's frames only while it is captured, taps what the page's Web
// Audio sends to the speakers and its audio and video elements, keeps it
// from the speakers as Chrome mutes a captured tab, and sends it here;
// here it goes on to the extension's page, whose side of the share
// (share-bridge.js) mixes it into a track of its own. Nothing runs in a
// tab nobody captures.
//
// The capture shows as the picture's does: "Recorded by" the extension on
// the tab, with Stop in its menu (a Share.Session with no picture), and
// ends when the track is stopped, the tab closes, or Stop is pressed.
// Re-put after each page load, and into frames that came since, every few
// seconds.
//
// What isn't heard: sound the page started before it was captured through
// a Web Audio graph made earlier (from its next connection on it is),
// another site's file played without CORS (Web Audio would get silence of
// it, so it is left playing, not captured), and protected media (EME).

@MainActor
enum ExtensionTabAudio {
    final class Session {
        let id: String
        weak var tab: Tab?
        weak var consumer: WKWebView?
        let frame: WKFrameInfo
        var frames: Set<String> = []
        var watches: [NSKeyValueObservation] = []
        var timer: Timer?
        /// Chunks handed to the extension's page and not yet taken there.
        var sending = 0

        init(id: String, tab: Tab, consumer: WKWebView, frame: WKFrameInfo) {
            self.id = id
            self.tab = tab
            self.consumer = consumer
            self.frame = frame
        }
    }

    private(set) static var sessions: [String: Session] = [:]
    static let tap = PageScript.load("tab-audio", vars: ["ASKED": ShareScript.asked])

    /// The extension's page asked for the sound a stream id names: only a
    /// tab's, picked in the box or the one it was invoked on.
    /// `caller`: the extension's own tab that asked, which then says
    /// Recording; nil for its offscreen document.
    static func start(_ grant: ExtensionCapture.Grant, consumer: WKWebView, caller: Tab? = nil, frame: WKFrameInfo, token: String,
                      answer: @escaping ([String: Any]) -> Void) {
        guard case .tab(let tabID) = grant.source,
              let tab = BrowserWindows.shared.browsers.lazy.flatMap(\.everyTab).first(where: { $0.id == tabID }),
              let browser = BrowserWindows.shared.browsers.first(where: { $0.everyTab.contains { $0 === tab } })
        else { return answer(["choice": "cancel"]) }
        guard let web = tab.webKitOnly("Legacy WebKit extension audio") else {
            return answer(["choice": "cancel"])
        }
        let id = UUID().uuidString
        let session = Session(id: id, tab: tab, consumer: consumer, frame: frame)
        sessions[id] = session
        // The tab says it is recorded, as for the picture, and its menu's
        // Stop ends this.
        let shown = Share.Session(id: id, caller: caller, browser: browser, frame: frame, source: nil, page: caller == nil ? consumer : nil)
        shown.shown = tab
        shown.recorder = grant.extensionName
        Share.shared.add(shown)
        answer(["choice": "sound", "id": id, "label": grant.label])
        arm(session, everywhere: true)
        session.watches.append(web.observe(\.isLoading, options: [.new]) { web, _ in
            let loading = web.isLoading
            MainActor.assumeIsolated {
                guard !loading, let session = sessions[id] else { return }
                session.frames = []
                arm(session, everywhere: true)
            }
        })
        session.timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let session = sessions[id] else { return }
                guard session.tab != nil, session.consumer != nil else { return stop(id) }
                arm(session, everywhere: false)
            }
        }
    }

    /// The tap into the tab's main frame (`everywhere`) and every frame not
    /// armed yet in this page.
    private static func arm(_ session: Session, everywhere: Bool, on: Bool = true) {
        guard let web = session.tab?.webKitOnly("Legacy WebKit extension audio", build: false) else { return }
        let arguments: [String: Any] = ["id": session.id, "on": on]
        if everywhere { web.callAsyncJavaScript(tap, arguments: arguments, in: nil, in: .page) { _ in } }
        web.webKitSubframes { frames in
            for frame in frames {
                let key = "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host)|\(frame.request.url?.absoluteString ?? "")"
                guard everywhere || !on || !session.frames.contains(key) else { continue }
                if on { session.frames.insert(key) }
                web.callAsyncJavaScript(tap, arguments: arguments, in: frame, in: .page) { _ in }
            }
        }
    }

    /// What a captured tab's frame heard (tab-audio.js), to the extension's
    /// page. Only from the tab captured under that id.
    static func heard(_ tab: Tab, _ body: [String: Any]) {
        guard let id = body["id"] as? String, let session = sessions[id], session.tab === tab,
              let consumer = session.consumer, let from = body["src"] as? String,
              let rate = body["rate"] as? Double, let data = body["data"] as? String,
              // What tab-audio.js sends: 4096 frames, stereo, 16-bit.
              (3_000...384_000).contains(rate), data.utf8.count <= 64_000, from.count <= 64 else { return }
        // A page that stopped taking them (asleep, gone) isn't buried: past
        // a second's worth behind, what comes is let go.
        guard session.sending < 24 else { return }
        session.sending += 1
        consumer.callAsyncJavaScript(ShareScript.transport("api.sound(id, from, rate, data)"),
                                     arguments: ["id": id, "from": from, "rate": rate, "data": data],
                                     in: session.frame, in: Web.world) { _ in
            MainActor.assumeIsolated { sessions[id]?.sending -= 1 }
        }
    }

    /// The capture over: the tap lets the tab be heard again, the track
    /// ends in the extension's page, the tab no longer says it is recorded.
    static func stop(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.timer?.invalidate()
        session.watches = []
        arm(session, everywhere: true, on: false)
        Share.shared.end(id, tellPage: true)
    }
}
