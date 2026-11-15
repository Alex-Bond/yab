import AppKit
import Testing
import WebKit
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumDRMTests {
    @Test func hostsAreBoundedToTheServiceAndWebNavigation() {
        for host in ["open.spotify.com", "accounts.spotify.com", "NETFLIX.com", "www.disneyplus.com",
                     "www.primevideo.com", "tv.apple.com", "music.apple.com", "play.max.com", "hbomax.com"] {
            #expect(ChromiumDRM.requiresWebKit(URL(string: "https://\(host)/watch")))
        }
        for value in ["https://evilspotify.com", "https://spotify.com.evil.test", "https://apple.com",
                      "https://amazon.com", "https://example.test/spotify.com", "file:///spotify.com",
                      "ftp://netflix.com", "https://spotify.com@evil.test"] {
            #expect(!ChromiumDRM.requiresWebKit(URL(string: value)))
        }
        #expect(!ChromiumDRM.requiresWebKit(nil))
    }

    @Test func restoredDRMTabChoosesWebKitBeforeConstructingChromium() {
        _ = NSApplication.shared
        var choices: [PageEngineKind] = []
        let factory = PageEngineFactory(kinds: [.webKit, .chromium]) { tab, kind in
            choices.append(kind)
            return tab.buildWebKitPage()
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration, engine: .chromium, factory: factory)
        defer { tab.close() }
        let id = tab.id
        tab.restore(url: URL(string: "https://open.spotify.com")!, title: "Spotify")
        #expect(tab.builtPage == nil && choices.isEmpty)
        #expect(tab.page.engine == .webKit)
        #expect(choices == [.webKit] && tab.id == id && tab.title == "Spotify")
    }
    private func cookie(_ value: String = "one", domain: String = ".spotify.com", path: String = "/") -> ChromiumDRMCookie {
        ChromiumDRMCookie(HTTPCookie(properties: [.name: "sid", .value: value, .domain: domain,
            .path: path, .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE", .sameSitePolicy: "lax"])!)
    }

    @Test func cookieMergePropagatesEditsAndSignOutWithoutResurrectingCookies() {
        let old = cookie(), new = cookie("two")
        let initial = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: [old.key: old], previousWebKit: [:], previousChromium: [:])
        #expect(initial.toWebKit.count == 1 && initial.toWebKit[0].cookie == old)
        let edited = ChromiumDRMCookieMerge.plan(webKit: [old.key: new], chromium: [old.key: old], previousWebKit: [old.key: old], previousChromium: [old.key: old])
        #expect(edited.toChromium.count == 1 && edited.toChromium[0].cookie == new && edited.toWebKit.isEmpty)
        let deleted = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: [old.key: old], previousWebKit: [old.key: old], previousChromium: [old.key: old])
        #expect(deleted.toChromium.count == 1 && deleted.toChromium[0].cookie == nil && deleted.toWebKit.isEmpty)
        let remoteDeleted = ChromiumDRMCookieMerge.plan(webKit: [old.key: old], chromium: [:], previousWebKit: [old.key: old], previousChromium: [old.key: old])
        #expect(remoteDeleted.toWebKit.count == 1 && remoteDeleted.toWebKit[0].cookie == nil)
        let unchanged = ChromiumDRMCookieMerge.plan(webKit: [old.key: old], chromium: [old.key: old], previousWebKit: [old.key: old], previousChromium: [old.key: old])
        #expect(unchanged.toWebKit.isEmpty && unchanged.toChromium.isEmpty)
    }

    @Test func cookieScopeIncludesDomainPathAndHostOnlyAttributes() throws {
        let hostOnly = cookie(domain: "open.spotify.com")
        #expect(hostOnly.chromium["domain"] == .null)
        #expect(hostOnly.chromium["url"] == .string("https://open.spotify.com/"))
        let domain = cookie()
        #expect(domain.chromium["domain"] == .string(".spotify.com"))
        #expect(domain.key != cookie(path: "/account").key)
        let returned = ChromiumDRMCookie(try #require(domain.webKit))
        #expect(returned == domain && returned.httpOnly && returned.secure && returned.sameSite == "Lax")
    }

    @Test func partitionedCookiesRefuseFlatteningAndNoneUsesWebKitNoPolicy() throws {
        let base: [String: JSONValue] = ["name": .string("sid"), "value": .string("fake"), "domain": .string(".spotify.com"), "path": .string("/")]
        var partitioned = base
        partitioned["partitionKey"] = .object(["topLevelSite": .string("https://example.test")])
        #expect(throws: (any Error).self) { try ChromiumDRMCookie(.object(partitioned)) }
        var none = base
        none["sameSite"] = .string("None")
        none["secure"] = .bool(true)
        let cookie = try ChromiumDRMCookie(.object(none))
        let webKit = try #require(cookie.webKit)
        #expect(webKit.sameSitePolicy == nil && webKit.isSecure)
        #expect(ChromiumDRMCookie(webKit).sameSite == "None")
        none["secure"] = .bool(false)
        #expect(try ChromiumDRMCookie(.object(none)).sameSite == "Lax")
        let noPolicy = HTTPCookie(properties: [.name: "sid", .value: "fake", .domain: "spotify.com", .path: "/"])!
        #expect(ChromiumDRMCookie(noPolicy).sameSite == "Lax")
    }

}
