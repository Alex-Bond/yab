import CryptoKit
import WebKit
import XCTest
@testable import YabPhone

/// Profile relocation must keep WebKit's namespace as well as the tab snapshot.
/// Cookies are native, disposable, and never sent to an external website.
@MainActor
final class BrowserIdentityTests: XCTestCase {
    private var root: URL!
    private var stores = Set<UUID>()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserIdentityTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for id in stores { try await WKWebsiteDataStore.remove(forIdentifier: id) }
        stores.removeAll()
        try FileManager.default.removeItem(at: root)
    }

    func testSavedIdentityAndCookieSurviveCopyMoveAndRelaunch() async throws {
        let original = root.appendingPathComponent("original")
        let copied = root.appendingPathComponent("copied")
        let moved = root.appendingPathComponent("moved")
        let profile = BrowserProfile(folder: original)
        let id = try XCTUnwrap(profile.dataStoreID)
        stores.insert(id)
        // The namespace is recorded before AppModel can create its first WebPool.
        let identity = try? Data(contentsOf: original.appendingPathComponent("website-data-store.json"))
        XCTAssertNotNil(identity)
        let app = makeApp(profile)
        XCTAssertEqual(app.websiteDataStore.identifier, id)
        await setCookie("ordinary", value: "retained", in: app.websiteDataStore)
        app.browser.open(PageFixtures.liveTab(for: URL(string: "https://identity.test/Exact?q=a%2Bb#part")!, id: "saved"))
        await app.flushProfile()

        try FileManager.default.copyItem(at: original, to: copied)
        let copyProfile = BrowserProfile(folder: copied)
        track(copyProfile)
        let copy = makeApp(copyProfile)
        XCTAssertEqual(copyProfile.dataStoreID, id)
        XCTAssertEqual(copy.browser.tab?.url, app.browser.tab?.url)
        let copyCookie = await cookie("ordinary", in: copy.websiteDataStore)
        XCTAssertEqual(copyCookie, "retained")
        XCTAssertEqual(try? Data(contentsOf: copied.appendingPathComponent("website-data-store.json")), identity)

        try FileManager.default.moveItem(at: copied, to: moved)
        let movedProfile = BrowserProfile(folder: moved)
        track(movedProfile)
        let relaunched = makeApp(movedProfile)
        XCTAssertEqual(movedProfile.dataStoreID, id)
        XCTAssertEqual(relaunched.websiteDataStore.identifier, id)
        let movedCookie = await cookie("ordinary", in: relaunched.websiteDataStore)
        XCTAssertEqual(movedCookie, "retained")
        XCTAssertEqual(BrowserProfile(folder: moved).dataStoreID, id)
    }

    func testLegacyOriginalFolderKeepsItsExactExistingStore() async throws {
        let original = root.appendingPathComponent("legacy")
        let copied = root.appendingPathComponent("legacy-relocated")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try JSONEncoder().encode(BrowserProfile.Snapshot.empty())
            .write(to: original.appendingPathComponent("profile.json"))
        let legacyID = previousStoreID(original)
        stores.insert(legacyID)
        let oldStore = WKWebsiteDataStore(forIdentifier: legacyID)
        await setCookie("legacy", value: "own-old-store", in: oldStore)

        let migrated = BrowserProfile(folder: original)
        XCTAssertEqual(migrated.dataStoreID, legacyID)
        XCTAssertNil(migrated.lastWriteError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("website-data-store.json").path))
        try FileManager.default.copyItem(at: original, to: copied)
        let restored = BrowserProfile(folder: copied)
        track(restored)
        XCTAssertEqual(restored.dataStoreID, legacyID)
        let model = makeApp(restored)
        let legacyCookie = await cookie("legacy", in: model.websiteDataStore)
        XCTAssertEqual(legacyCookie, "own-old-store")
    }

    func testNewProfilesAndPrivateWebKitStoresRemainIsolated() async throws {
        let one = BrowserProfile(folder: root.appendingPathComponent("one"))
        let two = BrowserProfile(folder: root.appendingPathComponent("two"))
        let firstID = try XCTUnwrap(one.dataStoreID), secondID = try XCTUnwrap(two.dataStoreID)
        stores.formUnion([firstID, secondID])
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertNotEqual(firstID, try World.load(named: "mira").dataStoreID)
        let first = makeApp(one), second = makeApp(two)
        await setCookie("ordinary", value: "one-only", in: first.websiteDataStore)
        let otherCookie = await cookie("ordinary", in: second.websiteDataStore)
        XCTAssertNil(otherCookie)

        let shy = first.pages.privateStore
        XCTAssertFalse(shy.isPersistent)
        XCTAssertNil(shy.identifier)
        let publicInPrivate = await cookie("ordinary", in: shy)
        XCTAssertNil(publicInPrivate)
        await setCookie("private", value: "private-only", in: shy)
        let privateInPublic = await cookie("private", in: first.websiteDataStore)
        XCTAssertNil(privateInPublic)
        let privateInOther = await cookie("private", in: second.websiteDataStore)
        XCTAssertNil(privateInOther)
        let firstCookie = await cookie("ordinary", in: first.websiteDataStore)
        XCTAssertEqual(firstCookie, "one-only")
    }

    func testUnwritableIdentityNeverOpensARotatingPersistentStore() async throws {
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let profile = BrowserProfile(folder: blocked)
        track(profile)
        XCTAssertNil(profile.dataStoreID)
        XCTAssertNotNil(profile.lastWriteError)
        XCTAssertFalse(makeApp(profile).websiteDataStore.isPersistent)
        await profile.flush()
        XCTAssertNotNil(profile.lastWriteError)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("not a directory".utf8))
    }

    func testInvalidSavedIdentityIsPreservedAndFailsClosedEvenAfterFlush() async throws {
        for (index, invalid) in [
            Data("unreadable identity".utf8),
            Data(#"{"version":2,"dataStoreID":"12345678-1234-4321-ABCD-123456789012"}"#.utf8),
            Data(#"{"version":1,"dataStoreID":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        ].enumerated() {
            let folder = root.appendingPathComponent("invalid-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("website-data-store.json")
            try invalid.write(to: file)
            let profile = BrowserProfile(folder: folder)
            track(profile)
            XCTAssertNil(profile.dataStoreID)
            XCTAssertNotNil(profile.lastWriteError)
            XCTAssertFalse(makeApp(profile).websiteDataStore.isPersistent)
            await profile.flush()
            XCTAssertNotNil(profile.lastWriteError, "a successful tab checkpoint must not hide an identity failure")
            XCTAssertEqual(try Data(contentsOf: file), invalid)
        }
    }

    private func track(_ profile: BrowserProfile) {
        let id: UUID? = profile.dataStoreID
        if let id { stores.insert(id) }
    }

    private func makeApp(_ profile: BrowserProfile) -> AppModel {
        AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
    }

    private func setCookie(_ name: String, value: String, in store: WKWebsiteDataStore) async {
        let cookie = HTTPCookie(properties: [.domain: "identity.test", .path: "/", .name: name, .value: value,
                                            .expires: Date().addingTimeInterval(86_400)])!
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func cookie(_ name: String, in store: WKWebsiteDataStore) async -> String? {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.first { $0.name == name && $0.domain == "identity.test" }?.value)
            }
        }
    }

    /// The previous release's exact namespace contract is tested independently.
    private func previousStoreID(_ folder: URL) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("yab-profile:" + folder.standardizedFileURL.path).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
