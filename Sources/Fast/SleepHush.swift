import AppKit
import WebKit

// Nothing plays by itself when the Mac wakes (#263).
//
// WebKit stops every page's media as the Mac goes to sleep and, on wake,
// plays again whatever it stopped: its media sessions take the system's
// sleep as an interruption (PlatformMediaSessionManager's
// processSystemWillSleep) and end it with MayResumePlaying
// (processSystemDidWake). The Mac wakes as the lid opens, at the lock
// screen, so a video left playing in some tab, often one out of sight,
// starts sounding before anyone has unlocked, which was the report.
//
// So as the Mac goes to sleep Yab pauses every page's media itself. A pause
// that reaches a page before WebKit's interruption leaves nothing to resume;
// one that reaches it during the interruption is what WebKit restores
// instead (its stateToRestore becomes Paused). Either way the video waits,
// paused where it was, for the play button. On wake the pause is sent again:
// a message sent as the Mac went down may only arrive after WebKit's own
// wake, and then it still stops the sound before anyone is there to hear
// it. Nothing else changes: a locked screen or a display asleep with the
// Mac awake goes on playing, as music should.
@MainActor
final class SleepHush {
    static let shared = SleepHush()

    /// Every page view there is (PageView registers itself), weakly.
    let pages = NSHashTable<WKWebView>.weakObjects()
    /// What pausing a page does; a stand-in for tests.
    var pause: (WKWebView) -> Void = { $0.pauseAllMediaPlayback(completionHandler: {}) }
    /// Only attached remote pages: reading this list never starts a helper
    /// or wakes a sleeping tab. ChromiumProcess keeps its entries weakly.
    var remotePages: () -> [ChromiumPage] = { ChromiumProcess.shared.livePages }
    var pauseRemote: (ChromiumPage) -> Void = { $0.mediaAction("pause") }
    /// How many times the pages were hushed.
    private(set) var hushes = 0

    private var watching: [NSObjectProtocol] = []
    private let diagnostics: FeedbackDiagnostics

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter, diagnostics: FeedbackDiagnostics = .shared) {
        self.diagnostics = diagnostics
        watching = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didWakeNotification { self.diagnostics.record(.systemWoke) }
                    self.hush()
                }
            }
        }
    }

    /// Every page's media paused where it is.
    func hush() {
        hushes += 1
        for page in pages.allObjects { pause(page) }
        for page in remotePages() { pauseRemote(page) }
    }
}
