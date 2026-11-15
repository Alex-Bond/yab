import Foundation
import Testing
@testable import Fast

/// Websites reads the same answers as Site Controls and WebKit, including
/// denied sites and separate schemes or ports on the same host.
@MainActor
@Suite(.serialized)
struct SiteNotificationSettingsTests {
    @Test func theListIncludesAllowedAndDeniedSitesInOriginOrder() {
        let host = "notification-list-\(UUID().uuidString.lowercased()).invalid"
        let origins = ["https://\(host):8443", "https://\(host):443", "http://\(host):80"]
        let malformed = SiteNotices.key("not-an-origin-\(host)")
        let wrongType = SiteNotices.key("https://other.\(host):443")
        let camera = Browser.captureKey(origins[0], .camera)
        let keys = origins.map(SiteNotices.key) + [malformed, wrongType, camera]
        defer { for key in keys { Store.settings.removeObject(forKey: key) } }
        Store.settings.set(true, forKey: SiteNotices.key(origins[0]))
        Store.settings.set(false, forKey: SiteNotices.key(origins[1]))
        Store.settings.set(true, forKey: SiteNotices.key(origins[2]))
        Store.settings.set(true, forKey: malformed)
        Store.settings.set("unasked", forKey: wrongType)
        Store.settings.set(true, forKey: camera)

        let sites = SiteNotices.sites().filter { $0.origin.contains(host) }
        #expect(sites.map(\.origin) == origins.sorted())
        #expect(sites.map(\.id) == sites.map(\.origin))
        #expect(sites.map(\.allowed) == [true, false, true])
        #expect(sites.map(\.title) == ["http://\(host)", "https://\(host)", "https://\(host):8443"])
        #expect(sites.allSatisfy { $0.host == host })
        #expect(SiteNotices.said("https://unasked.\(host):443") == nil)
    }

    @Test func changingTheAnswerUpdatesTheListAndWebKitPolicies() {
        let origin = "https://notification-change-\(UUID().uuidString.lowercased()).invalid:443"
        defer { Store.settings.removeObject(forKey: SiteNotices.key(origin)) }
        #expect(!SiteNotices.sites().contains { $0.origin == origin })
        for allowed in [true, false, true] {
            SiteNotices.remember(origin, allowed)
            #expect(SiteNotices.said(origin) == allowed)
            #expect(SiteNotices.sites().filter { $0.origin == origin } == [.init(origin: origin, allowed: allowed)])
            #expect(SiteNotices.policies()[SiteNotices.webKitOrigin(origin)] == allowed)
        }
    }

    @Test func removingEitherAnswerLetsTheSiteAskAgainAndKeepsOtherSites() {
        let host = "notification-remove-\(UUID().uuidString.lowercased()).invalid"
        let removed = "https://\(host):443"
        let kept = "https://\(host):8443"
        defer {
            Store.settings.removeObject(forKey: SiteNotices.key(removed))
            Store.settings.removeObject(forKey: SiteNotices.key(kept))
        }
        SiteNotices.remember(kept, false)
        for allowed in [true, false] {
            SiteNotices.remember(removed, allowed)
            #expect(SiteNotices.sites().contains { $0.origin == removed && $0.allowed == allowed })
            SiteNotices.forget(removed)
            #expect(SiteNotices.said(removed) == nil)
            #expect(!SiteNotices.sites().contains { $0.origin == removed })
            #expect(SiteNotices.policies()[SiteNotices.webKitOrigin(removed)] == nil)
            #expect(SiteNotices.said(kept) == false)
            #expect(SiteNotices.sites().contains { $0.origin == kept && !$0.allowed })
        }
        SiteNotices.remember(removed, true)
        #expect(SiteNotices.sites().contains { $0.origin == removed && $0.allowed })
    }
}
