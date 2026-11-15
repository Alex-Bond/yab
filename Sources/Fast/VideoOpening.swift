import AppKit
import Combine
import WebKit

/// A background link gets one chance to retry its blocked main video on
/// first display. No navigation or document-wide playback policy is held.
@MainActor
final class VideoOpening {
    private(set) var armed = false
    private(set) var shown = false
    private(set) var blocked = false
    private(set) var generation = 0
    private var reading = false
    private var started = false
    private var destination: URL?

    func open(_ url: URL?) {
        cancel()
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        destination = url
        armed = true
    }

    @discardableResult
    func going(to url: URL) -> Bool {
        guard shown || (armed && destination != url) else { return false }
        cancel()
        return true
    }

    @discardableResult
    func navigationStarted() -> Bool {
        guard armed || shown else { return false }
        if started || !armed { cancel(); return true }
        started = true
        return false
    }

    func prevented() { if armed { blocked = true } }

    func update(front: Bool, active: Bool) {
        if shown, !front || !active { cancel(); return }
        if armed, front, active { shown = true }
    }

    func begin(front: Bool, active: Bool) -> Int? {
        update(front: front, active: active)
        guard armed, shown, front, active, blocked, !reading else { return nil }
        reading = true
        return generation
    }

    func finish(_ ticket: Int, front: Bool, active: Bool, blockedMainVideo: Bool) -> Bool {
        guard ticket == generation else { return false }
        reading = false
        update(front: front, active: active)
        guard armed, shown, front, active, blocked, blockedMainVideo else { return false }
        armed = false
        return true
    }

    func cancel() {
        generation &+= 1
        armed = false
        shown = false
        started = false
        blocked = false
        reading = false
        destination = nil
    }

    static let script = WKUserScript(source: PageScript.load("video-opening"), injectionTime: .atDocumentStart,
                                     forMainFrameOnly: true, in: .page)
    static let probe = "window.__yabVideoOpening ? window.__yabVideoOpening.probe() : false"
    static let play = "window.__yabVideoOpening && window.__yabVideoOpening.play()"
    static let stop = "window.__yabVideoOpening && window.__yabVideoOpening.cancel()"
}

extension Tab {
    func prepareVideoOpening(_ url: URL?) {
        guard !bench else { return }
        videoOpening.open(url)
        built?.watchVideoOpening()
    }

    func cancelVideoOpening() {
        let watching = videoOpening.armed || videoOpening.shown
        videoOpening.cancel()
        if watching { built?.evaluateQuietly(VideoOpening.stop) }
        built?.videoOpeningWatches.removeAll()
    }
}

extension PageView {
    var videoOpeningFront: Bool {
        guard let tab = stateEvents as? Tab, !tab.bench, !tab.gone, tab.built === self,
              tab.videoOpeningFront?() == true,
              let stage = superview as? StageView, stage.shows == tab.id,
              let window, window.isVisible, window.isKeyWindow, window.identifier != Bench.roomID,
              !isHiddenOrHasHiddenAncestor else { return false }
        return true
    }

    func watchVideoOpening() {
        guard videoOpeningWatches.isEmpty, (stateEvents as? Tab)?.videoOpening.armed == true else { return }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didResignActiveNotification ||
                        (name == NSWindow.didResignKeyNotification && (note.object as? NSWindow) === self.window) {
                        if let tab = self.stateEvents as? Tab, tab.videoOpening.shown { tab.cancelVideoOpening() }
                    } else { self.updateVideoOpening() }
                }
            }.store(in: &videoOpeningWatches)
        }
        DispatchQueue.main.async { [weak self] in self?.updateVideoOpening() }
    }

    func updateVideoOpening() {
        guard let tab = stateEvents as? Tab else { return }
        let opening = tab.videoOpening
        let first = !opening.shown
        let generation = opening.generation
        opening.update(front: videoOpeningFront, active: NSApp.isActive)
        if generation != opening.generation {
            endVideoOpening()
            return
        }
        if first, opening.shown {
            // A slow or consent page never keeps a playback request alive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak tab] in
                guard let self, let tab, tab.built === self, tab.videoOpening.generation == generation else { return }
                tab.cancelVideoOpening()
                self.videoOpeningWatches.removeAll()
            }
        }
        guard let ticket = opening.begin(front: videoOpeningFront, active: NSApp.isActive) else { return }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, tab.built === self, tab.videoOpening.generation == ticket,
                  self.videoOpeningFront, NSApp.isActive else { return }
            self.evaluateQuietly(VideoOpening.probe) { [weak self, weak tab] value, _ in
                guard let self, let tab, tab.built === self else { return }
                let play = tab.videoOpening.finish(ticket, front: self.videoOpeningFront, active: NSApp.isActive,
                                                   blockedMainVideo: value as? Bool == true)
                if tab.videoOpening.generation != ticket { self.endVideoOpening() }
                guard play else { return }
                // The public call carries a user gesture only for this video.
                // The script rechecks visibility and the exact probed element.
                self.evaluateJavaScript(VideoOpening.play, completionHandler: nil)
            }
        }
    }

    func endVideoOpening() {
        evaluateQuietly(VideoOpening.stop)
        videoOpeningWatches.removeAll()
    }

    func videoPlaybackPrevented(event: Int, flags: UInt) {
        // _WKAutoplayEventDidPreventFromAutoplaying, PlaybackWasPrevented.
        guard event == 0, flags & 2 != 0, let tab = stateEvents as? Tab else { return }
        guard tab.videoOpening.armed, tab.built === self else { return }
        let generation = tab.videoOpening.generation
        let script = "window.__yabVideoOpening && window.__yabVideoOpening.prevented(\(flags & 4 != 0))"
        evaluateQuietly(script) { [weak self, weak tab] _, _ in
            guard let self, let tab, tab.built === self, tab.videoOpening.generation == generation else { return }
            tab.videoOpening.prevented()
            self.updateVideoOpening()
        }
    }
}
