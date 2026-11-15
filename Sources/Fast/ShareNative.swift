import AppKit
import ScreenCaptureKit
import YabCoreClient

// A page in Chromium is shown what Yab's box picked by Chromium's own capture
// (patch 0052): the box answers, the engine takes the picture. That is what
// gives a page Chrome's tab sound, a tab that keeps drawing behind others, a
// screen's whole pixels and a track that is a real screencast. ShareFeed stays
// for what the engine can't reach: a WebKit tab, and without Screen Recording
// a Yab window, which Yab can take and Chromium can't.

extension Share {
    /// How the helper names what was picked; nil where the engine can't take it.
    @MainActor
    static func nativeSource(_ source: Source, in browser: Browser, sees: Bool) -> [String: JSONValue]? {
        switch source {
        case .tab(let id):
            guard let page = browser.everyTab.first(where: { $0.id == id })?.builtPage as? ChromiumPage,
                  let remote = page.remoteID else { return nil }
            return ["source": .string("tab"), "sourceTab": .string(remote)]
        case .window(let number):
            guard sees else { return nil }
            return ["source": .string("window"), "id": .number(Double(number))]
        case .display(let number):
            guard sees else { return nil }
            return ["source": .string("screen"), "id": .number(Double(number))]
        }
    }

    /// The engine's word on what this page shows: a share it has ended by
    /// itself (the shown tab or window closed, a page's clone stopped, a
    /// navigation, macOS's own Stop) ends here too.
    func nativeCapture(of page: ChromiumPage, showing: Bool) {
        for session in sessions.values where session.native && session.caller?.builtPage === page {
            if showing { session.nativeLive = true }
            else if session.nativeLive { end(session.id, tellPage: false) }
        }
    }
}

extension Browser {
    /// `done(false)`: nothing was asked of the engine, the feed's turn.
    func shareNative(_ tab: Tab, _ picker: SharePicker, _ source: Share.Source, done: @escaping (Bool) -> Void) {
        guard let frame = picker.frame, let page = tab.builtPage as? ChromiumPage,
              let params = Share.nativeSource(source, in: self, sees: picker.sees) else { return done(false) }
        let id = UUID().uuidString
        let session = Share.Session(id: id, caller: tab, browser: self, frame: frame, source: source, token: picker.token)
        session.native = true
        session.hearing = picker.hears(source)
        if case .tab(let shown) = source { session.shown = everyTab.first { $0.id == shown } }
        var origin = frame.origin
        if origin.scheme.isEmpty, let url = tab.address, let scheme = url.scheme, let host = url.host() {
            origin = PageOrigin(scheme: scheme, host: host, port: url.port ?? 0)
        }
        Task { @MainActor in
            guard await page.grantDisplaySource(params, origin: origin, audio: session.hearing) else { return done(false) }
            guard tab.builtPage === page else { return }
            Share.shared.add(session)
            done(true)
            page.call(ShareScript.call("api.native(t, id)"), arguments: ["t": picker.token, "id": id], in: .page, frame: frame) { result in
                if (try? result.get()) as? Bool != true { Share.shared.end(id, tellPage: false) }
            }
        }
    }

    /// The page has its track. A tab shown comes forward,
    /// unless the page asked it not to, and wears the frame and the pill.
    func nativeStarted(_ session: Share.Session, stay: Bool) {
        session.nativeLive = true
        guard case .tab = session.source, let shown = session.shown else { return }
        if !stay { select(shown) }
        Share.shared.follow(session)
    }
}

/// macOS's own picker for a Chromium page, where Screen Recording is off: it
/// hands back a filter that needs no permission, and ShareFeed takes that.
/// WebKit goes through its own getDisplayMedia instead; Chromium's would open
/// Chrome's picker, which a page in Yab never gets.
final class ShareSystemPicker: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    static let shared = ShareSystemPicker()
    private var answer: (@MainActor (SCContentFilter?) -> Void)?
    private var quitting: NSObjectProtocol?

    @MainActor
    func present(windows: Bool, done: @escaping @MainActor (SCContentFilter?) -> Void) {
        answer?(nil)
        answer = done
        let picker = SCContentSharingPicker.shared
        var look = SCContentSharingPickerConfiguration()
        look.allowedPickerModes = windows ? [.singleWindow, .singleApplication] : [.singleDisplay]
        picker.defaultConfiguration = look
        picker.add(self)
        picker.isActive = true
        // Left up by an app that quits, macOS's picker stays over every screen.
        quitting = quitting ?? NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            SCContentSharingPicker.shared.isActive = false
        }
        picker.present()
    }

    private func finish(_ filter: SCContentFilter?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let done = answer
                answer = nil
                let picker = SCContentSharingPicker.shared
                picker.remove(self)
                picker.isActive = false
                done?(filter)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) { finish(nil) }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) { finish(filter) }
    func contentSharingPickerStartDidFailWithError(_ error: any Error) { finish(nil) }
}

extension Browser {
    /// macOS's picker for a Chromium page: its answer goes through ShareFeed.
    func sharePicked(_ tab: Tab, frame: PageFrame, token: String, most: CGSize?, windows: Bool) {
        ShareSystemPicker.shared.present(windows: windows) { [weak self, weak tab] filter in
            guard let self, let tab else { return }
            guard let filter else { return self.shareRefused(tab, frame, token) }
            let id = UUID().uuidString
            let session = Share.Session(id: id, caller: tab, browser: self, frame: frame, source: .window(0), token: token)
            session.most = most
            let scale = CGFloat(filter.pointPixelScale), size = filter.contentRect.size
            let pixels = ShareFeed.pixels(size, scale: scale, most: most)
            Share.shared.add(session)
            self.shareAccepted(tab, frame, token, ["choice": "own", "id": id, "surface": filter.style == .window ? "window" : "monitor",
                                                   "label": "", "width": pixels.width, "height": pixels.height]) { ready in
                guard ready else { return Share.shared.end(id, tellPage: false) }
                guard Share.shared.sessions[id] === session else { return }
                Share.shared.start(session, filter, rect: nil, points: size, scale: scale, cursor: true)
            }
        }
    }
}
