import AppKit
import Testing
import UserNotifications
@testable import Fast

/// Exercise the existing native presentation policy with registered browser
/// tabs. No notification is posted and no permission or real profile is used.
@MainActor @Suite(.serialized)
struct SiteNoticeMuteTests {
    enum Scenario: CaseIterable {
        case tab, site, both, worker, audible, unrelated, staleTab, unknownOrigin

        var quiet: Bool { self == .tab || self == .site || self == .both || self == .worker }
    }

    @Test(arguments: Scenario.allCases, [UInt32(1), 2, 4])
    func existingMuteAlsoQuietsNativeSound(_ scenario: Scenario, alert: UInt32) throws {
        _ = NSApplication.shared
        try #require(AudioWatch.canMute, "Fixture needs the existing native tab mute action")
        let windowID = UUID(), spaceID = UUID()
        let browser = Browser(windowID: windowID)
        let savedSpaces = Store.settings.object(forKey: "spaces")
        browser.spaces = [Space(id: spaceID, name: "Notification fixture", icon: "", ownSignIns: false)]
        browser.spaceID = spaceID
        let target = Tab(), other = Tab()
        target.restore(url: URL(string: "https://web.whatsapp.com/")!, title: "Owned notification target")
        other.restore(url: URL(string: "https://other-notification.invalid/")!, title: "Other origin")
        for tab in [target, other] { browser.prepare(tab) }
        browser.lay([target, other])
        // Keep it out of the active-page suppression path. These assertions
        // concern notification sound, not whether a banner is shown over chat.
        browser.activeID = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BrowserWindows.shared.register(window, for: browser)
        defer {
            window.close()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            Store.settings.set(savedSpaces, forKey: "spaces")
            for suffix in ["", "-" + spaceID.uuidString] {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString)\(suffix).json"))
            }
            Store.settings.removeObject(forKey: "window.\(windowID.uuidString).space")
        }
        if scenario == .tab || scenario == .both || scenario == .worker {
            browser.toggleMute([target])
            #expect(target.muted)
        }
        if scenario == .site || scenario == .both {
            browser.spaces[0].mutedSites = ["web.whatsapp.com"]
            #expect(browser.siteMuted(target))
        }
        if scenario == .unrelated || scenario == .staleTab { other.mute(true) }
        let origin = scenario == .unknownOrigin ? "https://unmatched-notification.invalid:443" : "https://web.whatsapp.com:443"
        let addressed: UUID? = scenario == .worker ? nil : scenario == .staleTab ? other.id : target.id
        let note = SiteNotices.Note(id: 1344, worker: scenario == .worker, origin: origin,
                                   title: "Owned message", body: "Fixture", tag: "", icon: "", tab: addressed,
                                   alert: SiteNotices.Alert(webKit: alert))
        let content = SiteNotices.content(note)
        let options = SiteNotices.presenting(content.userInfo)
        let audible = !scenario.quiet && alert != 2
        if audible {
            #expect(content.sound?.isEqual(UNNotificationSound.default) == true)
        } else {
            #expect(content.sound == nil)
        }
        #expect(options.contains(.banner) && options.contains(.list), "Mute must preserve the native banner")
        #expect(options.contains(.sound) == audible, "Existing tab/site mute must also quiet native notification sound")
        #expect(target.builtPage == nil, "Sound policy must not wake its target")
    }
}
