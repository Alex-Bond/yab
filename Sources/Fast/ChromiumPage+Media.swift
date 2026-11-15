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
    /// Any media playing, a muted preview's too: not sound.
    var playing = false
    /// This document was heard (`ChromiumMedia.heard`): only then is there
    /// something to offer play or pause for, in the hover card, the band
    /// and macOS Now Playing.
    var heard = false
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
                session.artwork = NowPlayingArtwork.ranked(Array(rows.prefix(16))).compactMap { row in
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
    var fullscreen: Bool { presenter != nil }
    var permitsAutomaticPiP: Bool { presenter == nil }
    fileprivate var presenter: ChromiumFullscreen?
    /// The page made a sound, and its media or session is still there to be
    /// played again. A muted video playing on its own (a search's result
    /// previews), or a MediaSession a page sets up with nothing playing, is
    /// not heard: as with WebKit's Now Playing session and Arc, a tab that
    /// never made a sound has no Play or Paused (row 3105).
    fileprivate var heard = false
    /// The native session document it was heard in: another document of
    /// the tab starts unheard.
    fileprivate var heardDocument: String?
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
            if Store.testing { FileHandle.standardError.write(Data("YAB_FS_TRACE page.fullscreen \(on) held=\(media.fullscreen)\n".utf8)) }
            if on { enterPageFullscreen() } else { leavePageFullscreen() }
        default: break
        }
    }

    func applyNativeCapture(_ capture: ChromiumNativeCapture) {
        let camera: PageMediaState = capture.camera ? .active : .none
        let microphone: PageMediaState = capture.microphone ? .active : .none
        media.screen = capture.screen ? .active : .none
        Share.shared.nativeCapture(of: self, showing: capture.screen)
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
        let document = media.nativeSession?.document
        if let document, let before = media.heardDocument, before != document { media.heard = false; media.heardDocument = nil }
        if report.audible { media.heard = true }
        if report.media == nil, report.session == nil { media.heard = false; media.heardDocument = nil }
        if media.heard, media.heardDocument == nil { media.heardDocument = document }
        report.heard = media.heard
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
        media.heard = false
        media.heardDocument = nil
        if media.camera != .none { media.camera = .none; stateEvents?.page(self, changed: .camera(.none)) }
        if media.microphone != .none { media.microphone = .none; stateEvents?.page(self, changed: .microphone(.none)) }
        leavePageFullscreen()
        if let tab, tab.noisy { tab.heardAt = Date(); tab.noisy = false }
        tab?.tuneWatch.stop()
    }

    private func enterPageFullscreen() {
        if let presenter = media.presenter {
            presenter.request(true)
            return
        }
        guard window != nil else {
            // No visible presentation can own this request. Settle Chromium's
            // accepted request too, rather than leaving its DOM fullscreen.
            exitPageFullscreen()
            return
        }
        let presenter = ChromiumFullscreen(page: self)
        // Install the owner before reparenting can emit window/occlusion
        // notifications. Every consumer reads this same session's lifetime.
        media.presenter = presenter
        presenter.present()
        stateEvents?.page(self, changed: .fullscreen(true))
    }

    private func leavePageFullscreen() {
        // The delegate is weak: the media owner retains this session until
        // AppKit has completed the return, including a mid-entry exit.
        media.presenter?.request(false)
    }

    fileprivate func returnedFromFullscreen(_ presenter: ChromiumFullscreen) {
        guard media.presenter === presenter else { return }
        media.presenter = nil
        stateEvents?.page(self, changed: .fullscreen(false))
    }

    var fullscreenState: [String: Any] {
        ["fullscreen": media.fullscreen, "requested": media.presenter?.requested ?? false,
         "phase": media.presenter?.phase ?? "idle", "window": media.presenter?.window.windowNumber ?? 0,
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
    private var state: ChromiumFullscreenState
    var requested: Bool { state.requested }
    var phase: String { state.phase.rawValue }
    private let sourceFrame: NSRect
    private var ownsWindow: Bool { state.ownsWindow }
    private var sourceExit: NSObjectProtocol?

    init(page: ChromiumPage) {
        self.page = page
        stage = page.superview
        let source = page.window
        let frame = source?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        sourceFrame = frame
        let borrowed = source?.styleMask.contains(.fullScreen) == true
        state = ChromiumFullscreenState(ownsWindow: !borrowed)
        if let source, borrowed {
            // A native fullscreen window already owns this Space. Present
            // the page above its browser chrome in that same window;
            // macOS cannot enter a second primary fullscreen window here.
            window = source
        } else {
            // AppKit must know the source display when it creates the host,
            // before that host becomes a fullscreen primary window.
            window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: source?.screen)
        }
        super.init()
    }

    /// Only called after ChromiumMedia has installed this session.
    func present() {
        guard let page else { return }
        if !ownsWindow {
            if let content = window.contentView {
                page.removeFromSuperview()
                page.frame = content.bounds
                page.autoresizingMask = [.width, .height]
                content.addSubview(page)
            }
            window.makeFirstResponder(page)
            sourceExit = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.page?.exitPageFullscreen() }
            }
            return
        }
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.title = page.title ?? ""
        window.setFrame(sourceFrame, display: false)
        window.delegate = self
        let content = window.contentView ?? NSView()
        page.removeFromSuperview()
        page.frame = content.bounds
        page.autoresizingMask = [.width, .height]
        content.addSubview(page)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(page)
        drive()
    }

    /// macOS draws the move into full screen from the window as the screen
    /// shows it. Asked in the very turn this window was made, before the
    /// window server had it on screen, the move started from nothing at the
    /// screen's bottom-left corner: a white window, then the page growing
    /// out of that corner (#1854, register 2304). The window says when it
    /// is in sight, and the move starts from where it stands.
    private var shown: NSObjectProtocol?
    private func drive() {
        switch state.next(visible: window.occlusionState.contains(.visible)) {
        case .none: break
        case .enter, .exit:
            trace("nativeToggle")
            window.toggleFullScreen(nil)
        case .returnPage: finish(); return
        }
        if state.phase == .waiting {
            guard shown == nil else { return }
            shown = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.drive() }
            }
        } else {
            stopWaitingToEnter()
        }
    }

    /// Native completion callbacks run while AppKit is ending the slide.
    /// Reconcile the latest target on its next turn, as Chromium does; this
    /// is a transition completion, never a timed retry of a failed toggle.
    private func afterNativeTransition(entered: Bool) {
        trace("completionQueued")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Keep the phase in flight until AppKit has returned from its
            // delegate callback. A renderer event in that callback's turn
            // changes only the target and cannot start a conflicting toggle.
            self.trace("completionDelivered")
            if entered { self.state.entered() } else { self.state.exited() }
            self.drive()
        }
    }

    private func stopWaitingToEnter() {
        if let shown { NotificationCenter.default.removeObserver(shown); self.shown = nil }
    }

    func request(_ fullscreen: Bool) {
        state.request(fullscreen)
        trace("request \(fullscreen)")
        drive()
    }

    private func finish() {
        trace("returnBegin")
        let restoreFocus = stage?.window.map { $0.isVisible && !$0.isMiniaturized && !NSApp.isHidden } ?? false
        if let page, page.superview === window.contentView {
            page.removeFromSuperview()
            page.autoresizingMask = []
        }
        if let sourceExit { NotificationCenter.default.removeObserver(sourceExit); self.sourceExit = nil }
        stopWaitingToEnter()
        if ownsWindow {
            window.orderOut(nil)
            window.delegate = nil
        }
        trace("hostRetired")
        page?.returnedFromFullscreen(self)
        if let page, let holder = stage as? PageHolder { holder.returnFromFullscreen(page) }
        // The stage takes its page back on its next layout, if it still
        // shows this tab; another tab chosen meanwhile keeps its place.
        stage?.needsLayout = true
        stage?.layoutSubtreeIfNeeded()
        trace("stageLaidOut")
        // The source can close or hide before Chromium's exit arrives.
        // Returning its page must preserve that window's visibility.
        if restoreFocus {
            stage?.window?.makeKeyAndOrderFront(nil)
            if let page, page.window != nil { page.window?.makeFirstResponder(page) }
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        trace("didEnter")
        afterNativeTransition(entered: true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        if state.windowAskedToExit() { page?.exitPageFullscreen() }
        trace("willExit")
    }

    /// The bench's record of this window's moves (a --test run only).
    private func trace(_ event: String) {
        guard Store.testing else { return }
        StageView.mark("fullscreen." + event, ["number": window.windowNumber,
            "source": stage?.window?.windowNumber ?? 0, "pageWindow": page?.window?.windowNumber ?? 0,
            "phase": state.phase.rawValue, "requested": state.requested,
            "size": page.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? []])
        FileHandle.standardError.write(Data("YAB_FS_TRACE \(event) full=\(window.styleMask.contains(.fullScreen)) target=\(state.requested) phase=\(state.phase.rawValue)\n".utf8))
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        trace("didExit")
        afterNativeTransition(entered: false)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        state.failedToEnter()
        trace("failToEnter")
        page?.exitPageFullscreen()
        drive()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        page?.exitPageFullscreen()
        return false
    }
}
