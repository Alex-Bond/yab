import Foundation
import WebKit
import YabCoreClient

/// Cookie equality excludes Chromium's access timestamps and source port.
/// Partitioned cookies are skipped rather than copied into a different partition.
struct ChromiumDRMCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Double?
    var sameSite: String?
    var key: String { domain.lowercased() + "\n" + path + "\n" + name }

    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
        expires = cookie.isSessionOnly ? nil : cookie.expiresDate?.timeIntervalSince1970
        let policy = cookie.sameSitePolicy?.rawValue.lowercased()
        sameSite = policy == "strict" ? "Strict" : policy == "lax" ? "Lax" : cookie.isSecure ? "None" : "Lax"
        if policy == nil && !cookie.isSecure { NSLog("DRM cookies: insecure WebKit cookie without SameSite mapped to Lax") }
        // CEF uses seconds; avoid a permanent diff from subsecond Foundation dates.
        expires = expires.map { floor($0) }
    }

    init(_ json: JSONValue) throws {
        guard let name = json["name"].string, let value = json["value"].string,
              let domain = json["domain"].string, let path = json["path"].string,
              json["partitionKey"] == .null, json["partitionKeyOpaque"] != .bool(true) else {
            throw YabCoreError.remote("Partitioned or malformed DRM cookie cannot be synchronized")
        }
        self.name = name; self.value = value; self.domain = domain; self.path = path
        secure = json["secure"] == .bool(true); httpOnly = json["httpOnly"] == .bool(true)
        expires = json["session"] == .bool(true) ? nil : json["expires"].number.map { floor($0) }
        sameSite = json["sameSite"].string ?? "Lax"
        if sameSite == "None" && !secure {
            sameSite = "Lax"
            NSLog("DRM cookies: insecure Chromium SameSite=None cookie mapped to Lax")
        }
    }

    static func partitioned(_ cookie: HTTPCookie) -> Bool {
        (cookie.properties ?? [:]).contains { key, value in
            let name = key.rawValue.lowercased()
            return (name.contains("partition") && String(describing: value).lowercased() != "false" && String(describing: value) != "0")
        }
    }

    var webKit: HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { p[.secure] = "TRUE" }
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { p[.expires] = Date(timeIntervalSince1970: expires) } else { p[.discard] = "TRUE" }
        // WebKit expresses SameSite=None by omitting the policy.
        if let sameSite, sameSite != "None" { p[.sameSitePolicy] = sameSite.lowercased() }
        return HTTPCookie(properties: p)
    }

    var chromium: JSONValue {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        var p: [String: JSONValue] = ["name": .string(name), "value": .string(value), "path": .string(path),
            "url": .string((secure ? "https://" : "http://") + host + path),
            "secure": .bool(secure), "httpOnly": .bool(httpOnly)]
        // Omitting domain preserves a host-only cookie and __Host- prefixes.
        if domain.hasPrefix(".") { p["domain"] = .string(domain) }
        if let expires { p["expires"] = .number(expires) }
        if let sameSite { p["sameSite"] = .string(sameSite) }
        return .object(p)
    }

    var deletion: JSONValue { .object(["name": .string(name), "domain": .string(domain), "path": .string(path)]) }
}

/// Reconcile additions, edits and deletions with both previous snapshots.
/// On the first pass the existing WebKit sign-in wins a same-key conflict;
/// thereafter a WebKit edit wins only a simultaneous edit on both sides.
enum ChromiumDRMCookieMerge {
    struct Change { let key: String; let cookie: ChromiumDRMCookie? }
    struct Plan { var toWebKit: [Change] = []; var toChromium: [Change] = [] }
    static func plan(webKit: [String: ChromiumDRMCookie], chromium: [String: ChromiumDRMCookie],
                     previousWebKit: [String: ChromiumDRMCookie], previousChromium: [String: ChromiumDRMCookie]) -> Plan {
        plan(webKit: webKit, chromium: chromium,
             previous: ChromiumSwitchCookieLedger(webKit: ChromiumSwitchCookieLedger.fingerprint(previousWebKit),
                                                  chromium: ChromiumSwitchCookieLedger.fingerprint(previousChromium)))
    }

    static func plan(webKit: [String: ChromiumDRMCookie], chromium: [String: ChromiumDRMCookie],
                     previous: ChromiumSwitchCookieLedger) -> Plan {
        var result = Plan()
        let wHashes = ChromiumSwitchCookieLedger.fingerprint(webKit), cHashes = ChromiumSwitchCookieLedger.fingerprint(chromium)
        let keys = Set(webKit.keys).union(chromium.keys).union(previous.webKit.keys).union(previous.chromium.keys)
        for key in keys.sorted() {
            let w = webKit[key], c = chromium[key]
            guard w != c else { continue }
            if wHashes[key] != previous.webKit[key] { result.toChromium.append(Change(key: key, cookie: w)) }
            else if cHashes[key] != previous.chromium[key] { result.toWebKit.append(Change(key: key, cookie: c)) }
        }
        return result
    }
}

@MainActor
final class ChromiumDRMCookies: NSObject, WKHTTPCookieStoreObserver {
    private static var sessions: [String: ChromiumDRMCookies] = [:]
    static var hasSessions: Bool { !sessions.isEmpty }

    static func synchronizeBeforeQuit() async {
        var seen = Set<ObjectIdentifier>()
        let bridges = Array(sessions.values).filter { seen.insert(ObjectIdentifier($0)).inserted }
        await withTaskGroup(of: Void.self) { group in
            for bridge in bridges {
                group.addTask { @MainActor in
                    do { try await bridge.synchronizeForSwitching() }
                    catch { DebugLog.note("engine-switch-quit", ["error": String(describing: error)]) }
                }
            }
        }
    }
    let profile: String
    private let store: WKWebsiteDataStore
    private let privateMode: Bool
    private let storeConflict: Bool
    private let automaticSynchronization: Bool
    private var hosts = Set(ChromiumDRM.domains)
    private var allSites = false
    private var control: String?
    private var core: YabCoreClient?
    private var previous = ChromiumSwitchCookieLedger(webKit: [:], chromium: [:])
    private var ledgerLoaded = false
    private var pending: Task<Void, Error>?
    private var timer: Timer?
    private var retired = false
    private(set) var lastError: String?

    /// A WebKit-default app need not start Chromium until this sign-in profile
    /// has actually used it. Existing contexts must be reconciled before the
    /// first destination request, including immediately after a global restart.
    static func needsPreparation(_ tab: Tab) -> Bool {
        if tab.chromiumDRMEnabled || sessions[tab.chromiumProfile] != nil { return true }
        guard !tab.shy else { return false }
        return FileManager.default.fileExists(atPath: Store.file("Chromium").appendingPathComponent("space-" + tab.chromiumProfile).path)
    }

    static func of(_ tab: Tab) throws -> ChromiumDRMCookies {
        let profile = tab.chromiumProfile
        try ChromiumPrivateProfiles.authorize(profile, store: tab.pageStore, privateMode: tab.shy || !tab.pageStore.isPersistent)
        if let current = sessions[profile], (current.store === tab.pageStore || (current.store.isPersistent && current.store.identifier != nil && current.store.identifier == tab.pageStore.identifier)) { return current }
        // A mismatched store never reuses another space's live bridge.
        let key = profile + ":" + String(describing: ObjectIdentifier(tab.pageStore))
        if let current = sessions[key] { return current }
        let made = ChromiumDRMCookies(profile: profile, store: tab.pageStore, privateMode: tab.shy || !tab.pageStore.isPersistent, storeConflict: sessions[profile] != nil)
        if sessions[profile] == nil { sessions[profile] = made } else { sessions[key] = made }
        return made
    }

    static func retirePrivate(_ profile: String) {
        for (key, bridge) in sessions where bridge.profile == profile && bridge.privateMode {
            retire(key, bridge)
        }
    }

    static func retireStore(_ identifier: UUID) {
        for (key, bridge) in sessions where bridge.store.identifier == identifier { retire(key, bridge) }
    }
    private static func retire(_ key: String, _ bridge: ChromiumDRMCookies) {
        bridge.retired = true
        bridge.pending?.cancel()
        bridge.timer?.invalidate(); bridge.timer = nil
        bridge.store.httpCookieStore.remove(bridge)
        if let core = bridge.core, let id = bridge.control, ChromiumProcess.shared.isCurrent(core) {
            Task { try? await core.closeTab(id) }
        }
        bridge.control = nil; bridge.core = nil
        sessions[key] = nil
    }

    private init(profile: String, store: WKWebsiteDataStore, privateMode: Bool, storeConflict: Bool) {
        self.profile = profile; self.store = store; self.privateMode = privateMode; self.storeConflict = storeConflict
        automaticSynchronization = !(Store.testing && ProcessInfo.processInfo.environment["YAB_SWITCH_COOKIE_SYNC"] == "manual")
        super.init()
        store.httpCookieStore.add(self)
        // CEF's public CookieManager has no change observer. Read its complete
        // snapshot once a second while a DRM bridge exists, without waking UI.
        if automaticSynchronization {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in try? await self?.synchronize() }
            }
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard automaticSynchronization else { return }
        Task { @MainActor [weak self] in try? await self?.synchronize() }
    }

    func include(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else { return }
        hosts.insert(host.lowercased())
    }

    func includes(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else { return false }
        return allSites || hosts.contains { ChromiumDRM.matches(host: host, domain: $0) }
    }

    private func accepts(_ domain: String) -> Bool {
        if allSites { return true }
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return hosts.contains { host in
            ChromiumDRM.matches(host: domain, domain: host) || ChromiumDRM.matches(host: host, domain: domain)
        }
    }

    private func endpoint() async throws -> (YabCoreClient, String) {
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        try ChromiumPrivateProfiles.authorize(profile, store: store, privateMode: privateMode)
        let current = try await ChromiumProcess.shared.connection()
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        if let core, core === current, let control { return (core, control) }
        // After helper loss, old snapshots must not turn an empty context into
        // a sign-out. Reconcile again with the still-live WebKit store.
        if core != nil { previous = ChromiumSwitchCookieLedger(webKit: [:], chromium: [:]) }
        core = current
        try await current.openProfile(profile, privateMode: privateMode)
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        let id = try await current.createTab(profile: profile)
        guard !retired, !Task.isCancelled else {
            try? await current.closeTab(id)
            throw CancellationError()
        }
        control = id
        _ = try await current.request("tab.visible", params: ["tab": .string(id), "visible": .bool(false)])
        return (current, id)
    }

    func synchronize() async throws {
        while let pending { try await pending.value }
        let task = Task { @MainActor in
            defer { pending = nil }
            do { try await pass(); lastError = nil }
            catch { lastError = String(describing: error); throw error }
        }
        pending = task
        try await task.value
    }

    /// Engine switching shares this sign-in profile, including identity
    /// providers not on the DRM service list. Seed before the first request,
    /// not after a destination document has already redirected to sign-in.
    func synchronizeForSwitching() async throws {
        // Private profiles now follow the exact nonpersistent WebKit store.
        // Their state remains memory-only and dies with its last owning tab.
        allSites = true
        try await synchronize()
    }

    /// Synthetic cookies only, with no real profile values in the result.
    func roundTripForTesting(at url: URL) async throws -> [String: Bool] {
        guard Store.testing, let host = url.host, ["127.0.0.1", "localhost"].contains(host) else { throw CancellationError() }
        include(url)
        try await synchronize()
        let (core, id) = try await endpoint()
        let name = "yab_drm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let made = HTTPCookie(properties: [.name: name, .value: "chromium", .domain: host, .path: "/",
            .discard: "TRUE", .sameSitePolicy: "lax", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
        let initial = ChromiumDRMCookie(made)
        func remote(_ tab: String) async throws -> JSONValue? {
            let result = try await core.request("drm.cookies.list", params: ["tab": .string(tab)])
            guard case .array(let rows) = result["cookies"] else { return nil }
            return rows.first { $0["name"].string == name }
        }
        _ = try await core.request("drm.cookies.set", params: ["tab": .string(id), "cookie": initial.chromium])
        try await synchronize()
        let imported = await store.httpCookieStore.allCookies().first { $0.name == name }
        var checks = ["chromium_to_webkit": imported?.value == "chromium" && imported?.isHTTPOnly == true && imported?.isSessionOnly == true]
        var edited = initial
        edited.value = "webkit"
        await store.httpCookieStore.setCookie(edited.webKit!)
        try await synchronize()
        let exported = try await remote(id)
        checks["webkit_to_chromium"] = exported?["value"].string == "webkit" && exported?["httpOnly"] == .bool(true) && exported?["sameSite"] == .string("Lax")
        let otherProfile = "drm_isolation_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try await core.openProfile(otherProfile, privateMode: true)
        let other = try await core.createTab(profile: otherProfile)
        _ = try await core.request("tab.visible", params: ["tab": .string(other), "visible": .bool(false)])
        checks["other_profile_empty"] = try await remote(other) == nil
        try await core.closeTab(other)
        _ = try await core.request("drm.cookies.delete", params: ["tab": .string(id), "cookie": initial.deletion])
        try await synchronize()
        checks["chromium_signout"] = await store.httpCookieStore.allCookies().allSatisfy { $0.name != name }
        await store.httpCookieStore.setCookie(made)
        try await synchronize()
        await store.httpCookieStore.deleteCookie(made)
        try await synchronize()
        checks["webkit_signout"] = try await remote(id) == nil
        var none = initial
        none.secure = true; none.sameSite = "None"; none.value = "none"
        _ = try await core.request("drm.cookies.set", params: ["tab": .string(id), "cookie": none.chromium])
        try await synchronize()
        let importedNone = await store.httpCookieStore.allCookies().first { $0.name == name }
        checks["none_to_webkit"] = importedNone?.isSecure == true && importedNone?.sameSitePolicy == nil
        none.value = "none-edited"
        await store.httpCookieStore.setCookie(none.webKit!)
        try await synchronize()
        let exportedNone = try await remote(id)
        checks["none_to_chromium"] = exportedNone?["sameSite"] == .string("None") && exportedNone?["value"] == .string("none-edited")
        if let importedNone { await store.httpCookieStore.deleteCookie(importedNone) }
        try await synchronize()
        return checks
    }

    private func pass() async throws {
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        guard !storeConflict else { throw YabCoreError.remote("DRM cookie store does not match its Chromium space") }
        if Store.testing, !privateMode, !automaticSynchronization, store.identifier != Store.probeStore(1) {
            throw YabCoreError.remote("Switch fixture requires its isolated WebKit store")
        }
        let ledgerFile = ChromiumSwitchCookieLedger.file(profile: profile, store: store.identifier)
        if !ledgerLoaded {
            if !privateMode, store.isPersistent, FileManager.default.fileExists(atPath: ledgerFile.path) {
                previous = try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: Data(contentsOf: ledgerFile))
                // A restart has to compare every previously synchronized domain.
                allSites = true
            }
            ledgerLoaded = true
        }
        let (core, id) = try await endpoint()
        let response = try await core.request("drm.cookies.list", params: ["tab": .string(id)])
        guard case .array(let raw) = response["cookies"] else { throw YabCoreError.remote("Missing Chromium cookie snapshot") }
        var chromium: [String: ChromiumDRMCookie] = [:]
        for value in raw where value["domain"].string.map(accepts) == true {
            if value["partitionKey"] != .null || value["partitionKeyOpaque"] == .bool(true) {
                NSLog("DRM cookies: skipped partitioned Chromium cookie")
                continue
            }
            let cookie = try ChromiumDRMCookie(value)
            chromium[cookie.key] = cookie
        }
        let all = await store.httpCookieStore.allCookies()
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        var webKit: [String: ChromiumDRMCookie] = [:]
        for value in all where accepts(value.domain) {
            if ChromiumDRMCookie.partitioned(value) {
                NSLog("DRM cookies: skipped partitioned WebKit cookie")
                continue
            }
            let cookie = ChromiumDRMCookie(value)
            webKit[cookie.key] = cookie
        }
        let plan = ChromiumDRMCookieMerge.plan(webKit: webKit, chromium: chromium, previous: previous)
        for change in plan.toWebKit {
            guard !retired, !Task.isCancelled else { throw CancellationError() }
            if let cookie = change.cookie {
                guard let made = cookie.webKit else { throw YabCoreError.remote("WebKit rejected a DRM cookie") }
                await store.httpCookieStore.setCookie(made)
                webKit[change.key] = cookie
            } else if let old = webKit[change.key]?.webKit {
                await store.httpCookieStore.deleteCookie(old)
                webKit[change.key] = nil
            }
        }
        for change in plan.toChromium {
            guard !retired, !Task.isCancelled else { throw CancellationError() }
            let cookie = change.cookie ?? chromium[change.key]
            guard let cookie else { continue }
            _ = try await core.request(change.cookie == nil ? "drm.cookies.delete" : "drm.cookies.set",
                params: ["tab": .string(id), "cookie": change.cookie == nil ? cookie.deletion : cookie.chromium])
            chromium[change.key] = change.cookie
        }
        let next = ChromiumSwitchCookieLedger(webKit: ChromiumSwitchCookieLedger.fingerprint(webKit),
                                              chromium: ChromiumSwitchCookieLedger.fingerprint(chromium))
        if !privateMode, store.isPersistent, next != previous { try next.save(to: ledgerFile) }
        previous = next
    }
}

extension Tab {
    var chromiumProfile: String {
        // A warm/adopted private page is still an owner of its exact store.
        // Never let a supplied warm profile bypass that ownership boundary.
        if shy || !pageStore.isPersistent { return ChromiumPrivateProfiles.profile(for: self) }
        // A page made for a hover card has no window yet: it keeps its source's.
        if let warmProfile { return warmProfile }
        let browser = delegate as? Browser
        let placement = browser?.spaceHolding(self) ?? browser?.spaceID ?? Space.firstID
        return ChromiumPersistentProfiles.profile(store: pageStore, placement: placement)
    }
}
