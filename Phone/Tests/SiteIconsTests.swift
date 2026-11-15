import Network
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import YabPhone

@MainActor
final class SiteIconsTests: XCTestCase {
    private var sites: [IconTestSite] = []
    private var caches: [SiteIcons] = []
    private var stores: Set<UUID> = []

    func testKeptRestoreCoalescesAndNeverReplacesAFetchedIcon() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeptIcons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = try await site()
        let icons = SiteIcons(keptDirectory: folder)
        caches.append(icons)
        let fresh = server.url("/page")
        let loaded = await icons.load(for: fresh)
        XCTAssertTrue(loaded)
        let freshSize = try XCTUnwrap(icons.image(for: fresh)).size
        let old = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
        let key = SiteIcons.origin(of: fresh)!.absoluteString
        try old.write(to: folder.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        let saved = URL(string: "https://saved.invalid")!
        try png().write(to: folder.appendingPathComponent(saved.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        try Data("broken image".utf8).write(to: folder.appendingPathComponent("corrupt"))
        async let first: Void = icons.restoreKept()
        async let second: Void = icons.restoreKept()
        _ = await (first, second)
        XCTAssertEqual(icons.image(for: fresh)?.size, freshSize)
        XCTAssertNotNil(icons.image(for: saved))
        let later = URL(string: "https://later.invalid")!
        try png().write(to: folder.appendingPathComponent(later.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        await icons.restoreKept()
        XCTAssertNil(icons.image(for: later), "profile observation must not rescan the disk cache")
    }

    func testClearDuringKeptRestoreCannotBringIconsBack() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeptIcons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = URL(string: "https://saved.invalid")!
        try png().write(to: folder.appendingPathComponent(url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        let icons = SiteIcons(keptDirectory: folder)
        let began = expectation(description: "restore entered")
        let restore = Task { @MainActor in
            began.fulfill()
            await icons.restoreKept()
        }
        await fulfillment(of: [began], timeout: 5)
        icons.removeAll()
        await restore.value
        XCTAssertNil(icons.image(for: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    override func tearDown() async throws {
        caches.forEach { $0.removeAll() }
        SiteIcons.shared.removeAll()
        sites.forEach { $0.stop() }
        sites = []
        caches = []
        for id in stores { try await WKWebsiteDataStore.remove(forIdentifier: id) }
        stores = []
    }

    func testColdSpaceLoadsItsPublicOriginsWithoutVisitingTabs() async throws {
        let one = try await site()
        let two = try await site()
        let privateSite = try await site()
        let icons = cache()
        let first = tab("synced-pin", one.url("/documents?q=private-in-address"))
        let second = tab("synced-tab", two.url("/unvisited"))
        let secret = tab("secret", privateSite.url("/secret"), isPrivate: true)
        let space = Space(id: "shared-space", name: "Research", emoji: "", tint: RGB(1, 2, 3),
                          pins: [first], today: [first, second, secret])
        await icons.prefetch(space)
        XCTAssertEqual(one.paths, ["/favicon.ico"])
        XCTAssertEqual(two.paths, ["/favicon.ico"])
        XCTAssertTrue(privateSite.paths.isEmpty)
        XCTAssertNotNil(icons.image(for: first.navigationURL!))
        XCTAssertNotNil(icons.image(for: second.navigationURL!))
        XCTAssertNil(icons.image(for: "127.0.0.1"), "two ports must not share a host-only image")
        await icons.prefetch(space)
        XCTAssertEqual(one.paths, ["/favicon.ico"], "successful origins are cached")
        XCTAssertEqual(two.paths, ["/favicon.ico"])
        var privateSpace = space
        privateSpace.isPrivate = true
        let privateOnly = cache()
        await privateOnly.prefetch(privateSpace)
        XCTAssertNil(privateOnly.image(for: first.navigationURL!))
        XCTAssertEqual(one.paths.count, 1)
    }

    func testFailedRootIconCanRetryAndConcurrentLoadsCoalesce() async throws {
        let server = try await site()
        server.set("/favicon.ico", status: 503, body: Data())
        var clock = Date(timeIntervalSince1970: 100)
        let icons = cache(now: { clock })
        let page = server.url("/page")
        let first = await icons.load(for: page)
        XCTAssertFalse(first)
        let immediate = await icons.load(for: page)
        XCTAssertFalse(immediate)
        XCTAssertEqual(server.paths, ["/favicon.ico"])
        // A page's declared icon must not be blocked by a failed cold root.
        server.set("/offered.png", body: png())
        let offered = await icons.load(for: page, declaredIcon: server.url("/offered.png"))
        XCTAssertTrue(offered)
        XCTAssertEqual(server.paths, ["/favicon.ico", "/offered.png"])
        icons.removeAll()
        let failedAgain = await icons.load(for: page)
        XCTAssertFalse(failedAgain)
        server.set("/favicon.ico", body: png())
        clock = clock.addingTimeInterval(31)
        async let a = icons.load(for: page)
        async let b = icons.load(for: page)
        let results = await [a, b]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(server.paths.filter { $0 == "/favicon.ico" }.count, 3)
        XCTAssertNotNil(icons.image(for: page))
    }

    func testOnlySameOriginRedirectsAndDeclaredIconsAreFetchedWithoutCookies() async throws {
        let server = try await site()
        let outside = try await site()
        server.set("/same", status: 302, body: Data(), headers: ["Location": "/icon.png"])
        server.set("/icon.png", body: png(), headers: ["Set-Cookie": "session=must-not-send; Path=/"])
        let icons = cache()
        let own = await icons.load(for: server.url("/page"), declaredIcon: server.url("/same"))
        XCTAssertTrue(own)
        XCTAssertEqual(server.paths, ["/same", "/icon.png"])
        icons.removeAll()
        let again = await icons.load(for: server.url("/page"), declaredIcon: server.url("/same"))
        XCTAssertTrue(again)
        XCTAssertFalse(server.headers.contains { $0.lowercased().contains("\r\ncookie:") || $0.lowercased().contains("\r\nauthorization:") })
        server.set("/cross", status: 302, body: Data(), headers: ["Location": outside.url("/tracker").absoluteString])
        server.set("/favicon.ico", status: 503, body: Data())
        let blocked = cache()
        let redirect = await blocked.load(for: server.url("/page"), declaredIcon: server.url("/cross"))
        XCTAssertFalse(redirect)
        XCTAssertTrue(outside.paths.isEmpty, "a redirect must not contact another origin")
        let external = cache()
        let declared = await external.load(for: server.url("/page"), declaredIcon: outside.url("/tracker"))
        XCTAssertFalse(declared)
        XCTAssertTrue(outside.paths.isEmpty, "a declared external icon must not contact another origin")
    }

    func testPrivateLoadsAndCredentialURLsNeverEnterCacheOrNetwork() async throws {
        let server = try await site()
        let icons = cache()
        let secret = await icons.load(for: server.url("/secret"), isPrivate: true)
        XCTAssertFalse(secret)
        var url = URLComponents(url: server.url("/page"), resolvingAgainstBaseURL: false)!
        url.user = "user"
        url.password = "not-a-real-secret"
        let credential = await icons.load(for: url.url!)
        XCTAssertFalse(credential)
        XCTAssertTrue(server.paths.isEmpty)
        XCTAssertNil(icons.image(for: server.url("/secret")))
        XCTAssertEqual(SiteIcons.origin(of: URL(string: "https://EXAMPLE.com:443/a?q=x#part")!), URL(string: "https://example.com"))
        XCTAssertNotEqual(SiteIcons.origin(of: URL(string: "http://example.com/a")!), SiteIcons.origin(of: URL(string: "https://example.com/a")!))
        XCTAssertNil(SiteIcons.origin(of: URL(string: "file:///favicon.png")!))
    }

    func testAppSpaceEntryHydratesColdSyncedRowsWithoutCreatingWebViews() async throws {
        let current = try await site()
        let entering = try await site()
        let privateSite = try await site()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SiteIconsTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder)
        let identity: UUID? = profile.dataStoreID
        if let id = identity { stores.insert(id) }
        // No lock on Private: with it, entering Private below asks the
        // device's own Face ID, whose system sheet (on a simulator with a
        // face enrolled by TasksTests) leaves the app inactive for every
        // test after this one. Private is entered for real instead.
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        let first = tab("first-space", current.url("/not-visited"))
        let second = tab("cold-synced", entering.url("/not-visited"))
        app.browser.adopt([
            Space(id: "first", name: "Personal", emoji: "", tint: RGB(1, 2, 3), today: [first]),
            Space(id: "second", name: "Synced work", emoji: "", tint: RGB(1, 2, 3), pins: [second]),
            Space(id: "private", name: "Private", emoji: "", tint: RGB(0, 0, 0), today: [tab("secret", privateSite.url("/secret"))], isPrivate: true)
        ])
        app.browser.showSpace("first")
        try await eventually { SiteIcons.shared.image(for: first.navigationURL!) != nil }
        XCTAssertTrue(entering.paths.isEmpty, "an unentered space stays cold")
        // The cold space's pin as the spaces draw it (Favicon), its pixels
        // waiting for the space to be entered.
        let host = UIHostingController(rootView: Favicon(icon: second.icon, host: second.addressHost, size: 44, url: second.navigationURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity).environment(app))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKey = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = host
        host.view.backgroundColor = AppearanceColors.ui(0xFFFFFF, 0x121214)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        let before = recordColumn(window, name: "Synced work cold icons")
        app.browser.showSpace("second")
        try await eventually { SiteIcons.shared.image(for: second.navigationURL!) != nil }
        // Give SwiftUI's observation invalidation a layout pass after download.
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        let after = recordColumn(window, name: "Synced work hydrated icons")
        XCTAssertNotEqual(before.pngData(), after.pngData(), "hydration must update the drawn pin's pixels")
        XCTAssertEqual(entering.paths, ["/favicon.ico"])
        XCTAssertFalse(app.pages.isLive(first.id))
        XCTAssertFalse(app.pages.isLive(second.id))
        app.browser.showSpace("private")
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(privateSite.paths.isEmpty)
        await app.flushProfile()
    }

    func testDeclaredIconsParseUnquotedAttributesAndExactRelTokens() {
        let page = URL(string: "https://www.example.test/docs/index.html")!
        let html = """
        <link data-href="/wrong.png" rel="icon" href="/right.png">
        <link rel=apple-touch-icon href=../touch.png>
        <link rel="mask-icon" href="/mask.png">
        <link rel="icon" type="image/svg+xml" href="/vector">
        <link rel="icon" href="/mark.SVG?v=2">
        <link rel="shortcut icon" href="/right.png">
        <link rel="icon" href="https://user:secret@cdn.example.test/icon.png">
        <link rel="icon" href="https://cdn.example.test/icon.png?a=1&amp;b=2">
        """
        XCTAssertEqual(SiteIcons.declaredIcons(in: html, page: page).map(\.absoluteString), [
            "https://www.example.test/touch.png", "https://www.example.test/right.png",
            "https://cdn.example.test/icon.png?a=1&b=2"
        ])
    }

    /// The same persistent WebKit page a favorite visits: SVG first, broken
    /// touch icon second, usable PNG third, and no root favicon.
    func testPageWithSVGFirstLoadsItsRasterFavorite() async throws {
        let server = try await site()
        server.set("/favicon.ico", status: 404, body: Data())
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width">
        <link rel="icon" type="image/svg+xml" href="/first.svg">
        <link rel="apple-touch-icon" href="/missing.png">
        <link rel="icon" href="/favorite.png"><title>Favorite fixture</title>
        """
        server.set("/page", body: Data(html.utf8), headers: ["Content-Type": "text/html"])
        server.set("/first.svg", body: Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8))
        server.set("/favorite.png", body: png())
        let configuration = WKWebViewConfiguration()
        let storeID = UUID(); stores.insert(storeID)
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: configuration)
        let address = server.url("/page")
        page.load(URLRequest(url: address))
        try await eventually { page.url == address && !page.isLoading }
        let fixture = tab("favorite-svg-first", address)
        let app = AppModel(world: try World.load(named: "mira"))
        app.browser.adopt([Space(id: "favorites", name: "Favorites", emoji: "", tint: RGB(218, 229, 246), pins: [fixture])])
        app.browser.showSpace("favorites")
        let state = try XCTUnwrap(StateCatalog.named("spaces.full"))
        await state.apply(app)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = RootController(app: app)
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(400))
        SiteIcons.shared.read(from: page)
        // Keep a native screenshot even on BASE, where the icon never arrives.
        let deadline = Date().addingTimeInterval(8)
        while SiteIcons.shared.image(for: address) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        _ = recordColumn(window, name: "Favorite SVG first - light")
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(300))
        _ = recordColumn(window, name: "Favorite SVG first - dark")
        XCTAssertNotNil(SiteIcons.shared.image(for: address), "a page's unsupported first SVG must not hide its later PNG")
        XCTAssertTrue(server.paths.contains("/favorite.png"))
        XCTAssertFalse(server.paths.contains("/first.svg"), "unsupported SVG is skipped before fetching")
        XCTAssertFalse(server.headers.contains { $0.lowercased().contains("\r\ncookie:") || $0.lowercased().contains("\r\nauthorization:") })
    }

    private func cache(now: @escaping () -> Date = Date.init) -> SiteIcons {
        let icons = SiteIcons(now: now)
        caches.append(icons)
        return icons
    }

    private func site() async throws -> IconTestSite {
        let value = try IconTestSite(image: png())
        sites.append(value)
        try await value.start()
        return value
    }

    private func tab(_ id: String, _ url: URL, isPrivate: Bool = false) -> YabPhone.Tab {
        PageFixtures.liveTab(for: url, id: id, isPrivate: isPrivate)
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func recordColumn(_ window: UIWindow, name: String) -> UIImage {
        var rendered = false
        let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "the native column hierarchy must render before attaching evidence")
        let attachment = XCTAttachment(image: picture)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return picture
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "public space icon did not load", file: file, line: line)
    }
}

/// A disposable, loopback-only HTTP fixture. All mutable listener state stays
/// on its own queue; no browser page or independent dev server is started.
private final class IconTestSite: @unchecked Sendable {
    private struct Response { var status: Int; var body: Data; var headers: [String: String] }
    private let queue = DispatchQueue(label: "yab.tests.icons")
    private let listener: NWListener
    private var replies: [String: Response]
    private var receivedPaths: [String] = []
    private var receivedHeaders: [String] = []
    private var waiter: CheckedContinuation<Void, Error>?
    private var port: UInt16 = 0
    var paths: [String] { queue.sync { receivedPaths } }
    var headers: [String] { queue.sync { receivedHeaders } }

    init(image: Data) throws {
        replies = ["/favicon.ico": Response(status: 200, body: image, headers: [:])]
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let pending = self.waiter else { return }
                switch state {
                case .ready:
                    self.waiter = nil
                    self.port = self.listener.port!.rawValue
                    pending.resume()
                case let .failed(error):
                    self.waiter = nil
                    pending.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let pending = self.waiter else { return }
                self.waiter = nil
                self.listener.cancel()
                pending.resume(throwing: NSError(domain: "SiteIconsTests.Listener", code: 1))
            }
        }
    }

    func stop() { listener.cancel() }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func set(_ path: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        queue.sync { replies[path] = Response(status: status, body: body, headers: headers) }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = data
            if let chunk { request.append(chunk) }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                let path = text.components(separatedBy: " ").dropFirst().first ?? "/"
                self.receivedPaths.append(path)
                self.receivedHeaders.append(text)
                let response = self.replies[path] ?? Response(status: 404, body: Data(), headers: [:])
                let contentType = response.headers["Content-Type"] ?? "image/png"
                var head = "HTTP/1.1 \(response.status) Fixture\r\nContent-Type: \(contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
                for (key, value) in response.headers where key != "Content-Type" { head += "\(key): \(value)\r\n" }
                var bytes = Data((head + "\r\n").utf8)
                bytes.append(response.body)
                connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
            } else if !done, request.count < 32_768 {
                self.receive(connection, data: request)
            } else { connection.cancel() }
        }
    }
}
