import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct QueuedExternalRouteTests {
    @Test func fixedRoutesApplyToEveryQueuedExternalURLWithoutAFallback() throws {
        let browser = Browser(windowID: UUID())
        let routes = LinkRoutes.shared
        let oldDefault = routes.defaultSpace
        let oldSpaces = browser.prefs.usesSpaces
        let site = "queued-external-1673.invalid"
        let oldRule = routes.route(site: site)
        var added: UUID?
        defer {
            if let added { browser.deleteSpace(added) }
            routes.remove(site)
            if let oldRule { routes.set(oldRule.site, to: oldRule.space) }
            routes.setDefaultSpace(oldDefault)
            browser.prefs.usesSpaces = oldSpaces
            browser.letGo()
            if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        browser.prefs.usesSpaces = true
        let first = browser.spaceID
        added = browser.addSpace(named: "Queued Work", ownSignIns: false)
        let work = browser.spaceID
        #expect(first != work)
        browser.switchSpace(to: first)
        routes.setDefaultSpace(nil)
        routes.set(site, to: work)
        let url = try #require(URL(string: "https://\(site)/ticket"))
        Links.openQueued(url, in: browser, recent: first)
        #expect(browser.spaceID == work)
        #expect(browser.tabs.contains { $0.pending == url || $0.address == url })
        browser.switchSpace(to: first)
        #expect(!browser.tabs.contains { $0.pending == url || $0.address == url })
    }

    /// Feedback #1305: a link clicked in Teams comes as Teams' Safe Links
    /// page; the gitlab.com rule takes it to its space, where the page
    /// itself opens, its check intact.
    @Test func aTeamsSafeLinkGoesToTheSpaceOfTheLinkItCarries() throws {
        let browser = Browser(windowID: UUID())
        let routes = LinkRoutes.shared
        let oldDefault = routes.defaultSpace
        let oldSpaces = browser.prefs.usesSpaces
        let site = "teams-safelink-1305.invalid"
        let oldRule = routes.route(site: site)
        var added: UUID?
        defer {
            if let added { browser.deleteSpace(added) }
            routes.remove(site)
            if let oldRule { routes.set(oldRule.site, to: oldRule.space) }
            routes.setDefaultSpace(oldDefault)
            browser.prefs.usesSpaces = oldSpaces
            browser.letGo()
            if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        browser.prefs.usesSpaces = true
        let first = browser.spaceID
        added = browser.addSpace(named: "Teams Work", ownSignIns: false)
        let work = browser.spaceID
        browser.switchSpace(to: first)
        routes.setDefaultSpace(nil)
        routes.set(site, to: work)
        let url = try #require(URL(string: "https://teams.public.onecdn.static.microsoft/evergreen-assets/safelinks/2/atp-safelinks.html?url=https%3A%2F%2F\(site)%2Fgroup%2Fproject&locale=en-us"))
        Links.openQueued(url, in: browser, recent: first)
        #expect(browser.spaceID == work)
        #expect(browser.tabs.contains { $0.pending == url || $0.address == url })
    }
}
