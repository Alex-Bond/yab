import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct SiteEngineTests {
    @Test func exactHostSettingsPersistAcrossInstancesAndResetRemovesTheKey() {
        let name = "site-engine-model-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = SiteEngineSettings(store: store)
        let url = URL(string: "https://OPEN.SPOTIFY.COM.:8443/play")!
        #expect(settings.choice(for: url) == .recommended)
        #expect(settings.set(.chromium, for: url))
        let restored = SiteEngineSettings(store: UserDefaults(suiteName: name)!)
        #expect(restored.choice(for: URL(string: "http://open.spotify.com/other")) == .chromium)
        for host in ["spotify.com", "accounts.spotify.com", "www.open.spotify.com", "open.spotify.com.evil.test"] {
            #expect(restored.choice(for: URL(string: "https://\(host)/")) == .recommended)
        }
        #expect(restored.set(.recommended, for: url))
        #expect(store.object(forKey: "site.engine.open.spotify.com") == nil)
        store.set("future", forKey: "site.engine.open.spotify.com")
        #expect(settings.choice(for: url) == .recommended)
    }

    @Test func nonWebURLsCannotCreateAnOverride() {
        let settings = SiteEngineSettings(store: UserDefaults(suiteName: "site-engine-urls-" + UUID().uuidString)!)
        for raw in ["file:///netflix.com", "ftp://netflix.com", "about:blank", "yab://mail"] {
            let url = URL(string: raw)!
            #expect(!settings.set(.webKit, for: url))
            #expect(settings.choice(for: url) == .recommended)
        }
        #expect(SiteEngineSettings.host(nil) == nil)
    }

    @Test func factoryHonorsOverridesAndUnavailableChromiumKeepsWebKitDefault() {
        let name = "site-engine-factory-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = SiteEngineSettings(store: store)
        let factory = PageEngineFactory(kinds: [.webKit, .chromium], sites: settings) { tab, _ in tab.buildWebKitPage() }
        let webKitOnly = PageEngineFactory(kinds: [.webKit], sites: settings) { tab, _ in tab.buildWebKitPage() }
        let drm = URL(string: "https://open.spotify.com/")!, plain = URL(string: "https://plain.test/")!
        #expect(factory.resolved(.chromium, at: drm) == .webKit)
        #expect(factory.resolved(.chromium, at: plain) == .chromium)
        #expect(factory.resolved(.webKit, at: plain) == .webKit)
        settings.set(.chromium, for: drm)
        #expect(factory.resolved(.chromium, at: drm) == .chromium)
        #expect(webKitOnly.resolved(.webKit, at: drm) == .webKit)
        settings.set(.webKit, for: plain)
        #expect(factory.resolved(.chromium, at: plain) == .webKit)
    }
}
