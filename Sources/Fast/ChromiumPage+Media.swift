import AppKit
import YabCoreClient

// A Chromium tab's sound, Now Playing, camera and microphone, and its page's
// own full screen, from YabCore's media events (YabCore/src/media.inc).
//
// The speaker in the column and Tune/PlayerBand read the same tab fields as
// for WebKit: `noisy` and `heardAt`, and the tune TuneWatch keeps. With Yab's
// own CEF the sound is the browser's native audible state; on the prebuilt
// one it is the page's media elements playing unmuted (`native` says which).

/// One YabCore `media.state` report, bounded and typed.
struct ChromiumMediaReport: Equatable {
    struct Session: Equatable {
        var title = "", artist = "", album = ""
        var artwork: [URL] = []
    }
    struct Media: Equatable {
        /// Seconds, -1 when unknown.
        var time: Double = -1
        var duration: Double = -1
        var paused = true, muted = false, loop = false, video = false
    }
    var audible = false
    var playing = false
    var native = false
    var session: Session?
    var sessionState = "none"
    var hideMetadata = false
    var media: Media?

    init() {}

    init(_ p: [String: JSONValue]) {
        audible = p["audible"] == .bool(true)
        playing = p["playing"] == .bool(true)
        native = p["audibleSource"]?.string == "native"
        sessionState = String((p["sessionState"]?.string ?? "none").prefix(16))
        if let s = p["session"]?.object {
            var session = Session()
            session.title = String((s["title"]?.string ?? "").prefix(1024))
            session.artist = String((s["artist"]?.string ?? "").prefix(1024))
            session.album = String((s["album"]?.string ?? "").prefix(1024))
            if case .array(let rows)? = s["artwork"] {
                session.artwork = rows.prefix(16).compactMap { row in
                    guard let raw = row["src"].string, let url = URL(string: raw),
                          ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                    return url
                }
            }
            self.session = session
        }
        if let m = p["media"]?.object {
            func number(_ key: String) -> Double {
                guard let v = m[key]?.number, v.isFinite, v >= 0 else { return -1 }
                return v
            }
            media = Media(time: number("t"), duration: number("d"), paused: m["paused"] != .bool(false),
                          muted: m["muted"] == .bool(true), loop: m["loop"] == .bool(true), video: m["video"] == .bool(true))
        }
    }
}

@MainActor
final class ChromiumMedia {
    fileprivate(set) var report = ChromiumMediaReport()
    var nativeSession: ChromiumNativeMediaSession?
    var nativeSessionKnown = false
    var nativeSessionRevision: UInt64 = 0
    var nativeCapture: ChromiumNativeCapture?
    var nativeCaptureKnown = false
    var nativeCaptureRevision: UInt64 = 0
    fileprivate(set) var screen: PageMediaState = .none
    var rawReport = ChromiumMediaReport()
    fileprivate(set) var camera: PageMediaState = .none
    fileprivate(set) var microphone: PageMediaState = .none
    /// The page holds the screen, lent to `ChromiumFullscreen`'s window.
    fileprivate(set) var fullscreen = false
    fileprivate var presenter: ChromiumFullscreen?
    var captureStatus: PageCaptureStatus { PageCaptureStatus(camera: camera, microphone: microphone, screen: screen) }
    nonisolated init() {}
}

extension ChromiumPage {
    func receiveMedia(_ event: YabCoreEvent) { receiveMedia(event.name, event.params) }

    func receiveMedia(_ name: String, _ params: [String: JSONValue]) {
        switch name {
        case "media.session.changed": receiveNativeMediaSession(params)
        case "media.capture.changed": receiveNativeCapture(params)
        case "media.state":
            let report = ChromiumMediaReport(params)
            receiveNativeAudible(report)
        case "media.capture":
            guard !media.nativeCaptureKnown else { return }
            let camera: PageMediaState = params["camera"] == .bool(true) ? .active : .none
            let microphone: PageMediaState = params["microphone"] == .bool(true) ? .active : .none
            if camera != media.camera { media.camera = camera; stateEvents?.page(self, changed: .camera(camera)) }
            if microphone != media.microphone { media.microphone = microphone; stateEvents?.page(self, changed: .microphone(microphone)) }
        case "page.fullscreen":
            let on = params["fullscreen"] == .bool(true)
            if on { enterPageFullscreen() } else { leavePageFullscreen() }
        default: break
        }
    }

    func applyNativeCapture(_ capture: ChromiumNativeCapture) {
        let camera: PageMediaState = capture.camera ? .active : .none
        let microphone: PageMediaState = capture.microphone ? .active : .none
        media.screen = capture.screen ? .active : .none
        if camera != media.camera { media.camera = camera; stateEvents?.page(self, changed: .camera(camera)) }
        if microphone != media.microphone { media.microphone = microphone; stateEvents?.page(self, changed: .microphone(microphone)) }
    }

    func receiveNativeAudible(_ incoming: ChromiumMediaReport) {
        media.rawReport = incoming
        var report = incoming
        if media.nativeSessionKnown {
            // A retired or unavailable native owner cannot expose older
            // renderer metadata while waiting for the next native session.
            report.session = nil; report.sessionState = "none"
            report.hideMetadata = true
        }
        if let native = media.nativeSession {
            report.session = .init(title: native.title, artist: native.artist, album: native.album, artwork: native.artwork)
            report.sessionState = native.playback
            report.playing = native.playback == "playing"
            report.hideMetadata = native.hideMetadata
            if let position = native.position, let duration = native.duration {
                var current = report.media ?? .init()
                current.time = position; current.duration = duration
                current.paused = native.playback != "playing"
                report.media = current
            }
        }
        media.report = report
        guard let tab = navigationTab, tab.builtPage === self else { return }
        if tab.noisy != report.audible {
            if !report.audible { tab.heardAt = Date() }
            tab.noisy = report.audible
        }
        tab.tuneWatch.chromium(report, page: self, tab: tab)
        ChromiumNowPlaying.shared.receive(report, page: self)
    }

    /// Play, pause or a time in seconds, to the frame whose media leads.
    func mediaAction(_ action: String, value: Double? = nil) {
        if routeNativeMediaAction(action, value: value) { return }
        var params: [String: JSONValue] = ["action": .string(action)]
        if let value { params["value"] = .number(value) }
        command("media.action", params)
    }

    /// Asks Chromium to give the screen back; `page.fullscreen` follows.
    func exitPageFullscreen() {
        command("page.exitFullscreen")
    }

    /// The page and its helper are gone: nothing plays, nothing captures,
    /// and a full screen it held is given back.
    func mediaEnded() {
        endNativeVideoPiP()
        ChromiumNowPlaying.shared.ended(self)
        let tab = navigationTab.flatMap { $0.builtPage === self ? $0 : nil }
        media.nativeSessionRevision &+= 1
        media.nativeCaptureRevision &+= 1
        media.nativeSession = nil
        media.nativeSessionKnown = false
        media.nativeCapture = nil
        media.nativeCaptureKnown = false
        media.screen = .none
        media.rawReport = ChromiumMediaReport()
        media.report = ChromiumMediaReport()
        if media.camera != .none { media.camera = .none; stateEvents?.page(self, changed: .camera(.none)) }
        if media.microphone != .none { media.microphone = .none; stateEvents?.page(self, changed: .microphone(.none)) }
        leavePageFullscreen()
        if let tab, tab.noisy { tab.heardAt = Date(); tab.noisy = false }
        tab?.tuneWatch.stop()
    }

    private func enterPageFullscreen() {
        guard !media.fullscreen, window != nil else { return }
        media.fullscreen = true
        media.presenter = ChromiumFullscreen(page: self)
        stateEvents?.page(self, changed: .fullscreen(true))
    }

    private func leavePageFullscreen() {
        guard media.fullscreen else { return }
        if let presenter = media.presenter {
            // NSWindow's delegate is weak. Keep the presenter until its
            // asynchronous exit callback returns the live page to its stage.
            presenter.giveBack()
            return
        }
        media.fullscreen = false
        stateEvents?.page(self, changed: .fullscreen(false))
    }

    fileprivate func returnedFromFullscreen(_ presenter: ChromiumFullscreen) {
        guard media.presenter === presenter else { return }
        media.presenter = nil
        media.fullscreen = false
        stateEvents?.page(self, changed: .fullscreen(false))
    }

    var fullscreenState: [String: Any] {
        ["fullscreen": media.fullscreen, "window": media.presenter?.window.windowNumber ?? 0,
         "windowFullScreen": media.presenter?.window.styleMask.contains(.fullScreen) ?? false,
         "pageWindow": window?.windowNumber ?? 0, "size": [bounds.width, bounds.height]]
    }
}

/// A Chromium page's own full screen, a video's or a game's, in a window of
/// Yab's own on a Space of its own, as WebKit lends its page to
/// WebCoreFullScreenWindow. The window it came from stays usable; the page
/// goes back to its stage when Chromium gives the screen back (Escape, the
/// player's button, the green button or ⌃⌘F on this window).
@MainActor
final class ChromiumFullscreen: NSObject, NSWindowDelegate {
    let window: NSWindow
    private weak var page: ChromiumPage?
    private weak var stage: NSView?
    private var returning = false

    init(page: ChromiumPage) {
        self.page = page
        stage = page.superview
        let source = page.window
        let frame = source?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.title = page.title ?? ""
        window.setFrame(frame, display: false)
        window.delegate = self
        let content = window.contentView ?? NSView()
        page.removeFromSuperview()
        page.frame = content.bounds
        page.autoresizingMask = [.width, .height]
        content.addSubview(page)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(page)
        window.toggleFullScreen(nil)
    }

    /// Back to its stage, after this window leaves full screen.
    func giveBack() {
        guard !returning else { return }
        returning = true
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { finish() }
    }

    private func finish() {
        guard window.isVisible || page?.window === window else { return }
        if let page, page.window === window {
            page.removeFromSuperview()
            page.autoresizingMask = []
        }
        window.orderOut(nil)
        window.delegate = nil
        page?.returnedFromFullscreen(self)
        // The stage takes its page back on its next layout, if it still
        // shows this tab; another tab chosen meanwhile keeps its place.
        stage?.needsLayout = true
        stage?.layoutSubtreeIfNeeded()
        stage?.window?.makeKeyAndOrderFront(nil)
        if let page, page.window != nil { page.window?.makeFirstResponder(page) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if returning { finish(); return }
        // Left by the green button, ⌃⌘F or Mission Control: Chromium too.
        page?.exitPageFullscreen()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        if returning { finish() } else { page?.exitPageFullscreen() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        page?.exitPageFullscreen()
        return false
    }
}
