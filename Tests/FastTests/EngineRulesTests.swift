import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct EngineRulesTests {
    private func world() -> (SiteEngineSettings, () -> Void) {
        let name = "engine-rules-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        return (SiteEngineSettings(store: store), { store.removePersistentDomain(forName: name) })
    }

    @Test func precedenceIsTabThenOwnThenBuiltInThenDefault() {
        let builtIn = (rule: "netflix", kind: PageEngineKind.webKit)
        #expect(EngineRules.decide(held: .chromium, own: .webKit, builtIn: builtIn, base: .webKit, auto: true, tight: true)
                == EngineDecision(kind: .chromium, source: .tab))
        #expect(EngineRules.decide(held: nil, own: .chromium, builtIn: builtIn, base: .webKit, auto: true, tight: true)
                == EngineDecision(kind: .chromium, source: .own))
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: builtIn, base: .chromium, auto: true, tight: false)
                == EngineDecision(kind: .webKit, source: .builtIn("netflix")))
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: nil, base: .chromium, auto: true, tight: false)
                == EngineDecision(kind: .chromium, source: .standard))
    }

    @Test func autoSparesMemoryOnlyForChromiumWithNoRule() {
        // Auto, memory tight: still Chromium. Auto sends only the built-in rules' sites to WebKit.
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: nil, base: .chromium, auto: true, tight: true)
                == EngineDecision(kind: .chromium, source: .standard))
        // Chromium picked by name ignores memory.
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: nil, base: .chromium, auto: false, tight: true).kind == .chromium)
        // A rule wins over memory, both ways.
        #expect(EngineRules.decide(held: nil, own: .chromium, builtIn: nil, base: .chromium, auto: true, tight: true).kind == .chromium)
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: (rule: "chromewebstore", kind: .chromium),
                                   base: .chromium, auto: true, tight: true).kind == .chromium)
        // WebKit as the default stays WebKit.
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: nil, base: .webKit, auto: true, tight: false).kind == .webKit)
    }

    @Test func builtInRulesMatchTheirFamiliesAndCanBeOverridden() {
        let (sites, done) = world()
        defer { done() }
        let netflix = URL(string: "https://www.netflix.com/watch/1")!
        #expect(sites.builtIn(for: netflix)?.rule == "netflix")
        #expect(sites.builtIn(for: URL(string: "https://play.max.com/")!)?.rule == "max")
        #expect(sites.builtIn(for: URL(string: "https://chromewebstore.google.com/detail/x")!)?.kind == .chromium)
        #expect(sites.builtIn(for: URL(string: "https://checkout.stripe.com/pay/1")!)?.rule == "applepay")
        #expect(sites.builtIn(for: URL(string: "https://notnetflix.com/")!) == nil)
        // Crunchyroll's player needs Widevine, which Yab's Chromium lacks (register 1394).
        let crunchyroll = sites.builtIn(for: URL(string: "https://www.crunchyroll.com/watch/G4VUQ1ZKW")!)
        #expect(crunchyroll?.rule == "crunchyroll" && crunchyroll?.kind == .webKit)
        #expect(ChromiumDRM.requiresWebKit(URL(string: "https://static.crunchyroll.com/")!))
        let rule = EngineBuiltInRule.all.first { $0.id == "netflix" }!
        sites.set(.chromium, for: rule)
        #expect(sites.builtIn(for: netflix)?.kind == .chromium)
        #expect(sites.decide(.chromium, at: netflix, tight: false).kind == .chromium)
        // Picking its own engine again removes the override.
        sites.set(.webKit, for: rule)
        #expect(sites.store.object(forKey: EngineRules.builtInPrefix + "netflix") == nil)
        #expect(sites.decide(.chromium, at: netflix, tight: false) == EngineDecision(kind: .webKit, source: .builtIn("netflix")))
        #expect(EngineDecision(kind: .webKit, source: .builtIn("netflix")).reason == "Protected video")
    }

    @Test func ownRulesUseTheOldOpensInKeysAndBeatBuiltIns() {
        let (sites, done) = world()
        defer { done() }
        // A value the old Opens in wrote reads as a row, unchanged.
        sites.store.set("chromium", forKey: "site.engine.figma.com")
        sites.store.set("webKit", forKey: "site.engine.www.netflix.com")
        sites.store.set("future", forKey: "site.engine.bad.test")
        #expect(sites.ownRules == [.init(host: "figma.com", kind: .chromium), .init(host: "www.netflix.com", kind: .webKit)])
        let rule = EngineBuiltInRule.all.first { $0.id == "netflix" }!
        sites.set(.chromium, for: rule)
        #expect(sites.decide(.chromium, at: URL(string: "https://www.netflix.com/")!, tight: false).source == .own)
        sites.setOwn(nil, host: "figma.com")
        #expect(sites.choice(for: URL(string: "https://figma.com/")!) == .recommended)
    }

    @Test func autoIsTheDefaultUntilChromiumIsPickedByName() {
        let (sites, done) = world()
        defer { done() }
        let plain = URL(string: "https://plain.test/")!
        #expect(sites.auto)
        #expect(sites.decide(.chromium, at: plain, tight: true).kind == .chromium)
        sites.store.set("chromium", forKey: EngineRules.defaultKey)
        #expect(!sites.auto)
        #expect(sites.decide(.chromium, at: plain, tight: true).kind == .chromium)
    }

    @Test func webKitFirstMovesOnlyATabWithNoRuleWhileMemoryIsTight() {
        func first(own: SiteEngineChoice = .recommended, builtIn: (rule: String, kind: PageEngineKind)? = nil,
                   held: PageEngineKind? = nil, tight: Bool = true) -> EngineDecision {
            EngineRules.decide(held: held, own: own, builtIn: builtIn, base: .webKit, auto: false, webKitFirst: true, tight: tight)
        }
        #expect(first(tight: false) == EngineDecision(kind: .webKit, source: .standard))
        #expect(first() == EngineDecision(kind: .chromium, source: .spared))
        // Rules win, both ways: Spotify and the like stay on WebKit.
        #expect(first(builtIn: (rule: "spotify", kind: .webKit)) == EngineDecision(kind: .webKit, source: .builtIn("spotify")))
        #expect(first(own: .webKit) == EngineDecision(kind: .webKit, source: .own))
        #expect(first(held: .webKit) == EngineDecision(kind: .webKit, source: .tab))
        #expect(first(builtIn: (rule: "chromewebstore", kind: .chromium)).source == .builtIn("chromewebstore"))
        // A tab on Chromium by its own history stays there: only Auto goes the other way.
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: nil, base: .chromium, auto: false, webKitFirst: true,
                                   tight: true) == EngineDecision(kind: .chromium, source: .standard))
    }

    @Test func webKitFirstReadsFromTheStoredName() {
        let (sites, done) = world()
        defer { done() }
        let plain = URL(string: "https://plain.test/")!
        sites.store.set(EngineDefault.webKitFirst.rawValue, forKey: EngineRules.defaultKey)
        #expect(sites.webKitFirst && !sites.auto)
        #expect(sites.decide(.webKit, at: plain, tight: true) == EngineDecision(kind: .chromium, source: .spared))
        #expect(sites.decide(.webKit, at: plain, tight: false) == EngineDecision(kind: .webKit, source: .standard))
        #expect(sites.decide(.webKit, at: URL(string: "https://open.spotify.com/")!, tight: true).kind == .webKit)
        // WebKit picked by name keeps the old stored value and looks at nothing.
        sites.store.set(EngineDefault.auto.rawValue, forKey: EngineRules.defaultKey)
        #expect(sites.decide(.webKit, at: plain, tight: true) == EngineDecision(kind: .webKit, source: .standard))
    }

    @Test func theMenuNamesWebKitFirstAndEachChoiceHasItsEngine() {
        #expect(EngineDefault.allCases.map(\.title) == ["Auto", "WebKit", "WebKit First", "Chromium"])
        #expect(EngineDefault.allCases.map(\.base) == [.chromium, .webKit, .webKit, .chromium])
    }

    @Test func aRestoredSessionTakesTheDefaultOnWebPagesOnly() {
        // A session from a WebKit-only version: no engine, so saved is WebKit.
        let page = URL(string: "https://plain.test/")!, own = URL(string: "chrome-extension://abc/page.html")!
        #expect(EngineRules.restored(saved: .webKit, url: page, standard: .chromium) == .chromium)
        #expect(EngineRules.restored(saved: .webKit, url: nil, standard: .chromium) == .chromium)
        #expect(EngineRules.restored(saved: .webKit, url: own, standard: .chromium) == .webKit)
        #expect(EngineRules.restored(saved: .webKit, url: page, standard: nil) == .webKit)
        // A tab that memory moved comes back on the default, memory looked at anew.
        #expect(EngineRules.restored(saved: .chromium, url: page, standard: .webKit) == .webKit)
    }

    @Test func factoryKeepsWebKitWithoutChromium() {
        let (sites, done) = world()
        defer { done() }
        let webKitOnly = PageEngineFactory(kinds: [.webKit], sites: sites) { tab, _ in tab.buildWebKitPage() }
        #expect(webKitOnly.resolved(.chromium, at: URL(string: "https://chromewebstore.google.com/")!) == .webKit)
        sites.setOwn(.chromium, host: "figma.com")
        #expect(webKitOnly.resolved(.webKit, at: URL(string: "https://figma.com/")!) == .webKit)
    }

    @Test func addSiteTakesAHostFromWhatIsTyped() {
        #expect(EngineSiteEditing.host(from: "Figma.com") == "figma.com")
        #expect(EngineSiteEditing.host(from: "https://www.figma.com/file/1") == "www.figma.com")
        #expect(EngineSiteEditing.host(from: "figma") == nil)
        #expect(EngineSiteEditing.host(from: "two words") == nil)
    }
}
