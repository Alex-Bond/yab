import CryptoKit
import Foundation
import WebKit
import YabCoreClient

/// A site's localStorage and IndexedDB live in one engine's files, so a sign-in
/// kept there (Firebase, Supabase and the like) is gone when the site next opens
/// on the other engine, by any road: the default changed, a rule, memory, an
/// update from a WebKit-only version. EngineSwitchDocument carries a live page;
/// this carries the origin, whichever way it arrives.
///
/// The engine that last used an origin is the one that knows it: the first
/// request on the other engine waits, for a moment, while what the origin keeps
/// is copied across from an empty document on each side, so none of the site's
/// code and no request is involved. Never into an engine with a page of that
/// origin open, and never after the wait is over: the destination would be
/// changed under a running page. An origin never seen here has only WebKit's
/// past, and WebKit's record list says whether it has anything.
///
/// Not carried: a frame's storage under another site, session storage (a live
/// switch's), service workers and Cache Storage (the site makes them again),
/// and a value structured clone can't write as text, such as a CryptoKey.
@MainActor
final class EngineStorageCarry {
    /// How long a first request waits for it, and for the most it may hold.
    /// A first Chromium page starts the helper's renderers too; most take 0.3 s.
    static let wait: TimeInterval = 6
    private static let limit = 24 * 1024 * 1024
    private static let part = 1024 * 1024

    private let store: WKWebsiteDataStore
    let profile: String
    private let holds: (WKWebsiteDataStore) -> Bool
    private let file: URL
    private let connect: () async throws -> (YabCoreClient, String)
    /// The ledger, by `Self.key` of each origin: no site is named in the
    /// file, so it is no list of where you went for anyone reading it after
    /// Clear History.
    private var last: [String: String]?
    private var salt = ""
    private static let live = NSHashTable<EngineStorageCarry>.weakObjects()
    private var webKitRecords: Task<Set<String>, Never>?
    private var moving: [String: Task<Bool, Never>] = [:]
    private var tail: Task<Void, Never>?
    /// Failed or out of time this run: every navigation of it would wait again.
    private var failed = Set<String>()
    /// Being written now: a page mustn't start under a half-written base.
    private var writing = Set<String>()
    private var chromium: ChromiumStorageSide?
    private var webKit: WebKitStorageSide?
    private var closing: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var retired = false
    private(set) var moved = 0

    init(profile: String, store: WKWebsiteDataStore, holds: @escaping (WKWebsiteDataStore) -> Bool,
         connect: @escaping () async throws -> (YabCoreClient, String)) {
        self.store = store
        self.profile = profile
        self.holds = holds
        self.connect = connect
        file = Self.ledger(profile: profile, store: store.identifier)
        Self.live.add(self)
    }

    nonisolated static func ledger(profile: String, store: UUID?) -> URL {
        ChromiumSwitchCookieLedger.file(profile: profile, store: store)
            .deletingPathExtension().appendingPathExtension("storage.json")
    }

    /// An origin as the ledger names it.
    nonisolated static func key(_ origin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + "\n" + origin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A ledger as the file holds it, origins named by key; one written
    /// before keys has them changed now.
    nonisolated static func rows(_ file: [String: String]) -> (salt: String, rows: [String: String]) {
        let salt = file["salt"] ?? UUID().uuidString
        var rows: [String: String] = [:]
        for (name, engine) in file where name != "salt" {
            rows[name.contains("://") ? key(name, salt: salt) : name] = engine
        }
        return (salt, rows)
    }

    /// Signed out everywhere: both engines are empty, and nothing the ledger
    /// said is true of them any more.
    static func forgetAll(stores: [WKWebsiteDataStore]) {
        for store in stores where store.isPersistent {
            for carry in live.allObjects where carry.store === store && !carry.retired {
                carry.last = [:]
                carry.saveNow()
            }
            let profile = ChromiumPersistentProfiles.profile(store: store, placement: Space.firstID)
            let file = ledger(profile: profile, store: store.identifier)
            guard !live.allObjects.contains(where: { $0.file == file && !$0.retired }) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    nonisolated static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let named = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(scheme)://\(named):\($0)" } ?? "\(scheme)://\(named)"
    }

    /// `known` is what WebKit's records say: a registrable name, or a host.
    nonisolated static func listed(_ host: String, in known: Set<String>) -> Bool {
        var parts = host.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            if known.contains(parts.joined(separator: ".")) { return true }
            parts.removeFirst()
        }
        return false
    }

    /// Where the origin's storage is to come from, if anywhere.
    nonisolated static func source(last: PageEngineKind?, opening: PageEngineKind, webKitHasIt: Bool) -> PageEngineKind? {
        if let last { return last == opening ? nil : last }
        return opening == .chromium && webKitHasIt ? .webKit : nil
    }

    enum Step: Equatable {
        /// Nothing anywhere to carry: this engine is where the origin lives now.
        case remember
        /// A page of the origin is open on this engine: nothing is written
        /// under it, and the ledger keeps naming the engine that has the
        /// newer storage, so the next carry still comes from there.
        case leave
        case carry(from: PageEngineKind)
    }

    nonisolated static func step(last: PageEngineKind?, opening: PageEngineKind, webKitHasIt: Bool, openThere: Bool) -> Step {
        guard let source = source(last: last, opening: opening, webKitHasIt: webKitHasIt) else { return .remember }
        return openThere ? .leave : .carry(from: source)
    }

    func prepare(for url: URL, in engine: PageEngineKind) async {
        guard !retired, let origin = Self.origin(of: url), !failed.contains(origin) else { return }
        let ledger = read()
        let was = ledger[key(origin)].flatMap(PageEngineKind.init(rawValue:))
        guard was != engine else { return }
        if let running = moving[origin] {
            _ = await Self.within(Self.wait, running)
            if writing.contains(origin) { _ = await running.value }
            return
        }
        var holds = false
        if was == nil, engine == .chromium, let host = url.host?.lowercased() {
            holds = Self.listed(host, in: await recordsOfWebKit())
        }
        let source: PageEngineKind
        switch Self.step(last: was, opening: engine, webKitHasIt: holds, openThere: openPage(of: origin, in: engine)) {
        case .remember: remember(origin, engine); return
        case .leave: return
        case .carry(let from): source = from
        }
        // Signed out of it here while Chromium's copy couldn't be cleared:
        // carried, the old account would come back. The ledger stays.
        if source == .chromium, let host = url.host, ChromiumClearingDebt.owes(host: host, profile: profile) { return }
        let began = Date()
        let until = began.addingTimeInterval(Self.wait)
        let previous = tail
        let task = Task<Bool, Never> { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.retired else { return false }
            do {
                let done = try await self.move(origin, from: source, to: engine, until: until)
                if done { self.remember(origin, engine); self.moved += 1 } else { self.failed.insert(origin) }
                return done
            } catch {
                NSLog("Engine storage: not carried to %@: %@", engine.rawValue, String(describing: error))
                self.failed.insert(origin)
                return false
            }
        }
        moving[origin] = task
        tail = Task { _ = await task.value }
        _ = await Self.within(Self.wait, task)
        if writing.contains(origin) { _ = await task.value }
        Task { [weak self] in
            _ = await task.value
            self?.moving[origin] = nil
            self?.closeSoon()
        }
    }

    func retire() {
        retired = true
        closeSides()
        saveNow()
    }

    /// True once the origin's storage is on `engine`. A wait that ran out
    /// leaves it for the next launch: nothing is written over a running page.
    private func move(_ origin: String, from source: PageEngineKind, to engine: PageEngineKind, until: Date) async throws -> Bool {
        guard let address = URL(string: origin + "/") else { return false }
        closing?.cancel()
        let from = try await side(source), to = try await side(engine)
        try await from.open(address)
        let head = try await from.call(["op": "read", "limit": Self.limit])
        let length = head["length"] as? Int ?? 0
        // The key first: reading the ledger in writes `last`, which an access to it here would overlap.
        let row = key(origin)
        guard head["keys"] as? Int ?? 0 > 0 || head["bases"] as? Int ?? 0 > 0 || head["whole"] as? Bool != true || last?[row] != nil else {
            return true // Nothing kept, and nothing on the other side to replace.
        }
        var parts: [String] = []
        var at = 0
        while at < length {
            let got = try await from.call(["op": "slice", "at": at, "size": Self.part])
            guard let part = got["part"] as? String, let next = got["next"] as? Int, next > at else { return false }
            parts.append(part)
            at = next
        }
        _ = try await from.call(["op": "begin"])
        guard Date() < until, !openPage(of: origin, in: engine) else { return false }
        try await to.open(address)
        _ = try await to.call(["op": "begin"])
        for part in parts { _ = try await to.call(["op": "add", "part": part]) }
        guard Date() < until, !openPage(of: origin, in: engine) else { return false }
        writing.insert(origin)
        defer { writing.remove(origin) }
        _ = try await to.call(["op": "write"])
        NSLog("Engine storage: carried %d keys, %d bases to %@", head["keys"] as? Int ?? 0, head["bases"] as? Int ?? 0, engine.rawValue)
        return true
    }

    private func side(_ engine: PageEngineKind) async throws -> any EngineStorageSide {
        switch engine {
        case .webKit:
            if let webKit { return webKit }
            let made = WebKitStorageSide(store: store)
            webKit = made
            return made
        case .chromium:
            if let chromium { return chromium }
            let (core, profile) = try await connect()
            let made = try await ChromiumStorageSide(core: core, profile: profile)
            chromium = made
            return made
        }
    }

    private func closeSoon() {
        closing?.cancel()
        closing = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.moving.isEmpty else { return }
            self.closeSides()
        }
    }

    private func closeSides() {
        webKit?.close(); webKit = nil
        chromium?.close(); chromium = nil
    }

    /// A page of this origin on that engine: the storage is in use there.
    private func openPage(of origin: String, in engine: PageEngineKind) -> Bool {
        BrowserWindows.shared.browsers.flatMap(\.pagesHeld).contains { tab in
            guard !tab.gone, holds(tab.pageStore), let page = tab.builtPage, page.engine == engine,
                  let url = page.committedURL else { return false }
            return Self.origin(of: url) == origin
        }
    }

    private func recordsOfWebKit() async -> Set<String> {
        if let webKitRecords { return await webKitRecords.value }
        let store = store
        let task = Task<Set<String>, Never> { @MainActor in
            await withCheckedContinuation { done in
                store.fetchDataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases]) { records in
                    done.resume(returning: Set(records.map { $0.displayName.lowercased() }))
                }
            }
        }
        webKitRecords = task
        return await task.value
    }

    private func read() -> [String: String] {
        if let last { return last }
        let found = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let (salt, rows) = Self.rows(found)
        self.salt = salt
        last = rows
        if found.keys.contains(where: { $0.contains("://") }) { saveNow() }
        return rows
    }

    /// The origin's row in the ledger.
    private func key(_ origin: String) -> String {
        _ = read()
        return Self.key(origin, salt: salt)
    }

    private func remember(_ origin: String, _ engine: PageEngineKind) {
        var ledger = read()
        let key = key(origin)
        guard ledger[key] != engine.rawValue else { return }
        ledger[key] = engine.rawValue
        last = ledger
        guard saving == nil else { return }
        saving = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.saving = nil
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let last else { return }
        if salt.isEmpty { salt = UUID().uuidString }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(last.merging(["salt": salt]) { row, _ in row }).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("Engine storage: ledger not saved: %@", String(describing: error)) }
    }

    /// True if it finished within the time. It goes on either way.
    private static func within(_ seconds: TimeInterval, _ task: Task<Bool, Never>) async -> Bool {
        final class Once { var answered = false }
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                let said = await task.value
                guard !once.answered else { return }
                once.answered = true
                done.resume(returning: said)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                guard !once.answered else { return }
                once.answered = true
                done.resume(returning: false)
            }
        }
    }
}

/// An empty document at an origin in one engine, for engine-carry.js.
@MainActor
protocol EngineStorageSide: AnyObject {
    func open(_ origin: URL) async throws
    func call(_ fields: [String: Any]) async throws -> [String: Any]
    func close()
}

private enum EngineStorageScript {
    static let source = PageScript.load("engine-carry")
    static let blank = "<!doctype html><meta charset=utf-8><title></title>"
}

enum EngineStorageError: Error {
    case unanswered, noDocument
}

@MainActor
private final class WebKitStorageSide: NSObject, EngineStorageSide, WKNavigationDelegate {
    private let view: WKWebView
    private var opened: CheckedContinuation<Void, Error>?
    private var shown: URL?
    private var turn = 0

    init(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 16, height: 16), configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func open(_ origin: URL) async throws {
        guard shown != origin else { return }
        shown = nil
        turn &+= 1
        let mine = turn
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            opened = done
            view.loadSimulatedRequest(URLRequest(url: origin), responseHTML: EngineStorageScript.blank)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(EngineStorageCarry.wait * 1e9))
                if self?.turn == mine { self?.settle(.failure(EngineStorageError.noDocument)) }
            }
        }
        shown = origin
    }

    private func settle(_ result: Result<Void, Error>) {
        opened?.resume(with: result)
        opened = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settle(.success(())) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { settle(.failure(error)) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settle(.failure(error))
    }

    func call(_ fields: [String: Any]) async throws -> [String: Any] {
        let body = "return await (\(EngineStorageScript.source))(fields)"
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<[String: Any], Error>) in
            view.callAsyncJavaScript(body, arguments: ["fields": fields], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): done.resume(returning: value as? [String: Any] ?? [:])
                case .failure(let error): done.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        shown = nil
    }
}

/// A hidden helper tab in a profile, for a script in the document it shows.
@MainActor
final class ChromiumHiddenPage {
    private let core: YabCoreClient
    let tab: String
    private var frame: JSONValue?

    /// `url`: where it starts. An extension's page starts there rather than
    /// moving from about:blank, which takes it to another renderer.
    init(core: YabCoreClient, profile: String, url: String = "about:blank") async throws {
        self.core = core
        tab = try await core.createTab(profile: profile, url: url)
        _ = try await core.request("tab.visible", params: ["tab": .string(tab), "visible": .bool(false)])
        _ = try await core.request("scripts.install", params: ["tab": .string(tab), "scripts": .array([]), "relays": .object([:])])
    }

    /// `load` starts a document, and this waits for its main context at `wanted`.
    func show(where wanted: @escaping (URL) -> Bool, load: (YabCoreClient, String) async throws -> Void) async throws {
        frame = nil
        try await load(core, tab)
        let until = Date().addingTimeInterval(EngineStorageCarry.wait)
        while Date() < until {
            let state = try await core.request("scripts.status", params: ["tab": .string(tab)])
            if case .array(let contexts) = state["contexts"],
               let found = contexts.first(where: { context in
                   context["default"] == .bool(true) && context["main"] == .bool(true)
                       && (context["url"].string.flatMap(URL.init(string:)).map(wanted) ?? false)
               }) {
                frame = found["token"]
                return
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        throw EngineStorageError.noDocument
    }

    func run(_ function: String, _ argument: JSONValue, gesture: Bool = false) async throws -> JSONValue {
        guard let frame else { throw EngineStorageError.noDocument }
        return try await core.request("scripts.evaluate", params: [
            "tab": .string(tab), "frame": frame, "world": .string(""), "arguments": argument, "function": .string(function),
            "userGesture": .bool(gesture)])
    }

    func close() {
        let core = core, tab = tab
        Task { try? await core.closeTab(tab) }
    }
}

@MainActor
private final class ChromiumStorageSide: EngineStorageSide {
    private let page: ChromiumHiddenPage
    private var shown: URL?

    init(core: YabCoreClient, profile: String) async throws {
        page = try await ChromiumHiddenPage(core: core, profile: profile)
    }

    func open(_ origin: URL) async throws {
        guard shown != origin else { return }
        shown = nil
        let wanted = EngineStorageCarry.origin(of: origin)
        try await page.show(where: { EngineStorageCarry.origin(of: $0) == wanted }) { core, tab in
            _ = try await core.request("tab.loadHTML", params: ["tab": .string(tab), "url": .string(origin.absoluteString),
                                                                "html": .string(EngineStorageScript.blank)])
        }
        shown = origin
    }

    func call(_ fields: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let arguments = try JSONDecoder().decode(JSONValue.self, from: data)
        let value = try await page.run("function(fields){return (\(EngineStorageScript.source))(fields)}", arguments)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        return object as? [String: Any] ?? [:]
    }

    func close() { page.close() }
}
