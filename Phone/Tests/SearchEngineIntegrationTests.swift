import Network
import SyncKit
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Real settings, encrypted journal delivery and native HTTP loads use only owned stores.
@MainActor
final class SearchEngineIntegrationTests: XCTestCase {
    private var folder: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var bridges: [SyncBridge] = []
    private var apps: [AppModel] = []
    private var macs: [TestMac] = []
    private var leases: [Lease] = []
    private var site: SearchTestSite!
    private var window: UIWindow!
    private weak var oldKey: UIWindow?
    private var oldDisabled = false

    private final class Lease {
        weak var engine: PhoneSync?
        weak var client: SyncClient?
        weak var journal: Journal?
        init(_ engine: PhoneSync) { self.engine = engine; client = engine.client; journal = engine.journal }
        init(_ client: SyncClient) { self.client = client; journal = client.journal }
        var released: Bool { engine == nil && client == nil && journal == nil }
        func stop() { if let engine { engine.stop() } else { client?.stop() } }
    }
    override func setUp() async throws {
        oldDisabled = Motion.disabled; Motion.disabled = true
        folder = URL(fileURLWithPath: "/private/tmp/yab-search-integration-\(UUID())", isDirectory: true)
        suite = "owned-search-integration-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); settings = SettingsStore(defaults: defaults)
        site = try SearchTestSite()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in site.start { done.resume(with: $0) } }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        oldKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
    }
    override func tearDown() async throws {
        defer { Motion.disabled = oldDisabled; defaults?.removePersistentDomain(forName: suite) }
        for app in apps { for tab in app.browser.allTabs { app.pages.forget(tab.id) }; app.sync.end() }
        bridges.forEach { $0.end() }; macs.forEach { $0.client.stop() }; leases.forEach { $0.stop() }
        bridges = []; macs = []; apps = []
        window?.rootViewController = nil; window?.isHidden = true; window = nil; oldKey?.makeKey()
        site?.stop(); site = nil; settings = nil
        let released = await until { self.leases.allSatisfy(\.released) }
        XCTAssertTrue(released, "Owned sync references must release before removing SQLite files")
        if released { leases = []; if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
    }
    private func until(_ predicate: () -> Bool, seconds: TimeInterval = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }
    private func require(_ predicate: () -> Bool, _ message: String = "The actual owned state did not arrive", file: StaticString = #filePath, line: UInt = #line) async throws {
        let arrived = await until(predicate)
        guard arrived else { XCTFail(message, file: file, line: line); throw NSError(domain: "OwnedSearch", code: 1) }
    }
    private func app() -> AppModel {
        let world = World(name: "Owned search", space: "public", spaces: [Space(id: "public", name: "Public", emoji: "", tint: RGB(235,235,235))])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        app.field.attach(app, settings: settings)
        apps.append(app); return app
    }
    private func attach(_ app: AppModel, _ server: SyncMemoryServer, _ seal: Seal) async throws -> SyncBridge {
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try seal.raw.write(to: folder.appendingPathComponent("keys/key-shared"))
        let bridge = SyncBridge(settings: settings); bridges.append(bridge)
        bridge.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
                                      folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                      deviceName: "Owned search iPhone", transport: server, ownWorld: false))
        try await require { bridge.line == .live }
        leases.append(Lease(try XCTUnwrap(bridge.engine))); return bridge
    }
    private func mac(_ server: SyncMemoryServer, _ seal: Seal) async throws -> TestMac {
        let mac = try TestMac(server: server, seal: seal); macs.append(mac); leases.append(Lease(mac.client))
        mac.client.start(); try await require { mac.client.state == .live }; return mac
    }
    private func write(_ mac: TestMac, _ id: String, _ value: String) throws {
        try mac.write(SyncCollection.setting, id, ["value": .string(value)])
    }
    private func choose(_ engine: SearchEngine) throws {
        let rows = SettingsContent(store: settings, context: SettingsContext()).sections(.search).flatMap(\.rows)
        let row = try XCTUnwrap(rows.first { $0.id == "search.engine.\(engine.rawValue)" })
        guard case let .choice(_, selected) = row.kind else { return XCTFail("The actual Settings row must select an engine") }
        selected()
        XCTAssertEqual(settings.searchSelection.engine, engine)
        XCTAssertEqual(SettingsContent(store: settings, context: SettingsContext()).sections(.search).flatMap(\.rows).filter(\.isSelected).map(\.id), [row.id])
    }

    func testRetainedSnapshotImportsActualSettingsBeforeAnyNetworkBatch() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        let device = try keys.savedDeviceID()
        do {
            let retained = try PhoneSync(seal: seal, options: .init(folder: folder.appendingPathComponent("journal"),
                                                                   device: .init(id: device, name: "Owned iPhone", model: "iPhone"), transport: server))
            leases.append(Lease(retained))
            try retained.journal.change(.init(collection: SyncCollection.setting, id: SearchEngine.key), ["value": "custom"])
            try retained.journal.change(.init(collection: SyncCollection.setting, id: SearchEngine.customKey), ["value": .string(site.template)])
        }
        let made = app(); let bridge = try await attach(made, server, seal)
        try await require { self.settings.searchSelection.customTemplate == self.site.template }
        XCTAssertEqual(settings.searchSelection.engine, .custom)
        XCTAssertEqual(bridge.engine?.settings()[SearchEngine.customKey]?.string, site.template)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.searchEngine), "Import must remain read-only and account-bound")
        bridge.end(); XCTAssertEqual(settings.searchSelection.engine, .google)
        XCTAssertNil(settings.searchSelection.requested)
    }

    func testEncryptedPartialBatchRemovalAndAccountEndReadTheMergedJournal() async throws {
        let server = SyncMemoryServer(), seal = Seal.make(), made = app()
        let writer = try await mac(server, seal)
        try write(writer, SearchEngine.key, "custom"); try write(writer, SearchEngine.customKey, site.template)
        let bridge = try await attach(made, server, seal)
        try await require { self.settings.searchSelection.engine == .custom }
        let changed = site.template + "&source=second"
        try write(writer, SearchEngine.customKey, changed)
        try await require { self.settings.searchSelection.customTemplate == changed }
        XCTAssertEqual(settings.searchSelection.requested, "custom", "A custom-only batch must retain the merged engine")
        try writer.journal.remove(.init(collection: SyncCollection.setting, id: SearchEngine.customKey)); writer.client.kick()
        try await require { self.settings.searchSelection.customTemplate.isEmpty }
        XCTAssertEqual(settings.searchSelection.engine, .google); XCTAssertNotNil(settings.searchSelection.fallbackNote)
        try write(writer, SearchEngine.key, "brave")
        try await require { self.settings.searchSelection.engine == .brave }
        try writer.journal.remove(.init(collection: SyncCollection.setting, id: SearchEngine.key)); writer.client.kick()
        try await require { self.settings.searchSelection.requested == nil }
        try write(writer, SearchEngine.key, "ecosia")
        try await require { self.settings.searchSelection.engine == .ecosia }
        bridge.end(); XCTAssertEqual(settings.searchSelection.engine, .google); XCTAssertNil(settings.searchSelection.requested)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.searchEngine))
        XCTAssertTrue(writer.journal.living(SyncCollection.setting).allSatisfy { $0.stamps.values.allSatisfy { $0.device != bridge.setup?.keys.deviceID } }, "No settings record is written by the iPhone")
    }

    func testRealSettingsChoiceSurvivesFurtherMacImportAndAccountEnd() async throws {
        let server = SyncMemoryServer(), seal = Seal.make(), made = app()
        let writer = try await mac(server, seal); try write(writer, SearchEngine.key, "brave")
        let bridge = try await attach(made, server, seal)
        try await require { self.settings.searchSelection.engine == .brave }
        try choose(.bing); try write(writer, SearchEngine.key, "qwant")
        try await require { bridge.engine?.settings()[SearchEngine.key]?.string == "qwant" }
        XCTAssertEqual(settings.searchSelection.engine, .bing)
        bridge.end(); XCTAssertEqual(settings.searchSelection.engine, .bing)
        XCTAssertEqual(SettingsStore(defaults: defaults).searchSelection.engine, .bing)
    }

    func testActualPublicSettingsSelectionAndFieldSearchReachTheNativeHTTPPage() async throws { try await fieldSearch(privateMode: false) }
    func testActualPrivateSettingsSelectionAndFieldSearchUseASeparateNativeCookieJar() async throws { try await fieldSearch(privateMode: true) }
    private func fieldSearch(privateMode: Bool) async throws {
        let server = SyncMemoryServer(), seal = Seal.make(), made = app()
        let writer = try await mac(server, seal)
        try write(writer, SearchEngine.key, "google"); try write(writer, SearchEngine.customKey, site.template)
        let bridge = try await attach(made, server, seal)
        try await require { self.settings.searchEngines.contains(.custom) }
        try choose(.custom)
        let original = PageFixtures.liveTab(for: site.url("/source"), id: "owned-public-source")
        made.browser.open(original)
        let publicView = made.pages.activate(original); show(publicView)
        try await require({ made.pages.painted.contains(original.id) && !publicView.isLoading }, "The public source must finish its actual HTTP load")
        _ = try await publicView.evaluateJavaScript("document.cookie='public-only=owned;path=/'")
        let query = "café+tea & two/?"
        made.surfaces.openField(.newTab); made.field.setPrivate(privateMode); made.field.put(query)
        let search = try XCTUnwrap(made.fieldRows.first { $0.action == .search })
        XCTAssertTrue(search.subtitle.contains("127.0.0.1"))
        made.choose(search)
        XCTAssertNil(made.surfaces.field)
        let result = try XCTUnwrap(made.browser.tab)
        XCTAssertEqual(result.isPrivate, privateMode)
        let view = made.pages.activate(result); show(view)
        let expected = try XCTUnwrap(settings.searchSelection.url(for: query))
        try await require({ view.url == expected && made.pages.painted.contains(result.id) && !view.isLoading }, "The real field must load its selected URL")
        let actual = try XCTUnwrap(site.requests.last { $0.target.hasPrefix("/find?") })
        XCTAssertEqual(actual.target, "/find?q=caf%C3%A9%2Btea%20%26%20two%2F%3F&literal=YABSEARCHWORDS&encoded=a%2Bb")
        let renderedQuery = try await view.evaluateJavaScript("document.getElementById('query').textContent") as? String
        let renderedLiteral = try await view.evaluateJavaScript("document.getElementById('literal').textContent") as? String
        XCTAssertEqual(renderedQuery, query); XCTAssertEqual(renderedLiteral, "YABSEARCHWORDS")
        if privateMode {
            XCTAssertFalse(actual.header.contains("public-only=owned"))
            XCTAssertFalse(view.configuration.websiteDataStore === publicView.configuration.websiteDataStore)
            XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
            XCTAssertEqual(made.field.newTabWords, "")
        } else { XCTAssertTrue(actual.header.contains("public-only=owned")) }
        XCTAssertEqual(made.pages.front, result.id); XCTAssertEqual(result.navigationURL, expected)
        let shot = XCTAttachment(image: window.asImage()); shot.name = privateMode ? "Private selected-engine actual HTTP page" : "Public selected-engine actual HTTP page"; shot.lifetime = .keepAlways; add(shot)
        bridge.end()
    }
    private func show(_ view: WKWebView) {
        let host = window.rootViewController!.view!
        host.subviews.forEach { $0.removeFromSuperview() }; view.frame = host.bounds; view.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        host.addSubview(view); window.layoutIfNeeded()
    }
}

private extension UIWindow {
    func asImage() -> UIImage { UIGraphicsImageRenderer(bounds: bounds).image { _ in _ = drawHierarchy(in: bounds, afterScreenUpdates: true) } }
}

private final class SearchTestSite: @unchecked Sendable {
    struct Request { let target: String; let header: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "owned.search.site")
    private var connections: [ObjectIdentifier:NWConnection] = [:]
    private var ready: ((Result<Void,Error>) -> Void)?
    private var stopped = false
    private var received: [Request] = []
    var requests: [Request] { queue.sync { received } }
    var port: UInt16 { listener.port!.rawValue }
    var template: String { "http://127.0.0.1:\(port)/find?q=%s&literal=YABSEARCHWORDS&encoded=a%2Bb" }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    init() throws {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(_ callback: @escaping (Result<Void,Error>) -> Void) {
        queue.async {
            self.ready = callback
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let done = self.ready else { return }
                switch state {
                case .ready: self.ready = nil; done(.success(()))
                case let .failed(error): self.ready = nil; done(.failure(error))
                case .cancelled: self.ready = nil; done(.failure(NSError(domain: "OwnedSearchSite", code: 1)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection; connection.start(queue: self.queue); self.receive(connection, Data())
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now()+5) { [weak self] in
                guard let self, let done = self.ready else { return }; self.ready = nil; self.listener.cancel(); done(.failure(NSError(domain: "OwnedSearchSite", code: 2)))
            }
        }
    }
    func stop() { queue.sync { stopped = true; listener.cancel(); connections.values.forEach { $0.cancel() }; connections = [:] } }
    private func close(_ connection: NWConnection) { connections.removeValue(forKey: ObjectIdentifier(connection)); connection.cancel() }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous; if let chunk { bytes.append(chunk) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if ended { self.close(connection) } else { self.receive(connection, bytes) }; return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/"
            self.received.append(Request(target: target, header: header))
            let url = URL(string: "http://127.0.0.1\(target)")!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            func html(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
            let body = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><link rel=icon href=data:,><title>Owned actual search</title><style>body{font:20px system-ui;padding:70px 20px;background:#c4f5ef}</style><h1>Actual selected-engine HTTP page</h1><output id=query>\(html(query))</output><p id=literal>YABSEARCHWORDS</p>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }
}
