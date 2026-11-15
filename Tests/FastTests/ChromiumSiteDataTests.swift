import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor
struct ChromiumSiteDataTests {
    /// Clear Data from a private tab now on WebKit still names the origins
    /// its Chromium past kept: the tab's own, and the site's bare and www.
    @Test func aPrivateForgetNamesTheSitesOrigins() {
        let origins = ChromiumSiteData.privateOrigins(site: "example.test", shown: [
            nil, URL(string: "https://app.example.test:8443/inbox"), URL(string: "https://other.test/")])
        #expect(origins == ["https://app.example.test:8443", "https://example.test", "https://www.example.test",
                            "http://example.test", "http://www.example.test"])
    }

    /// The window's Chromium profile is found from its store, whichever
    /// engine the tab asking is on, and only once a tab asked for one.
    @Test func aPrivateStoresProfileIsFoundWithoutMakingOne() {
        let store = WKWebsiteDataStore.nonPersistent()
        #expect(ChromiumPrivateProfiles.existing(for: store) == nil)
    }
}
