import AppKit
import QuartzCore
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PlayerNotificationSoundTests {
    @Test(arguments: [0.6, 3.0])
    func notificationDoesNotBecomeAPausedMusicSource(duration: Double) {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let mail = Fast.Tab(shy: true), notes = Fast.Tab(shy: true)
        mail.restore(url: URL(string: "https://mail.google.com/")!, title: "Gmail")
        notes.restore(url: URL(string: "https://notes.invalid/")!, title: "Notes")
        browser.lay([mail, notes]); browser.activeID = notes.id
        defer {
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            for tab in [mail, notes] { tab.close() }
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        mail.tune = Tune(title: "Gmail", duration: duration, stamp: CACurrentMediaTime(), playing: true)
        browser.player.heard(mail)
        browser.player.restage(immediate: true)
        #expect(browser.player.face == nil)
        // The ordinary five-minute paused-source retention must not keep a ping.
        mail.tune?.playing = false
        browser.player.heard(mail)
        browser.player.restage(immediate: true)
        #expect(browser.player.face == nil)
        #expect(browser.activeID == notes.id)
        #expect(mail.tune?.duration == duration, "Filtering controls must not alter playback")
        // Positive controls go through the same production player path.
        for tune in [Tune(title: "Music", duration: 180, playing: true),
                     Tune(title: "Above boundary", duration: 3.01, playing: true),
                     Tune(title: "Unknown duration", playing: true),
                     Tune(title: "Live", duration: 1, live: true, playing: true),
                     Tune(title: "Loop", duration: 1, playing: true, loops: true)] {
            mail.tune = tune
            browser.player.heard(mail)
            browser.player.restage(immediate: true)
            #expect(browser.player.face?.tab == mail.id)
        }
    }
}
