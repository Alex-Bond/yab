import Network
import SyncKit
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// All profile folders, persistent namespaces and HTTP requests are test-owned.
@MainActor
final class SpaceWebsiteStoreTests: XCTestCase {
    private var site: SignInPages!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var apps: [AppModel] = []
    private var directories: [URL] = []
    private var namespaces = Set<UUID>()
    private var extraViews: [WKWebView] = []
    private var previousDisabled = false
    private var journalLeases: [JournalLease] = []

    override func setUp() async throws {
        previousDisabled = Motion.disabled
        Motion.disabled = true
        cleanupPhase("setup: create and start owned listener")
        do {
            site = try SignInPages()
            try await site.start()
        } catch {
            cleanupError("setup.listener", error)
            throw error
        }
        cleanupPhase("setup: owned listener ready")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen)) }
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    private final class AppLease {
        weak var value: AppModel?
        init(_ app: AppModel) { value = app }
    }
    private final class ViewLease {
        weak var value: WKWebView?
        init(_ view: WKWebView) { value = view }
    }
    private final class JournalLease {
        weak var value: Journal?
        init(_ journal: Journal) { value = journal }
    }

    override func tearDown() async throws {
        defer { Motion.disabled = previousDisabled }
        cleanupPhase("detach owned apps and views")
        let appLeases = apps.map(AppLease.init), viewLeases = extraViews.map(ViewLease.init)
        await detachOwnedContent()
        cleanupPhase("await actual owned app and view release")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, appLeases.contains(where: { $0.value != nil })
            || viewLeases.contains(where: { $0.value != nil }) || journalLeases.contains(where: { $0.value != nil }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard appLeases.allSatisfy({ $0.value == nil }), viewLeases.allSatisfy({ $0.value == nil }),
              journalLeases.allSatisfy({ $0.value == nil }) else {
            cleanupPhase("release failed; owned stores and folders retained")
            XCTFail("Owned apps or WebKit views are still retained; not removing their active stores or folders")
            return
        }
        journalLeases = []
        cleanupPhase("owned objects released; begin namespace removal")
        for id in namespaces {
            cleanupPhase("cleanup.remove: begin owned namespace")
            do { try await removeOwnedNamespace(id) }
            catch { cleanupError("cleanup.remove", error); throw error }
            cleanupPhase("cleanup.remove: owned namespace complete")
        }
        namespaces = []
        cleanupPhase("namespace removal complete; remove owned profile folders")
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories = []
        cleanupPhase("cleanup complete")
    }

    // Return before weak checks so loop locals cannot keep an owner alive.
    private func detachOwnedContent() async {
        for app in apps {
            for tab in app.browser.allTabs { app.pages.forget(tab.id) }
            await app.flushProfile()
        }
        for view in extraViews {
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.removeFromSuperview()
        }
        extraViews = []
        apps = []
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKey?.makeKey()
        site?.stop()
        site = nil
    }

    private func removeOwnedNamespace(_ id: UUID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                let native = error as NSError
                cleanupPhase("namespace removal error: \(native.domain) code \(native.code)")
                // Only the exact network-process lease error observed in R9
                // may drain. Every other error, or a deadline, still fails.
                guard native.domain == "WKWebSiteDataStore", native.code == 1,
                      native.localizedDescription == "Data store is in use (by network process)", Date() < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func cleanupError(_ phase: String, _ error: Error) {
        let native = error as NSError
        cleanupPhase("\(phase): error type \(String(reflecting: type(of: error))), domain \(native.domain), code \(native.code)")
    }

    private func cleanupPhase(_ phase: String) {
        let attachment = XCTAttachment(string: phase)
        attachment.name = "owned-website-store-cleanup"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSharedIdentityAndOwnNamespaceSurviveProfileRelocationAndRelaunch() async throws {
        let app = makeApp()
        let sharedID = try XCTUnwrap(app.profile?.dataStoreID)
        let shared = try await open("a", in: app)
        XCTAssertEqual(shared.configuration.websiteDataStore.identifier, sharedID)
        try await write("shared", in: shared)
        let own = try await open("own-a", in: app)
        let ownID = try XCTUnwrap(own.configuration.websiteDataStore.identifier)
        XCTAssertNotEqual(ownID, sharedID)
        try await write("own-a", in: own)
        await app.flushProfile()
        let original = try XCTUnwrap(app.profile?.folder)
        let relocated = folder()
        try FileManager.default.copyItem(at: original, to: relocated)
        let profile = BrowserProfile(folder: relocated)
        XCTAssertEqual(profile.dataStoreID, sharedID)
        var renamed = try XCTUnwrap(app.browser.space("own-a"))
        renamed.name = "Renamed"
        renamed.emoji = "X"
        XCTAssertEqual(profile.websiteStoreID(for: renamed), ownID)
        let relaunched = makeApp(profile: profile)
        let restoredOwn = try await open("own-a", in: relaunched, newTab: false)
        XCTAssertNotNil(relaunched.pages.reload(try XCTUnwrap(relaunched.browser.tab?.id)))
        try await painted(relaunched.pages, try XCTUnwrap(relaunched.browser.tab?.id))
        try await expect("own-a", in: restoredOwn)
        XCTAssertEqual(restoredOwn.configuration.websiteDataStore.identifier, ownID)
        XCTAssertTrue(site.cookie(for: restoredOwn.url!).contains("scope=own-a"))
        attach("own-space-relaunch")
        let restoredShared = try await open("a", in: relaunched, newTab: false)
        XCTAssertNotNil(relaunched.pages.reload(try XCTUnwrap(relaunched.browser.tab?.id)))
        try await painted(relaunched.pages, try XCTUnwrap(relaunched.browser.tab?.id))
        try await expect("shared", in: restoredShared)
        XCTAssertEqual(restoredShared.configuration.websiteDataStore.identifier, sharedID)
        XCTAssertTrue(site.cookie(for: restoredShared.url!).contains("scope=shared"))
    }

    func testOwnSharedAndDifferentProfilesHaveActualCookieAndStorageBoundaries() async throws {
        let app = makeApp()
        let sharedA = try await open("a", in: app)
        try await write("shared", in: sharedA)
        let sharedB = try await open("b", in: app)
        try await expect("shared", in: sharedB)
        XCTAssertTrue(site.cookie(for: sharedB.url!).contains("scope=shared"))
        let ownA = try await open("own-a", in: app)
        try await expect(nil, in: ownA)
        XCTAssertFalse(site.cookie(for: ownA.url!).contains("scope="))
        try await write("a", in: ownA)
        let ownB = try await open("own-b", in: app)
        try await expect(nil, in: ownB)
        XCTAssertFalse(site.cookie(for: ownB.url!).contains("scope="))
        try await write("b", in: ownB)
        for _ in 0..<WebPool.liveLimit { _ = try await open("b", in: app) }
        let againA = try await open("own-a", in: app, newTab: false)
        try await expect("a", in: againA)
        XCTAssertFalse(againA === ownA, "eviction must rebuild the view while keeping its own jar")
        let other = makeApp()
        let otherA = try await open("own-a", in: other)
        try await expect(nil, in: otherA)
        XCTAssertNotEqual(otherA.configuration.websiteDataStore.identifier, againA.configuration.websiteDataStore.identifier)
        XCTAssertFalse(site.cookie(for: otherA.url!).contains("scope="))
    }

    func testFlagChangesAndMoveCheckpointHistoryButNeverTransferNativeFormsOrPixels() async throws {
        let app = makeApp()
        let view = try await open("a", in: app)
        let id = try XCTUnwrap(app.browser.tab?.id)
        try await write("shared", in: view)
        let second = site.url("/second?scope=move&literal=a%2Bb#part")
        app.pages.load(id, second)
        try await painted(app.pages, id)
        _ = try await view.evaluateJavaScript("document.querySelector('input').value='unsaved source';window.scrollTo(0,180)")
        XCTAssertNotNil(app.browser.tab(id))
        let before = try XCTUnwrap(app.pages.navigationState(for: id))
        app.pages.picture(id)
        try await eventually { app.pages.snapshots[id] != nil }
        app.browser.setSpaceSignIns("a", own: true)
        _ = app.pages.reconcileWebsiteStores(app.browser.allTabs)
        XCTAssertNil(app.pages.snapshots[id], "a picture of the old store's page does not move with the tab")
        let cleared = try XCTUnwrap(app.pages.navigationState(for: id))
        XCTAssertNil(cleared.interactionData)
        XCTAssertEqual(cleared.entries.map(\.url), before.entries.map(\.url))
        XCTAssertEqual(cleared.index, before.index)
        XCTAssertEqual(app.browser.tab?.id, id)
        let own = app.pages.activate(try XCTUnwrap(app.browser.tab(id)))
        show(own)
        try await painted(app.pages, id)
        XCTAssertFalse(own === view)
        XCTAssertEqual(own.url, second)
        try await expect(nil, in: own)
        XCTAssertFalse(site.cookie(for: second).contains("scope="))
        let freshForm = try await own.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(freshForm, "fresh")
        XCTAssertTrue(app.pages.goBack(id))
        try await painted(app.pages, id)
        XCTAssertEqual(own.url, URL(string: before.entries[0].url))
        XCTAssertTrue(app.pages.goForward(id))
        try await painted(app.pages, id)
        app.browser.move(id, to: "own-b")
        app.browser.select(id)
        _ = app.pages.reconcileWebsiteStores(app.browser.allTabs)
        let moved = app.pages.activate(try XCTUnwrap(app.browser.tab(id)))
        show(moved)
        try await painted(app.pages, id)
        XCTAssertEqual(app.browser.spaceID, "own-b")
        XCTAssertEqual(moved.url, second)
        XCTAssertNotEqual(moved.configuration.websiteDataStore.identifier, own.configuration.websiteDataStore.identifier)
        XCTAssertEqual(app.pages.navigationState(for: id)?.entries.map(\.url), before.entries.map(\.url))
        try await expect(nil, in: moved)
        app.browser.move(id, to: "a")
        app.browser.setSpaceSignIns("a", own: false)
        app.browser.select(id)
        let backShared = app.pages.activate(try XCTUnwrap(app.browser.tab(id)))
        show(backShared)
        try await painted(app.pages, id)
        try await expect("shared", in: backShared)
        XCTAssertTrue(site.cookie(for: second).contains("scope=shared"))
        try await touch(backShared)
    }

    func testPrivateHasNoPublicCookiesAndNeverPersistsItsTimeline() async throws {
        let app = makeApp()
        let publicSource = try await open("own-a", in: app)
        try await write("public", in: publicSource)
        let view = try await open("private", in: app)
        let id = try XCTUnwrap(app.browser.tab?.id)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(view.configuration.websiteDataStore.identifier)
        try await expect(nil, in: view)
        XCTAssertFalse(site.cookie(for: view.url!).contains("scope="))
        try await write("private", in: view)
        attach("private-owned-store")
        let sameStore = view.configuration.websiteDataStore
        XCTAssertNotNil(app.pages.reload(id))
        try await painted(app.pages, id)
        try await expect("private", in: view)
        XCTAssertTrue(view.configuration.websiteDataStore === sameStore)
        await app.flushProfile()
        let profile = try XCTUnwrap(app.profile)
        XCTAssertNil(profile.navigation[id])
        XCTAssertFalse(profile.snapshot.spaces.contains(where: \.isPrivate))
        XCTAssertFalse(profile.recent.contains { $0.url.contains("scope=private") })
        app.pages.renewPrivateStore()
        let renewed = app.pages.activate(try XCTUnwrap(app.browser.tab(id)))
        show(renewed)
        try await painted(app.pages, id)
        try await expect(nil, in: renewed)
        XCTAssertFalse(renewed.configuration.websiteDataStore === sameStore)
        XCTAssertFalse(site.cookie(for: renewed.url!).contains("scope="))
        let publicView = try await open("own-a", in: app, newTab: false)
        try await expect("public", in: publicView)
    }

    func testPopupsKeepSourceSpaceWhenAnotherSpaceIsSelectedAndRejectStaleDomain() async throws {
        let app = makeApp()
        for space in ["own-a", "private"] {
            let source = try await open(space, in: app)
            let sourceID = try XCTUnwrap(app.browser.tab?.id)
            try await write(space, in: source)
            app.browser.showSpace("b")
            let before = Set(app.browser.allTabs.map(\.id))
            source.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            _ = try await source.evaluateJavaScript("document.getElementById('popup').click()")
            try await eventually { app.browser.allTabs.contains { !before.contains($0.id) } }
            let popupTab = try XCTUnwrap(app.browser.allTabs.first { !before.contains($0.id) })
            XCTAssertEqual(app.browser.space(holding: popupTab.id)?.id, space)
            XCTAssertEqual(popupTab.isPrivate, space == "private")
            let popup = app.pages.view(for: popupTab)
            show(popup)
            try await painted(app.pages, popupTab.id)
            XCTAssertTrue(popup.configuration.websiteDataStore === source.configuration.websiteDataStore)
            try await expect(space, in: popup)
            XCTAssertTrue(site.cookie(for: popup.url!).contains("scope=\(space)"))
            if space == "own-a" {
                // An old document cannot create a popup after its jar changes.
                app.browser.setSpaceSignIns(space, own: false)
                let ids = Set(app.browser.allTabs.map(\.id))
                _ = try? await source.evaluateJavaScript("document.getElementById('popup').click()")
                XCTAssertEqual(Set(app.browser.allTabs.map(\.id)), ids)
            }
            app.pages.forget(sourceID)
        }
    }

    func testMissingIdentityCannotOpenPersistentSpaceStoresAndLegacyNativeStateIsSharedOnly() async throws {
        let broken = folder()
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: broken.appendingPathComponent("website-data-store.json"))
        let profile = BrowserProfile(folder: broken)
        XCTAssertNil(profile.dataStoreID)
        let app = makeApp(profile: profile)
        let ownA = try await open("own-a", in: app)
        let ownB = try await open("own-b", in: app)
        XCTAssertFalse(ownA.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(ownB.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(ownA.configuration.websiteDataStore === ownB.configuration.websiteDataStore)
        XCTAssertNil(profile.websiteStoreID(for: try XCTUnwrap(app.browser.space("own-a"))))
        let healthy = makeApp()
        let shared = try await open("a", in: healthy)
        _ = try await shared.evaluateJavaScript("document.querySelector('input').value='legacy source form'")
        let sourceID = try XCTUnwrap(healthy.browser.tab?.id)
        var legacy = try XCTUnwrap(healthy.pages.navigationState(for: sourceID))
        XCTAssertNotNil(legacy.interactionData, "the legacy restoration negative needs actual native state")
        legacy.websiteStoreID = nil
        legacy = try JSONDecoder().decode(BrowserNavigation.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(legacy.websiteStoreID)
        let ownID = "legacy.own"
        let tab = PageFixtures.liveTab(for: try XCTUnwrap(shared.url), id: ownID)
        healthy.browser.open(tab, in: "own-a")
        healthy.pages.navigationForTab = { id in id == ownID ? legacy : nil }
        let restored = healthy.pages.activate(tab)
        show(restored)
        try await painted(healthy.pages, ownID)
        let form = try await restored.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(form, "fresh")
        XCTAssertEqual(healthy.pages.navigationState(for: ownID)?.websiteStoreID,
                       healthy.profile?.websiteStoreID(for: try XCTUnwrap(healthy.browser.space("own-a"))))
    }

    func testSignInMetadataWritesOnlyItsOwnSyncFieldAndPrivateCannotChangePolicy() throws {
        let engine = try PhoneSync(seal: .make(), options: .init(base: URL(string: "https://sync.test")!, folder: folder(),
            device: .init(id: "owned-phone", name: "Test iPhone", model: "iPhone"), transport: SyncMemoryServer()))
        defer { engine.stop() }
        journalLeases.append(JournalLease(engine.journal))
        let id = UUID().uuidString
        var fields = SyncSpace(id: id, name: "Preserved", icon: "X", origin: "Arc:owned", order: "a").fields
        fields["future"] = "retained"
        try engine.journal.change(.init(collection: SyncCollection.space, id: id), fields)
        let key = Record.Key(collection: SyncCollection.space, id: id)
        let before = try XCTUnwrap(engine.journal.record(key))
        XCTAssertEqual(try engine.setSpaceSignIns(id, own: true).ownSignIns, true)
        let after = try XCTUnwrap(engine.journal.record(key))
        XCTAssertEqual(after["ownSignIns"], .bool(true))
        for field in fields.keys where field != "ownSignIns" { XCTAssertEqual(after[field], before[field], field) }
        XCTAssertEqual(try engine.setSpaceSignIns(id, own: false).ownSignIns, false)
        let app = makeApp()
        let privateBefore = try XCTUnwrap(app.browser.space("private"))
        app.browser.setSpaceSignIns("private", own: true)
        XCTAssertEqual(app.browser.space("private"), privateBefore)
    }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceWebsiteStores-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    private func publicSpace(_ id: String, own: Bool = false) -> Space {
        Space(id: id, name: id, emoji: "X", tint: RGB(238, 233, 226), ownSignIns: own)
    }

    private func privateSpace() -> Space {
        Space(id: "private", name: "Private", emoji: "", tint: RGB(0, 0, 0), isPrivate: true)
    }

    private func makeApp(profile: BrowserProfile? = nil, authentication: SignInAuthentication? = nil,
                         lockEnabled: Bool = false) -> AppModel {
        let profile = profile ?? BrowserProfile(folder: folder())
        let spaces = [privateSpace(), publicSpace("a"), publicSpace("b"), publicSpace("own-a", own: true), publicSpace("own-b", own: true)]
        let world = profile.snapshot.spaces.contains(where: { $0.id == "own-a" }) ? profile.world :
            World(name: "website stores", space: "a", spaces: spaces, mac: World.Mac(joined: false))
        let app = AppModel(world: world, fixturesEnabled: false, profile: profile,
                           privateAuthentication: authentication, privateLockEnabled: { lockEnabled })
        apps.append(app)
        app.pages.setViewport(PageViewport(size: window.bounds.size, hardware: window.safeAreaInsets,
                                          chrome: .init(folded: false, hasNow: false, visible: true)))
        for space in app.browser.spaces {
            if let id = profile.websiteStoreID(for: space) { namespaces.insert(id) }
        }
        return app
    }

    private func open(_ space: Space.ID, in app: AppModel, newTab: Bool = true) async throws -> WKWebView {
        app.browser.showSpace(space)
        if newTab {
            app.browser.open(PageFixtures.liveTab(for: site.url("/page?scope=\(space)")), in: space, deduplicate: false)
        }
        let tab = try XCTUnwrap(app.browser.tab)
        let view = app.pages.activate(tab)
        show(view)
        try await painted(app.pages, tab.id)
        if let id = view.configuration.websiteDataStore.identifier { namespaces.insert(id) }
        return view
    }

    private func show(_ view: WKWebView) {
        if let id = view.configuration.websiteDataStore.identifier { namespaces.insert(id) }
        let host = window.rootViewController!.view!
        for other in host.subviews { other.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        window.layoutIfNeeded()
    }

    private func write(_ value: String, in view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("document.cookie='scope=\(value);path=/;max-age=86400';localStorage.setItem('scope','\(value)')")
        try await expect(value, in: view)
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(cookies.contains { $0.name == "scope" && $0.value == value })
    }

    private func expect(_ value: String?, in view: WKWebView) async throws {
        let result = try await view.evaluateJavaScript("({cookie:document.cookie,storage:localStorage.getItem('scope')})") as? [String: Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["storage"] as? String, value)
        _ = try await view.evaluateJavaScript("showOwnedState()")
        let cookie = result?["cookie"] as? String ?? ""
        if let value { XCTAssertTrue(cookie.contains("scope=\(value)")) }
        else { XCTAssertFalse(cookie.contains("scope=")) }
    }

    private func attach(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let pixels = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: pixels)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func touch(_ view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("document.getElementById('action').click()")
        let count = try await view.evaluateJavaScript("window.actions") as? Int
        XCTAssertEqual(count, 1)
    }

    private func painted(_ pages: WebPool, _ id: Tab.ID) async throws {
        // 25 s, as the browser basics' (cc9cfbd1): a loopback page took longer than 10 s
        // to paint with the UI suite running on the same Mac (635f1948bcba4bb2).
        await pages.waitUntilPainted(id, timeout: .seconds(25))
        guard pages.painted.contains(id) else {
            XCTFail("owned page did not paint: \(pages.describe(id))")
            throw NSError(domain: "SpaceWebsiteStoreTests.Paint", code: 1)
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
        guard condition() else {
            XCTFail("owned WebKit condition did not arrive")
            throw NSError(domain: "SpaceWebsiteStoreTests.Arrival", code: 1)
        }
    }
}

@MainActor
private final class SignInAuthentication: PrivateAuthenticating {
    private(set) var calls = 0
    private var completion: (@MainActor (PrivateAuthenticationResult) -> Void)?
    func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void) {
        calls += 1
        self.completion = completion
    }
    func invalidate() { completion = nil }
    func complete(_ result: PrivateAuthenticationResult) { completion?(result) }
}

/// Complete bounded HTTP headers and FIN, with only owned cookie receipts.
private final class SignInPages: @unchecked Sendable {
    private let queue = DispatchQueue(label: "yab.tests.space-signins")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var cookies: [String: String] = [:]
    private var counts: [String: Int] = [:]
    private var waiter: CheckedContinuation<Void, Error>?
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, prior: Data())
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                waiter = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let continuation = self.waiter else { return }
                    switch state {
                    case .ready:
                        self.waiter = nil
                        self.port = self.listener.port!.rawValue
                        continuation.resume()
                    case let .failed(error):
                        self.waiter = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, let continuation = self.waiter else { return }
                    self.waiter = nil
                    self.listener.cancel()
                    continuation.resume(throwing: NSError(domain: "SpaceWebsiteStoreTests.Listener", code: 1))
                }
            }
        }
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections = []
            if let continuation = waiter {
                waiter = nil
                continuation.resume(throwing: NSError(domain: "SpaceWebsiteStoreTests.Listener", code: 2))
            }
        }
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func cookie(for url: URL) -> String { queue.sync { cookies[key(url), default: ""] } }
    func count(for url: URL) -> Int { queue.sync { counts[key(url), default: 0] } }
    private func key(_ url: URL) -> String { url.path + (url.query.map { "?" + $0 } ?? "") }

    private func receive(_ connection: NWConnection, prior: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var data = prior
            if let chunk { data.append(chunk) }
            guard data.count <= 32_768 else { connection.cancel(); return }
            guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !done { self.receive(connection, prior: data) }
                else { connection.cancel() }
                return
            }
            let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
            let cookie = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("cookie:") }
                .map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) } ?? ""
            self.cookies[path] = cookie
            self.counts[path, default: 0] += 1
            let body = """
            <!doctype html><meta name=viewport content=width=device-width><link rel=icon href=data:,>
            <title>Owned sign-in page</title><body style='background:#fff;margin:0;min-height:2000px'>
            <h1>Owned sign-in page</h1><pre id=state></pre><input value=fresh><button id=action>Page action</button>
            <a id=popup href='/popup?scope=popup' target=_blank>Popup</a>
            <script>window.actions=0;function showOwnedState(){document.getElementById('state').textContent='Cookie: '+document.cookie+'\\nStorage: '+localStorage.getItem('scope')}showOwnedState();document.getElementById('action').addEventListener('click',()=>window.actions++);</script>
            </body>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
