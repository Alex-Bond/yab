import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumPrivateProfilesTests {
    @Test func unrelatedPrivateTabsHaveDifferentContextsWithoutStartingAHelper() {
        _ = NSApplication.shared
        let a = Tab(shy: true), b = Tab(shy: true)
        defer { a.close(); b.close() }
        #expect(a.chromiumProfile != b.chromiumProfile)
        #expect(a.chromiumProfile.hasPrefix("private-") && b.chromiumProfile.hasPrefix("private-"))
        #expect(a.builtPage == nil && b.builtPage == nil)
    }

    @Test func aPrivatePopupSharesOnlyItsOpenersStoreAndSurvivesTheOpener() {
        _ = NSApplication.shared
        let opener = Tab(shy: true)
        let original = opener.chromiumProfile
        let child = Tab(shy: true, configuration: Web.configuration(shy: true, store: opener.pageStore))
        defer { child.close() }
        #expect(child.pageStore === opener.pageStore && child.chromiumProfile == original)
        opener.close()
        #expect(child.chromiumProfile == original)
    }

    @Test func lastPrivateOwnerEndsTheContextEvenIfAConfigurationIsRetained() {
        _ = NSApplication.shared
        let configuration = Web.configuration(shy: true)
        let first = Tab(shy: true, configuration: configuration)
        let profile = first.chromiumProfile
        first.close()
        let next = Tab(shy: true, configuration: configuration)
        defer { next.close() }
        #expect(next.chromiumProfile != profile)
    }

    @Test func aReplacementWithTheSameRowIDKeepsItsPrivateContext() {
        _ = NSApplication.shared
        let old = Tab(shy: true)
        let profile = old.chromiumProfile
        let next = Tab(id: old.id, shy: true, configuration: Web.configuration(shy: true, store: old.pageStore))
        defer { next.close() }
        #expect(next.chromiumProfile == profile)
        old.close()
        #expect(next.chromiumProfile == profile)
    }

    @Test func aWarmPrivateChildOwnsItsContextAfterTheSourceCloses() {
        _ = NSApplication.shared
        let source = Tab(shy: true)
        let profile = source.chromiumProfile
        let child = Tab(shy: true, configuration: Web.configuration(shy: true, store: source.pageStore))
        child.warmProfile = profile
        defer { child.close() }
        #expect(child.chromiumProfile == profile)
        source.close()
        child.warmProfile = nil
        #expect(child.chromiumProfile == profile)
    }

    @Test func aWarmHintCannotJoinUnrelatedPrivateStores() {
        _ = NSApplication.shared
        let source = Tab(shy: true), other = Tab(shy: true)
        defer { source.close(); other.close() }
        other.warmProfile = source.chromiumProfile
        #expect(other.chromiumProfile != source.chromiumProfile)
    }

    @Test func privateBridgeAdmissionRequiresTheExactLiveEphemeralStore() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true), other = Tab(shy: true)
        defer { tab.close(); other.close() }
        let profile = tab.chromiumProfile
        try ChromiumPrivateProfiles.authorize(profile, store: tab.pageStore, privateMode: true)
        let session = try ChromiumDRMExtensionSession.of(tab)
        #expect(session.profile == profile && session.privateMode && session.store === tab.pageStore)
        #expect(throws: ChromiumPersistentProfiles.Refused.self) {
            try ChromiumPrivateProfiles.authorize(profile, store: other.pageStore, privateMode: true)
        }
        #expect(throws: ChromiumPersistentProfiles.Refused.self) {
            try ChromiumPrivateProfiles.authorize(profile, store: Store.websites, privateMode: true)
        }
        let own = ChromiumExtensions.shared(profile: profile, privateMode: true, store: tab.pageStore)
        let foreign = ChromiumExtensions.shared(profile: profile, privateMode: true, store: other.pageStore)
        #expect(own !== foreign)
        #expect(tab.builtPage == nil && other.builtPage == nil)
    }

    @Test func anInternalEphemeralPageIsAdmittedWithoutAPrivateWindowFlag() throws {
        _ = NSApplication.shared
        let tab = Tab(configuration: Web.configuration(store: .nonPersistent()))
        defer { tab.close() }
        #expect(!tab.shy)
        let session = try ChromiumDRMExtensionSession.of(tab)
        #expect(session.privateMode && session.profile == tab.chromiumProfile)
        try ChromiumPrivateProfiles.authorize(tab.chromiumProfile, store: tab.pageStore, privateMode: true)
        tab.close()
        #expect(throws: ChromiumPersistentProfiles.Refused.self) {
            try ChromiumPrivateProfiles.authorize(session.profile, store: tab.pageStore, privateMode: true)
        }
    }
}
