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
