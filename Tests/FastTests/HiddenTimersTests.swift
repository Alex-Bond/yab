import Foundation
import Testing
import WebKit
@testable import Fast

// A hidden page's timers slow down the longer it stays hidden; an
// agent's tab keeps WebKit's pace (Web.hiddenTimers).
@MainActor
@Suite(.serialized)
struct HiddenTimersTests {
    private func slowsDown(_ preferences: WKPreferences) -> Bool? {
        let selector = NSSelectorFromString("_hiddenPageDOMTimerThrottlingAutoIncreases")
        guard preferences.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(preferences.method(for: selector), to: Getter.self)(preferences, selector)
    }

    @Test func restoringSleepingAddressesKeepsWebKitConfigurationLazy() throws {
        guard #available(macOS 15.4, *) else { return }
        let tab = Tab(later: .nonPersistent(), factory: .webKitOnly)
        defer { tab.close() }
        #expect(tab.madeExtensionController == nil)
        for host in ["sleeping.example.invalid", "another.example.invalid"] {
            tab.restore(url: try #require(URL(string: "https://\(host)/paper.pdf")), title: "Paper")
            tab.paceHiddenTimers()
            #expect(tab.asleep && tab.builtPage == nil)
            #expect(tab.madeExtensionController == nil, "An address/timer policy change must not materialize a sleeping tab's configuration")
        }
    }

    @Test func deferredConfigurationUsesTheCurrentAwakePolicyAndKeepsFollowingIt() throws {
        guard Web.slowsHiddenTimers, slowsDown(WKPreferences()) != nil else { return }
        let awake = AwakeSites.shared
        let saved = awake.sites
        awake.restore(["kept.example.invalid"])
        let tab = Tab(later: .nonPersistent(), factory: .webKitOnly)
        defer { tab.close(); awake.restore(saved) }
        tab.restore(url: try #require(URL(string: "https://kept.example.invalid/")), title: "Kept")
        let preferences = requireNativeWebKitFixture(tab, "HiddenTimersTests").configuration.preferences
        #expect(slowsDown(preferences) == false)
        tab.restore(url: try #require(URL(string: "https://ordinary.example.invalid/")), title: "Ordinary")
        #expect(slowsDown(preferences) == true)
        tab.restore(url: try #require(URL(string: "https://kept.example.invalid/")), title: "Kept")
        #expect(slowsDown(preferences) == false)
    }

    @Test func aTabsHiddenTimersSlowDownAndAnAgentsDoNot() {
        guard Web.slowsHiddenTimers, slowsDown(WKPreferences()) != nil else { return }
        #expect(slowsDown(WKPreferences()) == false, "WebKit's own default, off")
        let yours = Tab(factory: .webKitOnly)
        let agents = Tab(bench: true, factory: .webKitOnly)
        defer { yours.close(); agents.close() }
        #expect(slowsDown(Web.configuration().preferences) == true)
        #expect(slowsDown(requireNativeWebKitFixture(yours, "HiddenTimersTests").configuration.preferences) == true)
        #expect(slowsDown(requireNativeWebKitFixture(agents, "HiddenTimersTests").configuration.preferences) == false)
        // An agent's tab you keep is yours: its timers slow down from then on.
        agents.adopt()
        #expect(slowsDown(requireNativeWebKitFixture(agents, "HiddenTimersTests").configuration.preferences) == true)
    }
}
