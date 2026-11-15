import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ChromiumShieldTests {
    @Test func destinationArmingDecidesYouTubeBeforeBuildingTheDocumentScripts() throws {
        try #require(Store.testing)
        _ = NSApplication.shared
        let tab = Tab(shy: true, factory: .webKitOnly)
        let scripts = ChromiumScripts()
        scripts.tab = tab
        let shield = Shield.shared
        let host = "youtube.com"
        let enabled = shield.enabled, paused = shield.isPaused(on: host)
        defer { shield.enabled = enabled; shield.pause(host, paused); tab.close() }
        shield.enabled = true
        shield.pause(host, false)

        #expect(!tab.skipsAds)
        scripts.arm(css: "", host: host)
        #expect(tab.skipsAds)
        let registrations = PageScripts.chromium(for: tab, .init(host: host, css: ""))
        let youtube = try #require(registrations.first { $0.source == YouTube.user.source })
        #expect(youtube.world == .page && !youtube.atEnd && youtube.mainOnly)

        scripts.arm(css: "", host: "example.test")
        #expect(!tab.skipsAds)
        #expect(!PageScripts.chromium(for: tab, .init(host: "example.test", css: "")).contains { $0.source == YouTube.user.source })

        shield.pause(host, true)
        scripts.arm(css: "", host: host)
        #expect(!tab.skipsAds)
        shield.pause(host, false)
        shield.enabled = false
        scripts.arm(css: "", host: host)
        #expect(!tab.skipsAds)
    }
}
