import XCTest
@testable import YabPhone

@MainActor
final class BrowserProfileTests: XCTestCase {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BrowserProfileTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func tab(_ id: String, _ address: String, isPrivate: Bool = false) -> Tab {
        PageFixtures.liveTab(for: URL(string: address)!, id: id, isPrivate: isPrivate)
    }

    func testLinkedSpacesUseOneWebsiteStoreAndSurviveCoding() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfile(folder: directory)
        let owner = Space(id: UUID().uuidString, name: "Owner", emoji: "💼", tint: RGB(128, 128, 128), ownSignIns: true)
        var member = owner
        member.id = UUID().uuidString
        member.signInWith = owner.id
        let third = Space(id: UUID().uuidString, name: "Own", emoji: "✈️", tint: owner.tint, ownSignIns: true)
        let back = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(member))
        XCTAssertEqual(back.signInWith, owner.id)
        XCTAssertEqual(profile.websiteStoreID(for: owner), profile.websiteStoreID(for: back))
        XCTAssertNotEqual(profile.websiteStoreID(for: owner), profile.websiteStoreID(for: third))
    }

    func testNormalLaunchRestoresAProfileAndNamedWorldsKeepFixtures() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = LaunchOptions(arguments: ["Yab", "-YabProfileDirectory", directory.path])
        XCTAssertNil(options.fixtureWorld)
        let app = AppModel.launch(options)
        XCTAssertFalse(app.isFixture)
        XCTAssertEqual(app.browser.spaces.map(\.id), ["local.private", "local.personal"])
        XCTAssertNil(app.browser.tab, "a new profile starts with no tabs")
        XCTAssertTrue(app.tasks.runs.isEmpty)
        XCTAssertTrue(app.chats.chats.isEmpty)
        app.browser.open(tab("ordinary", "https://example.com/a"))
        await app.flushProfile()

        let restored = AppModel.launch(options)
        XCTAssertEqual(restored.browser.tab?.url, "https://example.com/a")
        XCTAssertEqual(restored.profile?.dataStoreID, app.profile?.dataStoreID)
        let fixture = AppModel.launch(LaunchOptions(arguments: ["Yab", "-YabWorld", "mira"]))
        XCTAssertTrue(fixture.isFixture)
        XCTAssertNil(fixture.profile)
        XCTAssertEqual(fixture.browser.spaces.map(\.id), ["personal", "work", "lisbon"])
        XCTAssertTrue(AppModel(world: try World.load(named: "mira")).isFixture)
        XCTAssertEqual(LaunchOptions(arguments: ["Yab", "-YabState", "page.1"]).fixtureWorld, "mira")
    }

    func testLiveNamedStatesRequireAnExplicitIsolatedProfile() {
        let state = ["Yab", "-YabState", "duo.rotation.right", "-YabLiveState", "YES"]
        XCTAssertEqual(LaunchOptions(arguments: state).fixtureWorld, "mira")
        let live = LaunchOptions(arguments: state + ["-YabProfileDirectory", folder().path])
        XCTAssertNil(live.fixtureWorld)
        XCTAssertTrue(live.isTestRun)
        XCTAssertNil(SyncBridge.Setup.resolve(options: live, arguments: []))
        XCTAssertEqual(LaunchOptions(arguments: state + ["-YabWorld", "mira", "-YabProfileDirectory", folder().path]).fixtureWorld, "mira")
    }

    func testExplicitProfileDirectoryNeverUsesPersonalSyncWithoutEnvironmentFlags() {
        let options = LaunchOptions(arguments: ["Yab", "-YabProfileDirectory", folder().path])
        XCTAssertTrue(options.isTestRun)
        XCTAssertNil(options.fixtureWorld)
        XCTAssertNil(SyncBridge.Setup.resolve(options: options, arguments: []))
        let environment = LaunchOptions(arguments: ["Yab"], environment: ["YAB_PROFILE_DIRECTORY": folder().path])
        XCTAssertTrue(environment.isTestRun)
        XCTAssertNil(SyncBridge.Setup.resolve(options: environment, arguments: []))
        XCTAssertFalse(LaunchOptions(arguments: ["Yab"]).isTestRun)
    }

    func testTabsSpaceSelectionNavigationAndScrollSurviveAnotherLaunch() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfile(folder: directory)
        let store = BrowserStore(world: profile.world)
        let one = tab("one", "http://localhost:8765/A?q=Two#three")
        let two = tab("two", "https://example.com/b")
        store.adopt([
            Space(id: "first", name: "First", emoji: "", tint: RGB(1, 2, 3), pins: [one], current: one.id),
            Space(id: "second", name: "Second", emoji: "", tint: RGB(4, 5, 6), kept: [.folder(Folder(id: "folder", name: "Folder", open: true, tabs: [two]))], current: two.id)
        ])
        store.showSpace("second")
        profile.capture(store)
        let state = BrowserNavigation(entries: [
            .init(url: "https://example.com/a", title: "A", scrollY: 120),
            .init(url: "https://example.com/b", title: "B", scrollY: 456)
        ], index: 1, interactionData: Data([1, 2, 3]))
        profile.navigationChanged(two.id, state)
        profile.recordVisit(one, now: Date(timeIntervalSince1970: 1))
        profile.recordVisit(two, now: Date(timeIntervalSince1970: 2))
        await profile.flush()

        let restored = BrowserProfile(folder: directory)
        XCTAssertNil(restored.lastWriteError)
        XCTAssertEqual(restored.snapshot.spaces, store.spaces)
        XCTAssertEqual(restored.snapshot.spaceID, "second")
        XCTAssertEqual(restored.navigation[two.id], state)
        XCTAssertEqual(restored.recent.map(\.url), ["https://example.com/b", "http://localhost:8765/A?q=Two#three"])
        XCTAssertEqual(BrowserStore(world: restored.world).tab?.id, "two")
    }

    func testPrivateTabsSpacesNavigationAndVisitsNeverReachDisk() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfile(folder: directory)
        let store = BrowserStore(world: profile.world)
        let ordinary = tab("public", "https://example.com/public")
        let secret = tab("secret", "https://private.example/secret", isPrivate: true)
        let privateSpaceTab = tab("private-space-tab", "https://private.example/space")
        store.adopt([
            Space(id: "public-space", name: "Public", emoji: "", tint: RGB(1, 2, 3), pins: [secret],
                  kept: [.folder(Folder(id: "folder", name: "Folder", tabs: [ordinary, secret]))], today: [secret], current: secret.id),
            Space(id: "private-space", name: "Secret space", emoji: "", tint: RGB(0, 0, 0), today: [privateSpaceTab], isPrivate: true)
        ])
        store.showSpace("private-space")
        XCTAssertTrue(store.tab(privateSpaceTab.id)?.isPrivate ?? false, "a private space supplies the flag omitted by a record")
        profile.capture(store)
        profile.navigationChanged(secret.id, BrowserNavigation(entries: [.init(url: secret.url!, title: "Secret", scrollY: 987)], index: 0))
        profile.recordVisit(secret)
        profile.recordVisit(privateSpaceTab)
        await profile.flush()

        let restored = BrowserProfile(folder: directory)
        XCTAssertEqual(restored.snapshot.spaces.map(\.id), ["public-space"])
        XCTAssertEqual(restored.snapshot.spaces.flatMap(\.allTabs).map(\.id), [ordinary.id])
        XCTAssertEqual(restored.snapshot.spaceID, "public-space")
        XCTAssertNil(restored.snapshot.spaces[0].current, "a kept tab doesn't step forward for a private one gone")
        XCTAssertTrue(restored.navigation.isEmpty)
        XCTAssertTrue(restored.recent.isEmpty)
        let encoded = try String(contentsOf: directory.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(encoded.contains("private.example"))
        XCTAssertFalse(encoded.contains("Secret space"))
    }

    func testPrivateTabsOpenedFromRealProfileAreGoneAfterRelaunchButDefaultSpaceRemains() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = LaunchOptions(arguments: ["Yab", "-YabProfileDirectory", directory.path])
        let profile = BrowserProfile.launch(options)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        let ordinary = app.browser.spaceID
        app.openPrivately(tab("secret", "https://private.example/never-persist"))
        XCTAssertTrue(app.browser.space.isPrivate)
        let secret = try XCTUnwrap(app.browser.tab)
        app.profile?.capture(app.browser)
        app.profile?.recordVisit(secret)
        app.profile?.navigationChanged(secret.id, BrowserNavigation(entries: [.init(url: secret.url!, title: "Secret")], index: 0))
        await app.flushProfile()
        let restored = AppModel.launch(options)
        XCTAssertEqual(restored.browser.spaceID, ordinary)
        XCTAssertTrue(restored.browser.spaces.first?.isPrivate == true)
        XCTAssertEqual(restored.browser.spaces.filter(\.isPrivate).count, 1)
        XCTAssertTrue(restored.browser.spaces.first?.allTabs.isEmpty == true)
        XCTAssertNil(restored.browser.tab(secret.id))
        let saved = try String(contentsOf: directory.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("private.example"))
        XCTAssertFalse(saved.contains("local.private"))
        XCTAssertTrue(restored.profile?.recent.isEmpty == true)
    }

    func testDefaultPrivateSpaceIsAvailableBeforeOpeningAnyPrivateTab() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = LaunchOptions(arguments: ["Yab", "-YabProfileDirectory", directory.path])
        let profile = BrowserProfile.launch(options)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        let ordinary = app.browser.spaceID
        let personalTab = app.browser.tab?.id
        let privateSpace = try XCTUnwrap(app.browser.spaces.first)
        XCTAssertTrue(privateSpace.isPrivate)
        XCTAssertEqual(privateSpace.name, "Private")
        XCTAssertTrue(privateSpace.allTabs.isEmpty)
        XCTAssertFalse(app.browser.space.isPrivate)
        XCTAssertEqual(app.browser.spaces.filter(\.isPrivate).count, 1)

        app.browser.showSpace(privateSpace.id)
        app.surfaces.openField(.newTab)
        XCTAssertTrue(app.field.isPrivate, "an empty default Private must open a private new-tab field")
        app.field.close()
        await app.flushProfile()
        let restored = AppModel.launch(options)
        XCTAssertEqual(restored.browser.spaceID, ordinary)
        XCTAssertEqual(restored.browser.tab?.id, personalTab)
        XCTAssertTrue(restored.browser.spaces.first?.isPrivate == true)
        XCTAssertTrue(restored.browser.spaces.first?.allTabs.isEmpty == true)
        let saved = try String(contentsOf: directory.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains(privateSpace.id), "the default Private remains outside the disk profile")
    }

    func testPublicSyncAdoptionKeepsDefaultPrivateAndItsUnsyncedTabs() throws {
        let world = World(name: "test", space: "public", spaces: [
            Space(id: "public", name: "Personal", emoji: "", tint: RGB(1, 2, 3))
        ])
        let store = BrowserStore(world: world, fixturesEnabled: false)
        let privateSpace = try XCTUnwrap(store.spaces.first)
        let secret = tab("secret", "https://private.example/local", isPrivate: true)
        store.open(secret)
        XCTAssertEqual(store.spaceID, privateSpace.id)
        let synced = Space(id: "synced", name: "Work", emoji: "", tint: RGB(4, 5, 6))
        store.adopt([synced])
        XCTAssertEqual(store.spaces.map(\.id), [privateSpace.id, synced.id])
        XCTAssertEqual(store.tab?.id, secret.id)
        XCTAssertEqual(store.ordinarySpaceID, synced.id)
        store.adopt([synced, try XCTUnwrap(store.space(privateSpace.id))])
        XCTAssertEqual(store.spaces.filter(\.isPrivate).count, 1)
        XCTAssertEqual(store.spaceID, privateSpace.id)
        store.showSpace(synced.id)
        store.adopt([Space(id: "replacement", name: "Replacement", emoji: "", tint: RGB(7, 8, 9))])
        XCTAssertFalse(store.space.isPrivate, "removing the selected public space must select another public space")
        XCTAssertNotNil(store.tab(secret.id))
    }

    func testMetadataUpdatesDoNotCountAnotherVisit() async {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfile(folder: directory)
        var page = tab("one", "https://example.com/a")
        profile.recordVisit(page, now: Date(timeIntervalSince1970: 10))
        page.title = "Page title"
        profile.recordVisit(page, countsVisit: false, now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(profile.recent.first?.count, 1)
        XCTAssertEqual(profile.recent.first?.title, "Page title")
        XCTAssertEqual(profile.recent.first?.visitedAt, Date(timeIntervalSince1970: 10))
        profile.recordVisit(tab("two", "https://example.com/b"), now: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(profile.frequent.count, 1)
        XCTAssertEqual(profile.frequent.first?.count, 2)
        await profile.flush()
    }

    func testUnreadableProfileIsPreservedBeforeAnAtomicReplacement() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("unreadable profile".utf8)
        try original.write(to: directory.appendingPathComponent("profile.json"))
        let profile = BrowserProfile(folder: directory)
        await profile.flush()
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("unreadable-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertTrue(BrowserProfile(folder: directory).snapshot.isValid)
    }

    func testPopupMayOpenTheSameAddressAsASeparateTab() {
        let profile = BrowserProfile(folder: folder())
        let store = BrowserStore(world: profile.world)
        store.open(tab("one", "https://example.com/a"))
        store.open(tab("two", "https://example.com/a"), deduplicate: false)
        XCTAssertEqual(store.space.today.prefix(2).map(\.id), ["two", "one"])
        store.open(tab("three", "https://example.com/a"))
        XCTAssertEqual(store.space.today.prefix(2).map(\.id), ["two", "one"])
        XCTAssertEqual(store.tab?.id, "two")
    }

    func testRealAddressesKeepTheirSchemeAndPathCase() {
        let profile = BrowserProfile(folder: folder())
        let store = BrowserStore(world: profile.world, fixturesEnabled: false)
        store.open(tab("http", "http://example.com/A"))
        store.open(tab("https", "https://example.com/A"))
        store.open(tab("case", "https://example.com/a"))
        XCTAssertEqual(store.space.today.prefix(3).map(\.id), ["case", "https", "http"])
        store.open(tab("duplicate", "https://example.com/A"))
        XCTAssertEqual(store.tab?.id, "https")
        XCTAssertNil(store.tab("duplicate"))
    }

    func testProfileWebsiteDataIsStableAndSeparateFromWorlds() throws {
        let directory = folder()
        let one = BrowserProfile(folder: directory)
        let two = BrowserProfile(folder: directory)
        XCTAssertEqual(one.dataStoreID, two.dataStoreID)
        XCTAssertNotEqual(one.dataStoreID, BrowserProfile(folder: folder()).dataStoreID)
        XCTAssertNotEqual(one.dataStoreID, try World.load(named: "mira").dataStoreID)
        let options = LaunchOptions(arguments: ["Yab"], environment: ["XCTestConfigurationFilePath": "tests"])
        let testProfile = BrowserProfile.launch(options)
        XCTAssertTrue(testProfile.folder.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNil(options.fixtureWorld)
    }
}
