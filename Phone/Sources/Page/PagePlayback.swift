import AVFoundation
import WebKit
import os

/// Media on pages. A page that plays keeps playing with Yab in the
/// background or the screen locked (the audio background mode), its video
/// goes into Picture in Picture from WebKit's player, and the pool never lets
/// its web view go to keep the live-page limit while it plays. While anything
/// plays, the app's audio session is playback, so the Ring/Silent switch
/// doesn't mute it and AVKit may take a playing full-screen video into
/// Picture in Picture as Yab goes to the background; once nothing plays it
/// is iOS's default again and other apps' audio may go on.
///
/// What plays is WebKit's word (requestMediaPlaybackState), asked whenever
/// Yab's own script world hears a media element start or stop; a page can't
/// claim to play.
@MainActor
final class PagePlayback {
    private(set) var playing: Set<Tab.ID> = []
    private var checks: [Tab.ID: UUID] = [:]
    /// Sets the app's audio session for whether anything plays.
    private let apply: @MainActor (Bool) -> Void

    init(apply: @escaping @MainActor (Bool) -> Void = PagePlayback.setSession) {
        self.apply = apply
    }

    func isPlaying(_ id: Tab.ID) -> Bool { playing.contains(id) }

    /// A media element of the tab's page started or stopped: ask WebKit.
    /// `current` says the view still is the tab's when the answer comes.
    func check(_ id: Tab.ID, in view: WKWebView, current: @escaping @MainActor () -> Bool) {
        let token = UUID()
        checks[id] = token
        view.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.checks[id] == token, current() else { return }
                self.checks[id] = nil
                self.set(id, playing: state == .playing)
            }
        }
    }

    func set(_ id: Tab.ID, playing now: Bool) {
        let before = !playing.isEmpty
        if now { playing.insert(id) } else { playing.remove(id) }
        if before != !playing.isEmpty { apply(!playing.isEmpty) }
    }

    /// The tab's web view is gone, and its media with it.
    func forget(_ id: Tab.ID) {
        checks[id] = nil
        set(id, playing: false)
    }

    /// Playback while media plays; iOS's default, let go, once nothing does.
    nonisolated static func category(playing: Bool) -> AVAudioSession.Category {
        playing ? .playback : .soloAmbient
    }

    static func setSession(_ playing: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if playing {
                try session.setCategory(category(playing: true), mode: .moviePlayback)
            } else {
                // Others' audio (Music, a podcast) may go on where it stopped.
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setCategory(category(playing: false), mode: .default)
            }
        } catch {
            Logger(subsystem: "dev.serafim.fast.iphone", category: "page")
                .error("audio session: \(String(describing: error), privacy: .public)")
        }
    }
}
