import AppKit
import QuartzCore
import Testing
@testable import Fast

/// Choosing a paused source is different from an unattended source pausing.
/// The native compact/expanded click path is checked by player-secondary-736.
@MainActor @Suite(.serialized)
struct PlayerPromotionTests {
    private func sources() -> (Browser, Fast.Tab, Fast.Tab, Fast.Tab) {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tabs = ["playing", "secondary", "notes"].map { name in
            let tab = Fast.Tab()
            tab.restore(url: URL(string: "https://player-promotion.invalid/\(name)")!, title: name)
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = tabs[2].id
        for tab in tabs.prefix(2) {
            tab.tune = Tune(title: tab.title, duration: 240, elapsed: 20,
                            stamp: CACurrentMediaTime(), playing: true)
            browser.player.heard(tab)
            browser.player.restage(immediate: true)
        }
        return (browser, tabs[0], tabs[1], tabs[2])
    }

    private func stop(_ browser: Browser) {
        browser.dozing?.invalidate()
        browser.stuck.timer?.invalidate()
        browser.pressure?.cancel()
        browser.tabs.forEach { $0.close() }
        if let id = browser.windowID {
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
    }

    private func playing(_ on: Bool, in tab: Fast.Tab, browser: Browser) {
        tab.tune?.playing = on
        browser.player.heard(tab)
    }

    private func pastHandoff() async throws {
        try await Task.sleep(for: .seconds(Player.yield + 0.15))
    }

    @Test func choosingAnOldPausedSourceSurvivesFurtherUpdates() async throws {
        let (browser, first, second, notes) = sources()
        defer { stop(browser) }
        #expect(browser.player.face?.tab == first.id)
        playing(false, in: second, browser: browser)
        try await pastHandoff()

        browser.player.promote(second.id)
        #expect(browser.player.face?.tab == second.id)
        #expect(browser.player.face?.tune.playing == false)
        #expect(browser.player.face?.others.map(\.tab) == [first.id])
        #expect(first.tune?.playing == true)
        #expect(browser.activeID == notes.id)

        // An ordinary metadata/clock refresh must not reverse the click,
        // either immediately or after another automatic-handoff interval.
        first.tune?.elapsed += 1
        browser.player.heard(first)
        browser.player.restage()
        #expect(browser.player.face?.tab == second.id)
        try await pastHandoff()
        browser.player.restage()
        #expect(browser.player.face?.tab == second.id)

        browser.player.promote(first.id)
        #expect(browser.player.face?.tab == first.id)
        browser.player.promote(second.id)
        #expect(browser.player.face?.tab == second.id)
        second.tune = nil
        browser.player.heard(second)
        #expect(browser.player.face?.tab == first.id)
    }

    @Test func anUnattendedPausedLeadStillHandsOff() async throws {
        let (browser, first, second, notes) = sources()
        defer { stop(browser) }
        playing(false, in: first, browser: browser)
        try await pastHandoff()
        browser.player.restage()
        #expect(browser.player.face?.tab == second.id)
        #expect(browser.activeID == notes.id)
    }

    @Test func playingTheChosenSourceRestoresAutomaticHandoff() async throws {
        let (browser, first, second, _) = sources()
        defer { stop(browser) }
        playing(false, in: second, browser: browser)
        try await pastHandoff()
        browser.player.promote(second.id)
        #expect(browser.player.face?.tab == second.id)

        playing(true, in: second, browser: browser)
        playing(false, in: second, browser: browser)
        try await pastHandoff()
        browser.player.restage()
        #expect(browser.player.face?.tab == first.id)
    }
}
