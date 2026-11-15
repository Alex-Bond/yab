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
        // Auto, memory tight: WebKit.
        #expect(EngineRules.decide(held: nil, own: .recommended, builtIn: nil, base: .chromium, auto: true, tight: true)
                == EngineDecision(kind: .webKit, source: .spared))
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
        #expect(sites.decide(.chromium, at: plain, tight: true).kind == .webKit)
        sites.store.set("chromium", forKey: EngineRules.defaultKey)
        #expect(!sites.auto)
        #expect(sites.decide(.chromium, at: plain, tight: true).kind == .chromium)
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
