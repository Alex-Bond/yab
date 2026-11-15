import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct SpaceHistoryTests {
    @Test func linkedSpacesShareHistoryAndBackgroundPagesKeepTheirProfile() {
        let owner = Space(id: UUID(), name: "Owner", icon: "💼", ownSignIns: true)
        let member = Space(id: UUID(), name: "Projects", icon: "📁", ownSignIns: true, signInWith: owner.id)
        let third = Space(id: UUID(), name: "Travel", icon: "✈️", ownSignIns: true)
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        browser.spaces = [owner, member, third]
        browser.spaceID = owner.id
        let history = browser.history
        let url = URL(string: "https://profile-history-" + UUID().uuidString.lowercased() + ".test/")!
        history.record(url, title: "Profile history", space: owner.id)
        let tab = Tab(bench: true, configuration: Web.configuration(store: Spaces.store(for: owner.id)))
        defer { tab.close() }
        browser.spaceID = member.id
        #expect(browser.history === history)
        #expect(browser.history.remembers(History.key(for: url)))
        browser.spaceID = third.id
        #expect(browser.history !== history)
        #expect(!browser.history.remembers(History.key(for: url)))
        #expect(browser.history(for: tab) === history)
        #expect(RecentMenu.following(history) !== RecentMenu.following(browser.history))
        #expect(History.profile(Space.firstID) === History.shared)
    }

    @Test func aTestHistoryOverrideStillAppliesToEverySpaceAndPage() {
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        let injected = History([])
        browser.history = injected
        let tab = Tab(bench: true)
        defer { tab.close() }
        #expect(browser.history === injected)
        #expect(browser.history(for: tab) === injected)
    }
}
