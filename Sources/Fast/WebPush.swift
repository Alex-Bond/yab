import YabStore
import AppKit
import CryptoKit
import WebKit

// Web Push: a site's notifications with its tab closed, as long as Yab is
// running (docs/site-notifications.md, "Closed sites"). Safari gets them
// through Apple's push daemon, which no other app may use; WKWebView's own
// pushManager.subscribe() fails for want of it. So Yab is its own push
// client:
//
// - The page's pushManager is Yab's (push-page.js, in the page's world, with
//   a bridge to Yab's world as passkeys have). subscribe() makes a P-256 key
//   pair and an auth secret here, asks Yab's push service for an endpoint,
//   and hands the site those three, as any browser does.
// - The push service is a box on the sync server (sync-server/src/webpush.ts)
//   that only carries what sites send: it's encrypted to the keys here
//   (RFC 8291) and the box never learns which site a subscription is for.
// - While Yab runs, a WebSocket to the box brings each message at once; it
//   is decrypted here (WebPushCrypto) and handed to WebKit, which wakes the
//   site's service worker with a push event, page or no page, as WebKit's
//   push daemon would (`_processPushMessage:`). What the worker shows comes to
//   SiteNotices like any of its notifications, and a click opens its page.
//
// Only for a site allowed to notify, never in a private window, and a site
// told no, forgotten, or cleared loses its subscriptions here and on the box.

@MainActor
final class WebPush: NSObject {
    static let shared = WebPush()

    /// One subscription: what the site was given, and the keys that open
    /// what it sends.
    struct Record: Codable, Equatable {
        /// The box's name for it, the last part of the endpoint.
        var id: String
        var endpoint: String
        /// As Browser.origin writes it.
        var origin: String
        /// The service worker registration's scope.
        var scope: String
        /// The sign-ins store it lives in (WKWebsiteDataStore.identifier),
        /// nil for the default one.
        var store: String?
        /// The site's applicationServerKey, URL-safe base64, "" if none.
        var key: String
        var secret: String
        var auth: String
        var made: Date
        /// The Chromium profile whose worker hears it, while the site's page
        /// last came from Chromium; nil when it last came from WebKit. A site
        /// that moves engines keeps its endpoint: only this changes.
        var profile: String?

        var keys: WebPushCrypto.Keys? {
            guard let raw = Data(urlBase64: secret), let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw),
                  let auth = Data(urlBase64: auth) else { return nil }
            return WebPushCrypto.Keys(privateKey: privateKey, auth: auth)
        }

        /// What the page's PushSubscription is made of.
        var reply: [String: Any] {
            ["endpoint": endpoint, "p256dh": keys?.publicKey.urlBase64 ?? "", "auth": auth, "key": key]
        }
    }

    /// This Yab's box and every subscription in it, kept in the keychain.
    struct State: Codable, Equatable {
        var box: String
        var secret: String
        var opened = false
        var subs: [Record] = []
    }

    enum Trouble: Error {
        case refused(String, String)
        var name: String { if case .refused(let name, _) = self { return name }; return "AbortError" }
        var message: String { if case .refused(_, let message) = self { return message }; return "" }
    }

    // MARK: - where

    /// The push service: YAB_WEBPUSH_URL, else the sync server's. A test
    /// world has none unless it names one.
    static var base: URL? {
        let env = ProcessInfo.processInfo.environment
        if let text = env["YAB_WEBPUSH_URL"], let url = URL(string: text) { return url }
        if Store.testing, env["YAB_SYNC_URL"] == nil { return nil }
        return SyncCenter.base
    }

    private var state: State?
    private var loaded = false

    private func current() -> State? {
        if !loaded {
            loaded = true
            state = Self.read()
        }
        return state
    }

    private func save(_ next: State?) {
        state = next
        loaded = true
        Self.write(next)
    }

    // MARK: - the page's questions

    /// A frame's subscription for its scope in its store, if any.
    func subscription(origin: String, scope: String, store: String?) -> Record? {
        current()?.subs.first { $0.origin == origin && $0.scope == scope && $0.store == store }
    }

    /// The same key gets the subscription there is; another key, the page
    /// must unsubscribe first, as the Push API asks.
    func subscribe(origin: String, scope: String, store: String?, key: String, profile: String? = nil) async throws -> Record {
        if let known = subscription(origin: origin, scope: scope, store: store) {
            guard known.key == key else {
                throw Trouble.refused("InvalidStateError", "A subscription with a different applicationServerKey already exists.")
            }
            heard(known, on: profile)
            return known
        }
        guard let base = Self.base else { throw Trouble.refused("AbortError", "Push service not available.") }
        var state = try await openBox(base)
        let made: [String: Any] = try await call(base, "POST", "v1/webpush/boxes/\(state.box)/subs", state.secret, body: key.isEmpty ? [:] : ["vapid": key])
        guard let id = made["id"] as? String, let endpoint = made["endpoint"] as? String else {
            throw Trouble.refused("AbortError", "Push service refused the subscription.")
        }
        let keys = WebPushCrypto.Keys.make()
        let record = Record(id: id, endpoint: endpoint, origin: origin, scope: scope, store: store, key: key,
                            secret: keys.privateKey.rawRepresentation.urlBase64, auth: keys.auth.urlBase64, made: Date(), profile: profile)
        // Another request may have saved while this one waited on the box.
        state = current() ?? state
        state.subs.removeAll { $0.origin == origin && $0.scope == scope && $0.store == store }
        state.subs.append(record)
        save(state)
        connect()
        return record
    }

    /// The site's page is on this engine now: so is its worker, the one
    /// that hears the next push. Never both, so nothing arrives twice.
    func heard(_ record: Record, on profile: String?) {
        guard record.profile != profile, var state = current(),
              let index = state.subs.firstIndex(where: { $0.id == record.id }) else { return }
        state.subs[index].profile = profile
        save(state)
    }

    func unsubscribe(origin: String, scope: String, store: String?) async -> Bool {
        guard let record = subscription(origin: origin, scope: scope, store: store) else { return false }
        remove([record])
        return true
    }

    /// Told no, forgotten (SiteNotices) or its data cleared: every
    /// subscription of the origin goes, here and on the box.
    func drop(origin: String) {
        remove(current()?.subs.filter { $0.origin == origin } ?? [])
    }

    /// Site Controls' Clear Data, by the site's name: the host and anything under it.
    func drop(site: String) {
        remove(current()?.subs.filter { record in
            let host = URL(string: record.origin)?.host() ?? ""
            return host == site || host.hasSuffix("." + site)
        } ?? [])
    }

    /// A deleted space's store.
    func drop(store: UUID) {
        remove(current()?.subs.filter { $0.store == store.uuidString } ?? [])
    }

    private func remove(_ gone: [Record]) {
        guard !gone.isEmpty, var state = current() else { return }
        let ids = Set(gone.map(\.id))
        state.subs.removeAll { ids.contains($0.id) }
        save(state)
        if let base = Self.base {
            let box = state.box, secret = state.secret
            Task.detached {
                for id in ids { _ = try? await WebPush.call(base, "DELETE", "v1/webpush/boxes/\(box)/subs/\(id)", secret, body: nil) }
            }
        }
        if state.subs.isEmpty { disconnect() }
    }

    // MARK: - the box

    /// Named and opened once; a name someone has (409) is made again.
    private func openBox(_ base: URL) async throws -> State {
        var state = current() ?? Self.newState()
        if state.opened { return state }
        for _ in 0..<2 {
            let status = try await Self.put(base, "v1/webpush/boxes/\(state.box)", ["secret": state.secret])
            if status == 201 || status == 204 {
                state.opened = true
                save(state)
                return state
            }
            if status == 409 { state = Self.newState(); continue }
            break
        }
        throw Trouble.refused("AbortError", "Push service not available.")
    }

    private nonisolated static func newState() -> State {
        State(box: random(16), secret: random(32))
    }

    private nonisolated static func random(_ count: Int) -> String {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes.urlBase64
    }

    private nonisolated static func request(_ base: URL, _ method: String, _ path: String, _ secret: String?, body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private nonisolated static func put(_ base: URL, _ path: String, _ body: [String: Any]) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request(base, "PUT", path, nil, body: body))
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @discardableResult
    private nonisolated static func call(_ base: URL, _ method: String, _ path: String, _ secret: String, body: [String: Any]?) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request(base, method, path, secret, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Trouble.refused("AbortError", "Push service answered \(status).") }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func call(_ base: URL, _ method: String, _ path: String, _ secret: String, body: [String: Any]?) async throws -> [String: Any] {
        try await Self.call(base, method, path, secret, body: body)
    }

    // MARK: - the socket

    private var socket: URLSessionWebSocketTask?
    private var pinger: Timer?
    private var retry: DispatchWorkItem?
    private var backoff: TimeInterval = 1
    private var watching = false
    /// What came and what WebKit made of it, the last few, for the bench.
    private(set) var delivered: [[String: Any]] = []
    private(set) var connected = false

    /// At launch: connected if any site has a subscription.
    func launch() {
        guard !watching else { return }
        watching = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        connect()
    }

    @objc private func woke() {
        disconnect()
        backoff = 1
        connect()
    }

    func connect() {
        guard socket == nil, let base = Self.base, let state = current(), state.opened, !state.subs.isEmpty,
              var parts = URLComponents(url: base.appending(path: "v1/webpush/boxes/\(state.box)/socket"), resolvingAgainstBaseURL: false)
        else { return }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(state.secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        listen(task)
        // Said at once, so the box's pong says the socket is up.
        task.send(.string("ping")) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in if self?.socket === task { self?.lost() } }
        }
        // A keepalive the box answers itself; a socket that can't take it is gone.
        pinger = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let socket = self.socket else { return }
                socket.send(.string("ping")) { error in
                    guard error != nil else { return }
                    Task { @MainActor in if self.socket === socket { self.lost() } }
                }
            }
        }
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.connected = true
                    self.backoff = 1
                    if case .string(let text) = message { self.heard(text) }
                    self.listen(task)
                case .failure:
                    self.lost()
                }
            }
        }
    }

    private func disconnect() {
        pinger?.invalidate()
        pinger = nil
        retry?.cancel()
        retry = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
    }

    /// Gone: again after a while, longer each time up to a minute.
    private func lost() {
        disconnect()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.connect() } }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(backoff * 2, 60)
    }

    private func heard(_ text: String) {
        guard text != "pong", let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["t"] as? String == "msgs", let list = message["messages"] as? [[String: Any]]
        else { return }
        var done: [Int] = []
        for item in list {
            if let id = item["id"] as? Int { done.append(id) }
            deliver(item)
        }
        // Handed to WebKit: the box forgets them. A worker that showed
        // nothing is the site's business, not a reason to send it again.
        if !done.isEmpty, let ack = try? JSONSerialization.data(withJSONObject: ["t": "ack", "ids": done]),
           let text = String(data: ack, encoding: .utf8) {
            socket?.send(.string(text)) { _ in }
        }
    }

    // MARK: - into the site's worker

    func deliver(_ item: [String: Any]) {
        let sub = item["sub"] as? String ?? ""
        var note: [String: Any] = ["sub": sub, "at": Date().timeIntervalSince1970]
        defer {
            delivered.append(note)
            if delivered.count > 20 { delivered.removeFirst(delivered.count - 20) }
        }
        guard let record = current()?.subs.first(where: { $0.id == sub }) else { note["result"] = "unknown"; return }
        note["origin"] = record.origin
        // Taken back since: nothing for the worker.
        guard SiteNotices.said(record.origin) == true else { note["result"] = "not allowed"; return }
        guard let keys = record.keys, let scope = URL(string: record.scope) else { note["result"] = "no keys"; return }
        let coding = item["enc"] as? String ?? ""
        let body = Data(base64Encoded: item["body"] as? String ?? "") ?? Data()
        var plain: Data?
        if !coding.isEmpty, !body.isEmpty {
            do {
                plain = try WebPushCrypto.open(body, coding: coding, encryption: item["encryption"] as? String ?? "",
                                               cryptoKey: item["cryptoKey"] as? String ?? "", keys: keys)
            } catch {
                note["result"] = "undecryptable"
                return
            }
        }
        note["bytes"] = plain?.count ?? 0
        note["result"] = "handed"
        let store = record.store.flatMap(UUID.init(uuidString:)).map(Spaces.store(identified:)) ?? Store.websites
        let toWebKit = { [weak self] in
            Self.process(store, scope: scope, data: plain) { [weak self] shown in
                guard let self, let index = self.delivered.lastIndex(where: { ($0["sub"] as? String) == sub }) else { return }
                self.delivered[index]["shown"] = shown
            }
        }
        guard let profile = record.profile else { note["engine"] = "webkit"; return toWebKit() }
        note["engine"] = "chromium"
        // A worker that isn't there any more, or a payload that isn't text,
        // which is all DevTools' door takes: WebKit's, rather than nowhere.
        Task { @MainActor [weak self] in
            let text = plain.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let fits = plain.map { Data(text.utf8) == $0 } ?? true
            var delivered = false
            if fits { delivered = await Self.toChromium(profile: profile, origin: record.origin, scope: record.scope, text: text) }
            guard let self, let index = self.delivered.lastIndex(where: { ($0["sub"] as? String) == sub }) else { return }
            self.delivered[index]["worker"] = delivered
            if !delivered { self.delivered[index]["engine"] = "webkit"; toWebKit() }
        }
    }

    /// A worker in Chromium, through the helper (YabCore/src/site_push.inc).
    private static func toChromium(profile: String, origin: String, scope: String, text: String) async -> Bool {
        guard let core = try? await ChromiumProcess.shared.connection() else { return false }
        _ = try? await core.openProfile(profile, privateMode: false)
        await ChromiumPermissions.opened(profile, core: core)
        await ChromiumClearingDebt.settle(profile, core: core)
        let reply = try? await core.request("push.deliver", params: [
            "profile": .string(profile), "origin": .string(SiteNotices.webKitOrigin(origin)),
            "scope": .string(scope), "data": .string(text)])
        return reply?["delivered"] == .bool(true)
    }

    /// WebKit's door for a push, the one Safari's daemon uses: the worker
    /// of `scope` gets a push event with `data`. Its answer may never come
    /// (a worker that shows nothing asks the daemon to count it), so it is
    /// taken only as news.
    static func process(_ store: WKWebsiteDataStore, scope: URL, data: Data?, done: @escaping @MainActor (Bool) -> Void) {
        let selector = NSSelectorFromString("_processPushMessage:completionHandler:")
        guard store.responds(to: selector) else { return done(false) }
        let message: NSDictionary = [
            "WebKitPushData": data.map { $0 as NSData } ?? NSNull(),
            "WebKitPushRegistrationURL": scope as NSURL,
            "WebKitPushPartition": "",
            "WebKitNotificationPayload": NSNull(),
        ]
        typealias Process = @convention(c) (AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
        let handler: @convention(block) (Bool) -> Void = { shown in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(shown) } }
        }
        unsafeBitCast(store.method(for: selector), to: Process.self)(store, selector, message, handler)
    }

    // MARK: - the keychain

    private nonisolated static var service: String { "\(Store.name) · web push" }
    private nonisolated static let account = "state"
    private nonisolated static var testFile: URL { Store.file("webpush.test.json") }

    private nonisolated static func read() -> State? {
        let data: Data?
        if Store.testing {
            data = try? Data(contentsOf: testFile)
        } else {
            var query = keychainQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            data = Keychain.copySaved(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
        }
        return data.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    private nonisolated static func write(_ state: State?) {
        guard let state, let data = try? JSONEncoder().encode(state) else {
            if Store.testing { try? FileManager.default.removeItem(at: testFile) } else { Keychain.removeSaved(keychainQuery() as CFDictionary) }
            return
        }
        if Store.testing {
            try? data.write(to: testFile, options: .atomic)
            return
        }
        let status = Keychain.save(keychainQuery() as CFDictionary, data: data, attributes: [
            kSecAttrLabel as String: "\(Store.name) Web Push",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ])
        if status != errSecSuccess { NSLog("yab: web push keys not kept (%d)", status) }
    }

    private nonisolated static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    // MARK: - the bench

    func bench() -> [String: Any] {
        let state = current()
        return ["base": Self.base?.absoluteString ?? "", "box": state?.box ?? "", "opened": state?.opened ?? false,
                "connected": connected, "socket": socket != nil,
                "subs": state?.subs.map { ["id": $0.id, "origin": $0.origin, "scope": $0.scope, "store": $0.store ?? "",
                                           "endpoint": $0.endpoint, "key": $0.key, "engine": $0.profile == nil ? "webkit" : "chromium"] } ?? [],
                "delivered": delivered]
    }
}

// MARK: - the page's side

/// yab's side of the page's pushManager (push-page.js), in yab's own world.
/// The frame's origin is WebKit's to say, never the page's.
final class PushRelay: NSObject, WKScriptMessageHandlerWithReply, PageScriptReplying {
    static let name = "yabPush"
    static let shared = PushRelay()
    static let asked = "yab-push-ask"
    static let answered = "yab-push-answer"

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo.securityOrigin
            let origin = Browser.origin(scheme: frame.protocol, host: frame.host, port: frame.port)
            let store = message.webView?.configuration.websiteDataStore
            handle(message.body, origin: origin, store: store?.isPersistent == true ? .some(store?.identifier?.uuidString) : nil,
                   profile: nil, replyHandler)
        }
    }

    /// The same request from a Chromium page, whose frame's origin is the
    /// helper's word. Its space's store names the subscription, as WebKit's
    /// does, so the site keeps it whichever engine shows it.
    func receive(_ message: PageScriptMessage, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let source = message.frame.origin
            let origin = Browser.origin(scheme: source.scheme, host: source.host, port: source.port)
            guard let page = message.sourceView as? ChromiumPage, !page.privateMode, let store = page.navigationTab?.pageStore else {
                return reply(["error": "NotSupportedError", "message": "Push isn't available here."], nil)
            }
            handle(message.body, origin: origin, store: store.isPersistent ? .some(store.identifier?.uuidString) : nil,
                   profile: page.profile, reply)
        }
    }

    /// `store`: nil where nothing is kept, a private window.
    @MainActor
    private func handle(_ message: Any, origin: String, store: String??, profile: String?,
                        _ replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        do {
            guard let body = message as? [String: Any], let kind = body["kind"] as? String else { return replyHandler(nil, "Not a request") }
            let refuse = { (name: String, text: String) in replyHandler(["error": name, "message": text], nil) }
            // Only a page's own scope, in a store that keeps things: never a private window.
            guard let scope = (body["scope"] as? String).flatMap(URL.init(string:)), Browser.origin(of: scope) == origin,
                  let storeID = store
            else { return refuse("NotSupportedError", "Push isn't available here.") }
            let push = WebPush.shared
            switch kind {
            case "get":
                let known = push.subscription(origin: origin, scope: scope.absoluteString, store: storeID)
                if let known { push.heard(known, on: profile) }
                replyHandler(known?.reply ?? NSNull(), nil)
            case "unsubscribe":
                Task { @MainActor in
                    let gone = await push.unsubscribe(origin: origin, scope: scope.absoluteString, store: storeID)
                    replyHandler(["ok": gone], nil)
                }
            case "subscribe":
                guard SiteNotices.said(origin) == true else { return refuse("NotAllowedError", "Permission denied.") }
                let key = body["key"] as? String ?? ""
                Task { @MainActor in
                    do {
                        let record = try await push.subscribe(origin: origin, scope: scope.absoluteString, store: storeID, key: key, profile: profile)
                        replyHandler(record.reply, nil)
                    } catch let trouble as WebPush.Trouble {
                        refuse(trouble.name, trouble.message)
                    } catch {
                        refuse("AbortError", "Push service not available.")
                    }
                }
            default:
                refuse("NotSupportedError", "Unknown request.")
            }
        }
    }

    /// In the page, before anything of the site's runs: pushManager and
    /// PushSubscription, as WebKit would have them with a push daemon.
    static let page = PageScript.load("push-page", vars: ["ANSWERED": answered, "ASKED": asked, "OVERRIDE": "false"])
    /// Chromium has a pushManager of its own, on Google's push service.
    static let chromiumPage = PageScript.load("push-page", vars: ["ANSWERED": answered, "ASKED": asked, "OVERRIDE": "true"])

    /// In yab's world: the page's request handed over as it is, the answer
    /// dispatched back.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__yabPushBridged) return;
      window.__yabPushBridged = true;
      window.addEventListener('\(asked)', function (event) {
        var message;
        try { message = JSON.parse(event.detail); } catch (e) { return; }
        if (!message || typeof message !== 'object' || typeof message.token !== 'string') return;
        function answer(reply) {
          window.dispatchEvent(new CustomEvent('\(answered)', { detail: JSON.stringify({ token: message.token, reply: reply }) }));
        }
        handler.postMessage(message).then(answer, function () { answer({ error: 'AbortError', message: 'Push service not available.' }); });
      });
    })();
    """
}
