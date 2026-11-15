import Network
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Owned callback pages exercise WebKit's opener, message and close delegates.
@MainActor
final class PopupReturnTests: XCTestCase {
    private var site: PopupReturnSite!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var apps: [AppModel] = []
    private var previousMotion = false

    override func setUp() async throws {
        previousMotion = Motion.disabled
        Motion.disabled = true
        site = try PopupReturnSite()
        try await site.start()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        for app in apps {
            app.pages.suspendPageDialogs()
            for tab in app.browser.allTabs { app.pages.forget(tab.id) }
        }
        apps = []
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        previousKey?.makeKey()
        site?.stop()
        site = nil
        Motion.disabled = previousMotion
    }

    private func makeApp() -> AppModel {
        let ordinary = Space(id: "public", name: "Public", emoji: "", tint: RGB(238, 233, 226))
        let privateSpace = Space(id: "private", name: "Private", emoji: "", tint: RGB(0, 0, 0), isPrivate: true)
        let world = World(name: "owned popup callbacks", space: ordinary.id,
                          spaces: [privateSpace, ordinary], mac: .init(joined: false))
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        apps.append(app)
        return app
    }

    private func show(_ view: WKWebView) {
        let host = window.rootViewController!.view!
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        window.layoutIfNeeded()
    }

    private func require(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                         details: (() -> String)? = nil, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = apps.map { app in
            "selected=\(app.browser.tab?.id ?? "none"), live=\(app.browser.allTabs.filter { app.pages.isLive($0.id) }.map(\.id)), tabs=\(app.browser.allTabs.map(\.id))"
        }.joined(separator: "\n")
        let failure = message + (details.map { " [" + $0() + "]" } ?? "")
        let diagnostic = XCTAttachment(string: state + "\n" + failure)
        diagnostic.name = "Owned popup callback state"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTFail(failure, file: file, line: line)
        throw NSError(domain: "PopupReturnTests", code: 1)
    }

    private func open(_ path: String, in app: AppModel, privately: Bool = false) async throws -> (Tab, WKWebView) {
        let tab = PageFixtures.liveTab(for: site.url(path), id: UUID().uuidString, isPrivate: privately)
        app.browser.open(tab, in: privately ? "private" : "public", deduplicate: false)
        let view = app.pages.activate(tab)
        show(view)
        try await require("Owned source page must load before opening a popup") {
            app.pages.painted.contains(tab.id) && !view.isLoading && view.url == self.site.url(path)
        }
        return (tab, view)
    }

    private func popup(from source: WKWebView, in app: AppModel, startsBlank: Bool = false) async throws -> (Tab, WKWebView) {
        let before = Set(app.browser.allTabs.map(\.id))
        let probe = startsBlank ? PopupCreationProbe(pages: app.pages) : nil
        if let probe { source.uiDelegate = probe }
        defer { source.uiDelegate = app.pages }
        source.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let result = try await source.evaluateJavaScript("openOwnedPopup(\(startsBlank ? "true" : "false")); ({isNull: window.ownedPopup === null, type: typeof window.ownedPopup})") as? [String: Any]
        let details = { "startsBlank=\(startsBlank), JS window.ownedPopup=\(String(describing: result)), delegate=\(probe?.diagnostic ?? "normal WebPool")" }
        try await require("WebKit must create the actual authentication popup", details: details) {
            app.browser.allTabs.contains { !before.contains($0.id) }
        }
        let tab = try XCTUnwrap(app.browser.allTabs.first { !before.contains($0.id) })
        let view = try XCTUnwrap(app.pages.liveView(tab.id))
        _ = app.pages.activate(tab)
        show(view)
        try await require("Owned authentication page must load in WebKit's popup") {
            app.pages.painted.contains(tab.id) && !view.isLoading && view.url == self.site.url("/auth")
        }
        let hasOpener = try await view.evaluateJavaScript("window.opener !== null") as? Bool
        XCTAssertEqual(hasOpener, true, "the popup must retain WebKit's actual opener")
        XCTAssertTrue(view.configuration.websiteDataStore === source.configuration.websiteDataStore)
        return (tab, view)
    }

    private func complete(_ popup: WKWebView, message: Bool = true) async throws {
        _ = try await popup.evaluateJavaScript("completeOwnedOAuth(\(message ? "true" : "false")); true")
    }

    func testOAuthMessageAndCloseReturnToTheOriginalSite() async throws {
        let app = makeApp()
        let (sourceTab, source) = try await open("/source", in: app)
        _ = try await source.evaluateJavaScript("document.cookie='owned-session=public;path=/'; true")
        let (popupTab, popup) = try await popup(from: source, in: app)
        XCTAssertEqual(app.browser.tab?.id, popupTab.id)
        XCTAssertEqual(app.backStack.opener(of: popupTab.id), sourceTab.id)
        try await complete(popup)
        try await require("OAuth window.close must remove its popup and return to its opener") {
            app.browser.tab(popupTab.id) == nil && app.browser.tab?.id == sourceTab.id
        }
        _ = app.pages.activate(try XCTUnwrap(app.browser.tab(sourceTab.id)))
        show(source)
        try await require("The opener must finish its postMessage redirect to the signed-in site") {
            source.url == self.site.url("/signed-in") && !source.isLoading
        }
        XCTAssertTrue(source === app.pages.liveView(sourceTab.id))
        XCTAssertFalse(app.pages.isLive(popupTab.id))
        let cookies = try await source.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(cookies?.contains("owned-session=public") == true)
    }

    func testClosingAnAuthenticationPopupReturnsToTheOriginalTab() async throws {
        let app = makeApp()
        let (sourceTab, source) = try await open("/source", in: app)
        let (popupTab, popup) = try await popup(from: source, in: app)
        try await complete(popup, message: false)
        try await require("OAuth window.close must remove its popup and return to its opener") {
            app.browser.tab(popupTab.id) == nil && app.browser.tab?.id == sourceTab.id
        }
        XCTAssertEqual(source.url, site.url("/source"))
        XCTAssertTrue(source === app.pages.liveView(sourceTab.id))
        XCTAssertFalse(app.pages.isLive(popupTab.id))
    }

    func testInitiallyBlankAuthenticationPopupCanReturnAfterItsCallback() async throws {
        let app = makeApp()
        let (sourceTab, source) = try await open("/source", in: app)
        let (popupTab, popup) = try await popup(from: source, in: app, startsBlank: true)
        try await complete(popup)
        try await require("An initially blank OAuth popup must return to its original opener") {
            app.browser.tab(popupTab.id) == nil && app.browser.tab?.id == sourceTab.id
        }
        _ = app.pages.activate(try XCTUnwrap(app.browser.tab(sourceTab.id)))
        show(source)
        try await require("An initially blank popup must preserve the actual opener message channel") {
            source.url == self.site.url("/signed-in") && !source.isLoading
        }
    }

    func testPrivateCallbackKeepsTheOpenersStoreAndPublicSessionSeparate() async throws {
        let app = makeApp()
        let (publicTab, publicView) = try await open("/source", in: app)
        _ = try await publicView.evaluateJavaScript("document.cookie='owned-session=public;path=/'; true")
        let (sourceTab, source) = try await open("/source", in: app, privately: true)
        _ = try await source.evaluateJavaScript("document.cookie='owned-session=private;path=/'; true")
        let (popupTab, popup) = try await popup(from: source, in: app)
        XCTAssertTrue(popupTab.isPrivate)
        XCTAssertEqual(app.browser.space(holding: popupTab.id)?.id, "private")
        XCTAssertFalse(popup.configuration.websiteDataStore === publicView.configuration.websiteDataStore)
        let popupCookies = try await popup.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(popupCookies?.contains("owned-session=private") == true)
        XCTAssertFalse(popupCookies?.contains("owned-session=public") == true)
        try await complete(popup)
        try await require("A private OAuth callback must return to its private opener") {
            app.browser.tab(popupTab.id) == nil && app.browser.tab?.id == sourceTab.id
        }
        _ = app.pages.activate(try XCTUnwrap(app.browser.tab(sourceTab.id)))
        show(source)
        try await require("The private opener must receive the actual callback message") {
            source.url == self.site.url("/signed-in") && !source.isLoading
        }
        XCTAssertEqual(app.browser.spaceID, "private")
        XCTAssertNotNil(app.browser.tab(publicTab.id))
        let publicCookies = try await publicView.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(publicCookies?.contains("owned-session=public") == true)
        XCTAssertFalse(publicCookies?.contains("owned-session=private") == true)
    }

    func testClosingABackgroundPopupKeepsTheUnrelatedFocusedTab() async throws {
        let app = makeApp()
        let (sourceTab, source) = try await open("/source", in: app)
        let (popupTab, popup) = try await popup(from: source, in: app)
        let (unrelated, unrelatedView) = try await open("/unrelated", in: app)
        try await complete(popup, message: false)
        try await require("A background callback must remove only the popup that closed") {
            app.browser.tab(popupTab.id) == nil
        }
        XCTAssertEqual(app.browser.tab?.id, unrelated.id, "closing a background popup must preserve the user's newer selection")
        XCTAssertTrue(unrelatedView === app.pages.liveView(unrelated.id))
        XCTAssertNotNil(app.browser.tab(sourceTab.id))
        XCTAssertEqual(source.url, site.url("/source"))
    }

    func testAnOrdinaryTabCannotCloseItselfOrAnotherTab() async throws {
        let app = makeApp()
        let (other, _) = try await open("/unrelated", in: app)
        let (ordinary, view) = try await open("/source", in: app)
        _ = try await view.evaluateJavaScript("window.close(); true")
        // WebKit may reject close before calling its delegate. Check the delegate's guard too.
        app.pages.webViewDidClose(view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(app.browser.tab(ordinary.id))
        XCTAssertNotNil(app.browser.tab(other.id))
        XCTAssertEqual(app.browser.tab?.id, ordinary.id)
        XCTAssertTrue(view === app.pages.liveView(ordinary.id))
    }

    func testRetiredPopupCannotCloseTheReplacementViewForItsTab() async throws {
        let app = makeApp()
        let (sourceTab, source) = try await open("/source", in: app)
        let (popupTab, oldPopup) = try await popup(from: source, in: app)
        app.pages.forget(popupTab.id)
        let replacement = app.pages.activate(try XCTUnwrap(app.browser.tab(popupTab.id)))
        show(replacement)
        try await require("The retired popup's tab must load its separate replacement view") {
            app.pages.painted.contains(popupTab.id) && !replacement.isLoading
        }
        XCTAssertFalse(replacement === oldPopup)
        app.pages.webViewDidClose(oldPopup)
        XCTAssertNotNil(app.browser.tab(popupTab.id), "a retired popup callback cannot close the current tab")
        app.pages.webViewDidClose(replacement)
        XCTAssertNotNil(app.browser.tab(popupTab.id), "recreating an ordinary page must not inherit permission to close")
        XCTAssertNotNil(app.browser.tab(sourceTab.id))
        XCTAssertEqual(app.browser.tab?.id, popupTab.id)
        XCTAssertTrue(replacement === app.pages.liveView(popupTab.id))
    }
}

@MainActor
private final class PopupCreationProbe: NSObject, WKUIDelegate {
    private let pages: WebPool
    private var requests: [String] = []

    init(pages: WebPool) {
        self.pages = pages
        super.init()
    }

    var diagnostic: String { "callbackCount=\(requests.count), requests=\(requests)" }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        let description = "requestURL=\(url.map { String(reflecting: $0.absoluteString) } ?? "nil"), empty=\(url?.absoluteString.isEmpty == true), scheme=\(url?.scheme ?? "nil"), allowed=\(url.map { pages.allows($0) } ?? false), targetFrameNil=\(action.targetFrame == nil)"
        let popup = pages.webView(webView, createWebViewWith: configuration, for: action, windowFeatures: windowFeatures)
        requests.append(description + ", returnedPopup=\(popup != nil)")
        return popup
    }
}

private final class PopupReturnSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "owned-oauth-return-http")
    private var ready: CheckedContinuation<Void, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let callback = self.ready else { return }
                switch state {
                case .ready:
                    self.ready = nil
                    self.port = self.listener.port!.rawValue
                    callback.resume()
                case let .failed(error):
                    self.ready = nil
                    callback.resume(throwing: error)
                case .cancelled:
                    self.ready = nil
                    callback.resume(throwing: NSError(domain: "PopupReturnSite", code: 1))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            connections.values.forEach { $0.cancel() }
            connections = [:]
        }
    }

    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous
            if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if done { self.close(connection) } else { self.receive(connection, bytes) }
                return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/source"
            let path = target.components(separatedBy: "?").first ?? target
            let body = self.page(path)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }

    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }

    private func page(_ path: String) -> String {
        let script: String
        switch path {
        case "/source":
            script = """
            function openOwnedPopup(startsBlank) {
              window.ownedPopup = window.open(startsBlank ? '' : '/auth', 'owned-oauth');
              if (startsBlank && window.ownedPopup) window.ownedPopup.location.href = '/auth';
            }
            addEventListener('message', event => {
              if (event.origin === location.origin && event.data === 'owned-oauth-complete') location.href = '/signed-in';
            });
            """
        case "/auth":
            script = """
            function completeOwnedOAuth(message) {
              if (message && window.opener) window.opener.postMessage('owned-oauth-complete', location.origin);
              setTimeout(() => window.close(), 50);
            }
            """
        default: script = ""
        }
        return """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Owned \(path)</title><link rel="icon" href="data:,"><p>Owned \(path)</p><script>\(script)</script>
        """
    }
}
