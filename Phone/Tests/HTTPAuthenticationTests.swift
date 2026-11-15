import Network
import CryptoKit
import UIKit
import WebKit
import XCTest
@testable import YabPhone

@MainActor
final class HTTPAuthenticationTests: XCTestCase {
    private var site: HTTPAuthenticationSite!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var pools: [WebPool] = []
    private var tabs: [YabPhone.Tab] = []
    private var oldMotion = false

    override func setUp() async throws {
        oldMotion = Motion.disabled; Motion.disabled = true
        site = try HTTPAuthenticationSite()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in site.start { done.resume(with: $0) } }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
    }
    override func tearDown() async throws {
        defer { Motion.disabled = oldMotion }
        for pages in pools { pages.suspendPageDialogs(); for tab in tabs { pages.forget(tab.id) } }
        pools = []; tabs = []; window.rootViewController = nil; window.isHidden = true; window = nil
        previousKey?.makeKey(); site.stop(); site = nil
    }
    private func start(_ privateMode: Bool = false, path: String = "/auth") -> (WebPool, YabPhone.Tab, WKWebView) {
        let pages = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false); pools.append(pages)
        let tab = PageFixtures.liveTab(for: site.url(path), id: UUID().uuidString, isPrivate: privateMode); tabs.append(tab)
        let view = pages.activate(tab), host = window.rootViewController!.view!
        host.subviews.forEach { $0.removeFromSuperview() }; view.frame = host.bounds
        host.addSubview(view); window.layoutIfNeeded(); return (pages, tab, view)
    }
    private func until(_ phase: String = "auth state", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while Date() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        let receipt = pools.enumerated().map { offset, pages -> [String: Any] in
            let view = window.rootViewController?.view.subviews.compactMap { $0 as? WKWebView }.first
            return ["pool":offset, "authenticationPresent":pages.httpAuthentication != nil,
                    "frontPresent":pages.front != nil, "liveViewPresent":view != nil,
                    "viewLoading":view?.isLoading == true, "keyWindow":view?.window?.isKeyWindow == true,
                    "sceneActive":view?.window?.windowScene?.activationState == .foregroundActive,
                    "nativeModalPresent":window.rootViewController?.presentedViewController != nil,
                    "applicationActive":UIApplication.shared.applicationState == .active,
                    "ownPageTitle":view?.title == "Owned page", "authorizedPageTitle":view?.title == "Authenticated owned page"]
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["phase":phase, "pools":receipt,
            "authorizedResponses":site.authorizedCount, "rejectedCredentialRequests":site.rejectedCount]), uniformTypeIdentifier: "public.json")
        attachment.name = "Owned HTTP phase state"; attachment.lifetime = .keepAlways; add(attachment)
        XCTFail("Actual native authentication state did not arrive: " + phase, file: file, line: line)
        throw NSError(domain: "HTTPAuthenticationTests", code: 1)
    }

    /// The answer reaches WebKit once the sign-in alert is gone
    /// (PageHTTPAuthentication.resolve), and until then WebKit folds a new
    /// challenge for the same site into the pending one and cancels it with
    /// it, unseen. A person can't load a page in that fifth of a second; a
    /// test waits for the alert to go before its next protected load.
    private var alertGone: Bool { window.rootViewController?.presentedViewController == nil }

    func testActualCancelShowsCapturedRetryWithoutCommittingUnauthorizedPage() async throws {
        for privateMode in [false, true] {
            let before = site.authorizedCount
            let (pages, tab, view) = start(privateMode, path: "/page"), store = view.configuration.websiteDataStore
            var exported: [BrowserNavigation] = []
            pages.onNavigation = { _, state in exported.append(state) }
            try await until("actual source before Cancel") { pages.painted.contains(tab.id) && view.title == "Owned page" }
            let source = try XCTUnwrap(pages.navigationState(for: tab.id))
            let _: Any = try await view.evaluateJavaScript("document.querySelector('a').click();true")
            try await until("actual link challenge before Cancel") { pages.httpAuthentication != nil }
            let captured = try XCTUnwrap(pages.httpAuthentication)
            pages.answerHTTPAuthentication(captured.id, user: nil, password: nil)
            try await until("actual cancelled error and dismissed native alert") {
                pages.state(for: tab.id).failure?.kind == .authentication && !view.isLoading
                    && self.window.rootViewController?.presentedViewController == nil
            }
            let failure = try XCTUnwrap(pages.state(for: tab.id).failure)
            XCTAssertEqual(failure.url, site.url("/auth")); XCTAssertEqual(failure.previousURL, site.url("/page"))
            XCTAssertEqual(failure.explanation, "Website sign-in was cancelled. Try again to sign in or go back.")
            XCTAssertTrue(pages.state(for: tab.id).canGoBack); XCTAssertFalse(pages.painted.contains(tab.id))
            XCTAssertEqual(site.authorizedCount, before); XCTAssertEqual(pages.front, tab.id)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), source.entries.map(\.url))
            XCTAssertEqual(pages.navigationState(for: tab.id)?.index, source.index)
            XCTAssertTrue(pages.retryFailure(tab.id, expected: failure.id))
            XCTAssertFalse(pages.retryFailure(tab.id, expected: failure.id))
            try await until("actual Retry requests a fresh native challenge") { pages.httpAuthentication != nil }
            let fresh = try XCTUnwrap(pages.httpAuthentication)
            XCTAssertNotEqual(fresh.id, captured.id)
            pages.answerHTTPAuthentication(captured.id, user: "owned", password: "fixture")
            XCTAssertTrue(pages.httpAuthentication === fresh); XCTAssertEqual(site.authorizedCount, before)
            pages.answerHTTPAuthentication(fresh.id, user: "owned", password: "fixture")
            try await until("real authenticated response after captured Retry") {
                pages.painted.contains(tab.id) && view.title == "Authenticated owned page" && !view.isLoading
            }
            XCTAssertNil(pages.state(for: tab.id).failure); XCTAssertEqual(site.authorizedCount, before + 1)
            XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), [site.url("/page").absoluteString, site.url("/auth").absoluteString])
            XCTAssertEqual(pages.navigationState(for: tab.id)?.index, 1)
            let document = try await view.evaluateJavaScript("document.URL") as? String
            XCTAssertEqual(document, site.url("/auth").absoluteString)
            let _: Any = try await view.evaluateJavaScript("document.getElementById('result').click();true")
            let result = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
            XCTAssertEqual(result, "Page touched")
            if privateMode { XCTAssertFalse(store.isPersistent); XCTAssertTrue(exported.isEmpty) }
            let returned = await pages.back(tab.id); XCTAssertTrue(returned)
            try await until("actual previous source after authenticated Back") { pages.painted.contains(tab.id) && view.title == "Owned page" }
            XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), [site.url("/page").absoluteString, site.url("/auth").absoluteString])
            XCTAssertEqual(pages.navigationState(for: tab.id)?.index, 0)
            pages.forget(tab.id)
        }
    }

    func testCancelBackAndRetiredFailureCannotEscapePrivateOrPageOwnership() async throws {
        for privateMode in [false, true] {
            let (pages, tab, view) = start(privateMode, path: "/page"), store = view.configuration.websiteDataStore
            try await until("real source for cancelled Back") { pages.painted.contains(tab.id) && view.title == "Owned page" }
            let _: Any = try await view.evaluateJavaScript("document.querySelector('a').click();true")
            try await until("actual pending challenge for Back") { pages.httpAuthentication != nil }
            let captured = try XCTUnwrap(pages.httpAuthentication)
            pages.answerHTTPAuthentication(captured.id, user: nil, password: nil)
            try await until("retained Cancel failure before Back") { pages.state(for: tab.id).failure != nil && !view.isLoading && self.alertGone }
            let failure = try XCTUnwrap(pages.state(for: tab.id).failure)
            let returned = await pages.backFailure(tab.id, expected: failure.id); XCTAssertTrue(returned)
            try await until("actual source or source reload after Cancel Back") { pages.painted.contains(tab.id) && view.title == "Owned page" }
            let document = try await view.evaluateJavaScript("document.URL") as? String
            XCTAssertEqual(document, site.url("/page").absoluteString)
            XCTAssertNil(pages.state(for: tab.id).failure)
            XCTAssertFalse(pages.retryFailure(tab.id, expected: failure.id))
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), [site.url("/page").absoluteString])
            let _: Any = try await view.evaluateJavaScript("document.getElementById('result').click();true")
            let result = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
            XCTAssertEqual(result, "Page touched")
            pages.load(tab.id, site.url("/auth?covered=1"))
            try await until("real pending challenge before page cover") { pages.httpAuthentication != nil }
            let covered = try XCTUnwrap(pages.httpAuthentication)
            pages.setPageInteractionsEnabled(false)
            pages.answerHTTPAuthentication(covered.id, user: nil, password: nil)
            try await until("retired covered challenge has no visible Cancel error") { !view.isLoading && self.alertGone }
            XCTAssertNil(pages.httpAuthentication); XCTAssertNil(pages.state(for: tab.id).failure)
            XCTAssertEqual(site.authorizedCount, 0)
            pages.setPageInteractionsEnabled(true)
            pages.forget(tab.id)
            XCTAssertFalse(pages.retryFailure(tab.id, expected: failure.id)); XCTAssertFalse(pages.isLive(tab.id))
        }
    }

    func testActualHTTPChallengeUsesNativeSecureFieldsAndReachesTheSamePublicOrPrivatePage() async throws {
        for privateMode in [false, true] {
            let (pages, tab, view) = start(privateMode), store = view.configuration.websiteDataStore
            try await until { pages.httpAuthentication != nil }
            let authentication = try XCTUnwrap(pages.httpAuthentication)
            XCTAssertTrue(authentication.controller === window.rootViewController?.presentedViewController)
            XCTAssertEqual(authentication.controller.title, "Sign In to 127.0.0.1:\(site.port)")
            XCTAssertTrue(authentication.controller.textFields?.last?.isSecureTextEntry == true)
            XCTAssertEqual(authentication.controller.textFields?.last?.textContentType, .password)
            pages.answerHTTPAuthentication(authentication.id, user: "owned", password: "fixture")
            try await until { pages.painted.contains(tab.id) && view.title == "Authenticated owned page" }
            XCTAssertEqual(view.url, site.url("/auth")); XCTAssertEqual(pages.front, tab.id)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertNil(pages.httpAuthentication)
            let result = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
            XCTAssertEqual(result, "actual authorized response")
            XCTAssertTrue(site.authorizedCount >= 1)
            if privateMode { XCTAssertFalse(store.isPersistent) }
            pages.forget(tab.id)
        }
    }

    func testActualCancelDoesNotSendCredentialsAndNextFreshChallengeCanBeAnswered() async throws {
        let (pages, tab, view) = start()
        try await until { pages.httpAuthentication != nil }
        let old = try XCTUnwrap(pages.httpAuthentication)
        pages.answerHTTPAuthentication(old.id, user: nil, password: nil)
        try await until { pages.httpAuthentication == nil && !view.isLoading && self.alertGone }
        XCTAssertEqual(site.authorizedCount, 0)
        pages.load(tab.id, site.url("/auth?retry=1"))
        try await until { pages.httpAuthentication != nil }
        let fresh = try XCTUnwrap(pages.httpAuthentication)
        XCTAssertNotEqual(fresh.id, old.id)
        pages.answerHTTPAuthentication(old.id, user: "owned", password: "fixture")
        XCTAssertTrue(pages.httpAuthentication === fresh)
        XCTAssertEqual(site.authorizedCount, 0)
        pages.answerHTTPAuthentication(fresh.id, user: "owned", password: "fixture")
        try await until { view.title == "Authenticated owned page" && !view.isLoading }
    }

    func testSelectionAndBackgroundPageCancelTheCapturedAuthentication() async throws {
        let (pages, first, view) = start()
        try await until { pages.httpAuthentication != nil }
        let old = try XCTUnwrap(pages.httpAuthentication)
        let other = PageFixtures.liveTab(for: site.url("/page"), id: "auth.other"); tabs.append(other)
        let next = pages.activate(other); window.rootViewController!.view.addSubview(next)
        try await until { pages.painted.contains(other.id) }
        XCTAssertNil(pages.httpAuthentication)
        pages.answerHTTPAuthentication(old.id, user: "owned", password: "fixture")
        pages.load(first.id, site.url("/auth?background=1"))
        try await until { !view.isLoading }
        XCTAssertNil(pages.httpAuthentication); XCTAssertEqual(site.authorizedCount, 0)
        XCTAssertEqual(pages.front, other.id)
    }

    func testPrivateCoverAndRenewalNeverReviveAnOldCredentialReply() async throws {
        let (pages, tab, view) = start(true)
        try await until { pages.httpAuthentication != nil }
        let old = try XCTUnwrap(pages.httpAuthentication), store = view.configuration.websiteDataStore
        pages.setPageInteractionsEnabled(false); pages.setPageInteractionsEnabled(true)
        pages.answerHTTPAuthentication(old.id, user: "owned", password: "fixture")
        XCTAssertNil(pages.httpAuthentication); XCTAssertEqual(site.authorizedCount, 0)
        try await until { !view.isLoading }
        pages.load(tab.id, site.url("/auth?renew=1"))
        try await until { pages.httpAuthentication != nil }
        let renewed = try XCTUnwrap(pages.httpAuthentication)
        pages.renewPrivateStore()
        pages.answerHTTPAuthentication(renewed.id, user: "owned", password: "fixture")
        XCTAssertNil(pages.httpAuthentication); XCTAssertEqual(site.authorizedCount, 0)
        XCTAssertFalse(pages.privateStore === store)
    }

    func testNavigationCloseAndInactiveSceneResolvePendingChallengeWithoutLateReply() async throws {
        let (pages, tab, view) = start()
        try await until("initial challenge") { pages.httpAuthentication != nil }
        let old = try XCTUnwrap(pages.httpAuthentication)
        pages.load(tab.id, site.url("/page"))
        try await until("real unprotected page after pending navigation") { pages.painted.contains(tab.id) && view.title == "Owned page" && self.alertGone }
        pages.answerHTTPAuthentication(old.id, user: "owned", password: "fixture")
        XCTAssertNil(pages.httpAuthentication); XCTAssertEqual(view.url, site.url("/page"))
        pages.load(tab.id, site.url("/auth?inactive=1"))
        try await until("fresh challenge before inactive notification") { pages.httpAuthentication != nil }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(pages.httpAuthentication)
        try await until("actual canceled navigation after inactive notification") { !view.isLoading && self.alertGone }
        pages.load(tab.id, site.url("/auth?close=1"))
        try await until("fresh challenge before close") { pages.httpAuthentication != nil }
        pages.forget(tab.id)
        XCTAssertNil(pages.httpAuthentication); XCTAssertFalse(pages.isLive(tab.id)); XCTAssertEqual(site.authorizedCount, 0)
    }

    func testActualDigestChallengeChecksResponseAndReachesSamePublicAndPrivateDocument() async throws {
        for privateMode in [false, true] {
            let before = site.digestAuthorizedCount
            let (pages, tab, view) = start(privateMode, path: "/digest"), store = view.configuration.websiteDataStore
            try await until("actual Digest challenge") { pages.httpAuthentication != nil }
            let captured = try XCTUnwrap(pages.httpAuthentication)
            XCTAssertTrue(captured.controller.textFields?.last?.isSecureTextEntry == true)
            pages.answerHTTPAuthentication(captured.id, user: "owned", password: "fixture")
            try await until("actual server-verified Digest document") { pages.painted.contains(tab.id) && view.title == "Authenticated owned page" }
            XCTAssertEqual(view.url, site.url("/digest")); XCTAssertEqual(pages.front, tab.id)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertNil(pages.httpAuthentication); XCTAssertEqual(site.digestAuthorizedCount, before + 1)
            let result = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
            XCTAssertEqual(result, "actual authorized response")
            if privateMode { XCTAssertFalse(store.isPersistent) }
            pages.forget(tab.id)
        }
    }

    func testActualWrongPasswordRepromptsAndOnlyNewReplyAuthenticates() async throws {
        let (pages, tab, view) = start(path: "/auth?wrong=1")
        try await until("initial wrong-password challenge") { pages.httpAuthentication != nil }
        let old = try XCTUnwrap(pages.httpAuthentication)
        pages.answerHTTPAuthentication(old.id, user: "owned", password: "incorrect-owned-password")
        try await until("real server rejection and fresh credential challenge") { pages.httpAuthentication != nil }
        let retry = try XCTUnwrap(pages.httpAuthentication)
        XCTAssertNotEqual(retry.id, old.id); XCTAssertGreaterThan(site.rejectedCount, 0)
        XCTAssertEqual(site.authorizedCount, 0); XCTAssertFalse(pages.painted.contains(tab.id))
        pages.answerHTTPAuthentication(old.id, user: "owned", password: "fixture")
        XCTAssertTrue(pages.httpAuthentication === retry); XCTAssertEqual(site.authorizedCount, 0)
        pages.answerHTTPAuthentication(retry.id, user: "owned", password: "fixture")
        try await until("actual correct response after password retry") { view.title == "Authenticated owned page" && pages.painted.contains(tab.id) }
        XCTAssertEqual(site.authorizedCount, 1); XCTAssertEqual(pages.front, tab.id)
        XCTAssertEqual(view.url, site.url("/auth?wrong=1")); XCTAssertNil(pages.httpAuthentication)
    }

    func testNativeCredentialCompletionIsOnceOnlyTransientAndClearsSecureFields() {
        let view = WKWebView(frame: window.bounds)
        var replies: [(URLSession.AuthChallengeDisposition, URLCredential?)] = []
        let auth = PageHTTPAuthentication(tab: "owned", webView: view, navigation: nil, document: UUID(),
            requestedURL: nil, privateSession: nil, site: "owned.test") { replies.append(($0, $1)) }
        auth.controller.textFields?.first?.text = "owned"; auth.controller.textFields?.last?.text = "fixture"
        auth.resolve(user: "owned", password: "fixture", animated: false)
        auth.resolve(user: "stale", password: "stale", animated: false)
        XCTAssertEqual(replies.count, 1); XCTAssertEqual(replies[0].0, .useCredential)
        XCTAssertEqual(replies[0].1?.persistence, URLCredential.Persistence.none)
        XCTAssertTrue(auth.controller.textFields?.allSatisfy { $0.text?.isEmpty != false } == true)
    }

    func testProtectionSpaceCannotBorrowAnotherHostSchemePortOrProxy() {
        let url = URL(string: "https://owned.test:9443/page")!
        let exact = URLProtectionSpace(host: "owned.test", port: 9443, protocol: "https", realm: "Owned", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertTrue(PageHTTPAuthentication.matches(exact, url: url))
        XCTAssertFalse(PageHTTPAuthentication.matches(exact, url: URL(string: "https://another.test:9443")!))
        XCTAssertFalse(PageHTTPAuthentication.matches(exact, url: URL(string: "http://owned.test:9443")!))
        XCTAssertFalse(PageHTTPAuthentication.matches(exact, url: URL(string: "https://owned.test:8443")!))
        let proxy = URLProtectionSpace(proxyHost: "owned.test", port: 9443, type: NSURLProtectionSpaceHTTPSProxy, realm: "Owned", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertFalse(PageHTTPAuthentication.matches(proxy, url: url))
    }
}

/// Complete bounded HTTP responses with FIN, owned by this test only.
final class HTTPAuthenticationSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-http-auth-site")
    private let listener: NWListener
    private var callback: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var accepted = 0
    private var digestAccepted = 0
    private var rejected = 0
    private let digestNonce = UUID().uuidString
    var port: UInt16 { listener.port!.rawValue }
    var authorizedCount: Int { queue.sync { accepted } }
    var digestAuthorizedCount: Int { queue.sync { digestAccepted } }
    var rejectedCount: Int { queue.sync { rejected } }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    init() throws {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(_ done: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.callback = done
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let done = self.callback else { return }
                switch state {
                case .ready: self.callback = nil; done(.success(()))
                case let .failed(error): self.callback = nil; done(.failure(error))
                case .cancelled: self.callback = nil; done(.failure(NSError(domain: "HTTPAuthenticationSite", code: 2)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue); self.receive(connection, Data())
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let done = self.callback else { return }
                self.callback = nil; self.listener.cancel()
                done(.failure(NSError(domain: "HTTPAuthenticationSite", code: 1)))
            }
        }
    }
    func stop() {
        queue.sync {
            stopped = true; listener.cancel()
            let done = callback; callback = nil; done?(.failure(NSError(domain: "HTTPAuthenticationSite", code: 2)))
            connections.values.forEach { $0.cancel() }; connections = [:]
        }
    }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous; if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if ended { self.close(connection) } else { self.receive(connection, bytes) }; return
            }
            let path = header.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let digest = path.hasPrefix("/digest")
            let requiresAuth = path.hasPrefix("/auth") || digest
            let authorization = header.components(separatedBy: "\r\n").compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "authorization" else { return nil }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }.first
            let authorized = digest ? self.validDigest(authorization, target: path)
                : authorization == "Basic b3duZWQ6Zml4dHVyZQ=="
            if requiresAuth && authorized { self.accepted += 1; if digest { self.digestAccepted += 1 } }
            if requiresAuth && authorization != nil && !authorized { self.rejected += 1 }
            let allowed = !requiresAuth || authorized
            let body = allowed ? "<style>body{padding:80px 20px 100px;font:18px -apple-system}</style><title>\(requiresAuth ? "Authenticated owned page" : "Owned page")</title><button id='result' onclick='this.textContent=\"Page touched\"'>\(requiresAuth ? "actual authorized response" : "Owned action")</button><a href='/auth'>Protected page</a>" : "Authentication cancelled"
            let challenge = digest ? "Digest realm=\"Owned\", nonce=\"\(self.digestNonce)\", algorithm=MD5, qop=\"auth\"" : "Basic realm=\"Owned\""
            let response = "HTTP/1.1 \(allowed ? "200 OK" : "401 Unauthorized")\r\n" + (allowed ? "" : "WWW-Authenticate: \(challenge)\r\n") + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }
    /// This owned endpoint validates WebKit's actual Digest response. No
    /// challenge or success is injected into the production delegate.
    private func validDigest(_ header: String?, target: String) -> Bool {
        guard let header, header.hasPrefix("Digest ") else { return false }
        var fields: [String:String] = [:]
        for part in header.dropFirst(7).split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return false }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard fields[key] == nil else { return false }; fields[key] = value
        }
        guard fields["username"] == "owned", fields["realm"] == "Owned", fields["nonce"] == digestNonce,
              fields["uri"] == target, fields["qop"] == "auth", let nc = fields["nc"], nc.count == 8,
              UInt32(nc, radix: 16) != nil, let cnonce = fields["cnonce"], !cnonce.isEmpty,
              let response = fields["response"], response.count == 32 else { return false }
        func md5(_ words: String) -> String { Insecure.MD5.hash(data: Data(words.utf8)).map { String(format: "%02x", $0) }.joined() }
        let expected = md5(md5("owned:Owned:fixture") + ":" + digestNonce + ":" + nc + ":" + cnonce + ":auth:" + md5("GET:" + target))
        return response.lowercased() == expected
    }
    private func close(_ connection: NWConnection) { connections[ObjectIdentifier(connection)] = nil; connection.cancel() }
}
