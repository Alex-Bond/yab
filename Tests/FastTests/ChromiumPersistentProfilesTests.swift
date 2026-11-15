import Foundation
import Testing
import AppKit
import WebKit
@testable import Fast

@MainActor struct ChromiumPersistentProfilesTests {
    private let shared = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func liveSharedAssociationDoesNotRediscoverAliasesOnInput() throws {
        let store = Store.websites
        let plan = ChromiumPersistentProfiles.plan(for: store)
        let addedSpace = UUID()
        Spaces.sharing.insert(addedSpace)
        defer { Spaces.sharing.remove(addedSpace) }
        // Tab.chromiumProfile and endpoint authorization repeat these calls
        // for every event. A new row is not a new website-store association.
        for _ in 0..<120 {
            #expect(ChromiumPersistentProfiles.plan(for: store) == plan)
            #expect(ChromiumPersistentProfiles.profile(store: store, placement: addedSpace) == plan.primary.uuidString)
        }
    }

    @Test func freshSharedSpacesChooseOneNativeContext() {
        let plan = ChromiumPersistentProfiles.Plan(logical: shared, aliases: [shared,a,b], existing: [])
        #expect(!plan.needsMerge)
        #expect(plan.physical(for: a) == shared && plan.physical(for: b) == shared)
    }
    @Test func aSingleLegacyContextKeepsItsPhysicalDataAndAuthorization() {
        let plan = ChromiumPersistentProfiles.Plan(logical: shared, aliases: [shared,a,b], existing: [b], associated: [b])
        #expect(!plan.needsMerge)
        #expect(plan.physical(for: a) == b && plan.physical(for: shared) == b)
        #expect(plan.primary == b)
    }
    @Test func anUnprovenLegacyDirectoryCannotShareItsOldCredentials() {
        let plan = ChromiumPersistentProfiles.Plan(logical: shared, aliases: [shared,a,b], existing: [b])
        #expect(plan.needsMerge)
        #expect(plan.physical(for: b) == shared && plan.quarantined.contains(b))
        #expect(plan.physical(for: a) == shared && plan.physical(for: shared) == shared)
    }
    @Test func conflictingLegacyContextsAreRetainedAndMarkedForMigration() {
        let plan = ChromiumPersistentProfiles.Plan(logical: shared, aliases: [shared,a,b], existing: [shared,b], associated: [shared])
        #expect(plan.needsMerge)
        #expect(plan.physical(for: shared) == shared)
        #expect(plan.physical(for: b) == shared && plan.quarantined.contains(b))
        #expect(plan.physical(for: a) == shared)
    }
    @Test func independentSignInsNeverJoinTheSharedContext() {
        let own = ChromiumPersistentProfiles.Plan(logical: a, aliases: [a], existing: [a], associated: [a])
        #expect(own.physical(for: a) == a && own.primary != shared)
        #expect(!own.needsMerge)
    }

    @Test func anExistingLogicalUUIDIsNotEvidenceOfStoreAssociation() {
        let plan = ChromiumPersistentProfiles.Plan(logical: a, aliases: [a], existing: [a], fresh: b)
        #expect(plan.primary == b && plan.quarantined == [a] && plan.needsMerge)
        #expect(plan.physical(for: a) == b)
    }

    @Test func unknownDataIsNeverOpenedAndFreshAssociationPrecedesNativeUse() throws {
        let logical = UUID(), store = WKWebsiteDataStore(forIdentifier: logical)
        let root = Store.file("Chromium")
        let old = root.appendingPathComponent("space-" + logical.uuidString)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let marker = old.appendingPathComponent("fixture-old-data")
        try Data("synthetic old sign-in".utf8).write(to: marker)
        var created: [URL] = [old]
        defer {
            for item in created { try? FileManager.default.removeItem(at: item) }
            let receipts = Store.file("ChromiumProfiles")
            for file in (try? FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix(logical.uuidString + "-named.json") {
                try? FileManager.default.removeItem(at: file)
            }
            Store.settings.removeObject(forKey: "chromium.profile.generation." + logical.uuidString)
        }
        let profile = ChromiumPersistentProfiles.profile(store: store, placement: logical)
        #expect(profile != logical.uuidString)
        #expect(throws: ChromiumPersistentProfiles.Refused.self) {
            try ChromiumPersistentProfiles.authorize(logical.uuidString, store: store)
        }
        let fresh = root.appendingPathComponent("space-" + profile)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        try ChromiumPersistentProfiles.authorize(profile, store: store)
        created.append(fresh)
        let receipt = Store.file("ChromiumProfiles").appendingPathComponent(logical.uuidString + "-named.json")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        #expect(state["physical"] as? String == profile && state["provenance"] as? String == "fresh")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "synthetic old sign-in")
        ChromiumPersistentProfiles.retireAssociation(logical)
        #expect(throws: ChromiumPersistentProfiles.Refused.self) {
            try ChromiumPersistentProfiles.authorize(profile, store: store)
        }
        #expect(ChromiumPersistentProfiles.profile(store: store, placement: logical) != profile)
    }

    @Test func buildingDefaultWebKitDoesNotClaimANativeProfileOrStartItsBridges() async throws {
        _ = NSApplication.shared
        let logical = UUID(), store = WKWebsiteDataStore(forIdentifier: logical)
        let factory = PageEngineFactory(kinds: [.webKit, .chromium]) { tab, kind in
            if kind == .chromium { return ChromiumPage(tab: tab) }
            return tab.buildWebKitPage()
        }
        let tab = Tab(configuration: Web.configuration(store: store), engine: .webKit, factory: factory)
        defer { tab.close() }
        let profile = tab.chromiumProfile
        let directory = Store.file("Chromium").appendingPathComponent("space-" + profile)
        let receipt = Store.file("ChromiumProfiles").appendingPathComponent(logical.uuidString + "-named.json")
        let clientBefore = ChromiumProcess.shared.connectedClient
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let web = try #require(tab.page.webKit)
        #expect(tab.chromiumDRMExtensions == nil)
        #expect(ChromiumDRMExtensionSession.all[profile] == nil)
        #expect(!ChromiumDRMCookies.needsPreparation(tab))
        // Exercise the real first-navigation hook, not just the view factory.
        try await web.navigationEvents.prepareChromiumCookies?(URL(string: "https://plain-wk.test/")!)
        #expect(tab.chromiumDRMExtensions == nil)
        #expect(ChromiumDRMExtensionSession.all[profile] == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        #expect(ChromiumProcess.shared.connectedClient === clientBefore)
    }

    @Test func tabsInSharedSpacesUseTheirOneActualWebsiteStore() {
        _ = NSApplication.shared
        let store = Store.websites
        let a = Tab(configuration: Web.configuration(store: store))
        let b = Tab(configuration: Web.configuration(store: store))
        let first = Browser(windowID: UUID()), mail = Browser(windowID: UUID())
        first.spaceID = Space.firstID; mail.spaceID = Space.mailID
        a.delegate = first; b.delegate = mail
        defer { a.close(); b.close() }
        #expect(a.chromiumProfile == b.chromiumProfile)
        #expect(a.builtPage == nil && b.builtPage == nil)
    }

    @Test func aRowMoveCannotReinterpretTheExistingStoresSignIns() {
        _ = NSApplication.shared
        let identity = UUID()
        let store = WKWebsiteDataStore(forIdentifier: identity)
        let tab = Tab(configuration: Web.configuration(store: store))
        let browser = Browser(windowID: UUID())
        tab.delegate = browser
        defer { tab.close() }
        #expect(tab.chromiumProfile == identity.uuidString)
        browser.spaceID = UUID()
        #expect(tab.chromiumProfile == identity.uuidString)
        #expect(tab.builtPage == nil)
    }

    @Test func anInternalNonpersistentStoreStaysEphemeralWithoutAPrivateWindow() {
        _ = NSApplication.shared
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = Web.configuration(store: store)
        let tab = Tab(configuration: configuration)
        let profile = tab.chromiumProfile
        #expect(!tab.shy && profile.hasPrefix("private-"))
        tab.close()
        let next = Tab(configuration: configuration)
        defer { next.close() }
        #expect(next.chromiumProfile != profile)
        #expect(next.builtPage == nil)
    }
}
