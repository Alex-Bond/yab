import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct SiteEngineTests {
    @Test func hostSettingsPersistAcrossInstancesAndResetRemovesTheKey() {
        let name = "site-engine-model-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = SiteEngineSettings(store: store)
        let url = URL(string: "https://OPEN.SPOTIFY.COM.:8443/play")!
        #expect(settings.choice(for: url) == .recommended)
        #expect(settings.set(.chromium, for: url))
        let restored = SiteEngineSettings(store: UserDefaults(suiteName: name)!)
        #expect(restored.choice(for: URL(string: "http://open.spotify.com/other")) == .chromium)
        #expect(restored.choice(for: URL(string: "https://www.open.spotify.com/")) == .chromium)
        for host in ["spotify.com", "accounts.spotify.com", "open.spotify.com.evil.test"] {
            #expect(restored.choice(for: URL(string: "https://\(host)/")) == .recommended)
        }
        #expect(restored.set(.recommended, for: url))
        #expect(store.object(forKey: "site.engine.open.spotify.com") == nil)
        store.set("future", forKey: "site.engine.open.spotify.com")
        #expect(settings.choice(for: url) == .recommended)
    }

    @Test func youtubeRuleWinsOverWebKitDefaultAcrossTheWWWRedirect() {
        let name = "site-engine-youtube-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let sites = SiteEngineSettings(store: store)
        let factory = PageEngineFactory(kinds: [.webKit, .chromium], sites: sites) { tab, _ in tab.buildWebKitPage() }
        sites.setOwn(.chromium, host: "youtube.com")
        for host in ["m.youtube.com", "accounts.youtube.com", "youtube.com.evil.test"] {
            #expect(sites.choice(for: URL(string: "https://\(host)/")) == .recommended)
        }
        for host in ["youtube.com", "www.youtube.com"] {
            let url = URL(string: "https://\(host)/watch?v=test")!
            #expect(factory.resolved(.webKit, at: url) == .chromium)
            #expect(sites.decide(.webKit, at: url, tight: false).source == .own)
        }
        sites.setOwn(.webKit, host: "www.youtube.com")
        #expect(factory.resolved(.webKit, at: URL(string: "https://www.youtube.com/")!) == .webKit)
        #expect(factory.resolved(.webKit, at: URL(string: "https://youtube.com/")!) == .chromium)
        sites.setOwn(nil, host: "youtube.com")
        #expect(sites.choice(for: URL(string: "https://youtube.com/")) == .webKit)
        sites.setOwn(nil, host: "www.youtube.com")
        #expect(factory.resolved(.webKit, at: URL(string: "https://www.youtube.com/")!) == .webKit)
    }

    @Test func automaticChoiceClearsAnInheritedWWWRule() {
        let name = "site-engine-alias-reset-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let sites = SiteEngineSettings(store: store)
        let bare = URL(string: "https://youtube.com/")!, www = URL(string: "https://www.youtube.com/")!
        sites.set(.chromium, for: bare)
        #expect(sites.choice(for: www) == .chromium)
        sites.set(.recommended, for: www)
        #expect(sites.choice(for: www) == .recommended)
        #expect(sites.choice(for: bare) == .recommended)
        #expect(sites.ownRules.isEmpty)
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
