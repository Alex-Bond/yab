import Foundation
import Security
import WebKit

/// An exception names the exact TLS endpoint and the complete chain the
/// person inspected. A replacement certificate needs another decision.
struct CertificateException: Hashable, Codable {
    let host: String
    let port: Int
    let chain: [Data]
    /// When the person excused it, kept so a pardon can run out rather
    /// than live forever: a long-lived self-signed certificate stays
    /// excused for months at a stretch otherwise, and nobody comes back
    /// to look at it. Not part of equality: the endpoint and the chain
    /// are what was excused, and the date is only when.
    let at: Date

    /// Public endpoints are reconsidered after a week. Local devices,
    /// which commonly use self-signed certificates, get thirty days.
    /// A changed chain always needs a new decision.
    static let publicLives: TimeInterval = 7 * 24 * 3600
    static let localLives: TimeInterval = 30 * 24 * 3600

    var lives: TimeInterval {
        let bare = host.contains(":") ? "[\(host)]" : host
        return Address.isLocal(bare) ? Self.localLives : Self.publicLives
    }

    func expired(at now: Date) -> Bool { now.timeIntervalSince(at) >= lives }

    init?(host: String, port: Int, trust: SecTrust) {
        guard !host.isEmpty, (1...65535).contains(port),
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !certificates.isEmpty else { return nil }
        self.host = Self.hostName(host)
        self.port = port
        chain = certificates.map { SecCertificateCopyData($0) as Data }
        at = Date()
    }

    init(host: String, port: Int, chain: [Data], at: Date) {
        self.host = Self.hostName(host)
        self.port = port
        self.chain = chain
        self.at = at
    }

    private enum Keys: String, CodingKey { case host, port, chain, at }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        chain = try values.decode([Data].self, forKey: .chain)
        // A pardon from before the date was kept: it counts from now,
        // quietly, rather than refusing the whole file and losing the rest.
        at = try values.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }

    static func == (left: CertificateException, right: CertificateException) -> Bool {
        left.host == right.host && left.port == right.port && left.chain == right.chain
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(port)
        hasher.combine(chain)
    }

    static func hostName(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("[") && lower.hasSuffix("]") ? String(lower.dropFirst().dropLast()) : lower
    }

    /// The host itself or one under the site, as a site's data is named
    /// ("example.com" holds its subdomains).
    func under(_ site: String) -> Bool {
        let site = Self.hostName(site)
        return host == site || host.hasSuffix("." + site)
    }
}

/// WebKit pools TLS connections within a website data store and can reuse
/// one without another authentication callback. Exceptions therefore belong
/// to that sign-in profile, not a tab. Private stores remain independent.
///
/// A sign-in profile's exceptions are kept across launches, but not for good: one holds for a week on the web, or a month for
/// a machine on this network, until that endpoint shows another chain (so a
/// renewed certificate asks again, #494) or the time runs out, whichever
/// comes first. A private store's last only as long as the store.
@MainActor enum CertificateExceptions {
    private final class Decisions {
        var approved = Set<CertificateException>()
    }
    /// "default" for the default store, else the store's identifier.
    private typealias Profile = String
    private typealias Kept = [Profile: Set<CertificateException>]
    private static var persistent: Kept = [:]
    private static var loaded = false
    private static let ephemeral = NSMapTable<WKWebsiteDataStore, Decisions>.weakToStrongObjects()

    /// Beside the rest of what the app keeps; the tests point it elsewhere.
    static var file = Store.file("certificate-exceptions.json")

    private static func profile(_ store: WKWebsiteDataStore) -> Profile {
        profile(store.identifier)
    }

    private static func profile(_ id: UUID?) -> Profile {
        id?.uuidString ?? "default"
    }

    private static func kept(now: Date = Date()) -> Kept {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: file) {
                if let read = try? JSONDecoder().decode(Kept.self, from: data) {
                    // Persist dates assigned to legacy records once. Otherwise
                    // each launch would silently restart their lifetime.
                    save(read)
                } else {
                    Store.quarantine(file)
                }
            }
        }
        // Check the stored grant, not the fresh challenge, on every lookup.
        let alive = persistent.mapValues { $0.filter { !$0.expired(at: now) } }.filter { !$0.value.isEmpty }
        if alive != persistent { save(alive) }
        return persistent
    }

    private static func save(_ next: Kept) {
        persistent = next.filter { !$0.value.isEmpty }
        loaded = true
        if persistent.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard let data = try? JSONEncoder().encode(persistent) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        // A list of endpoints this Mac was told to trust is nobody else's
        // business, even in a folder only this account can enter.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// What was kept is read again on next use, as at a launch (tests).
    static func reload() {
        persistent = [:]
        loaded = false
    }

    static func contains(_ exception: CertificateException, in view: WKWebView, now: Date = Date()) -> Bool {
        contains(exception, in: view.configuration.websiteDataStore, now: now)
    }

    private static func contains(_ exception: CertificateException, in store: WKWebsiteDataStore, now: Date) -> Bool {
        if store.isPersistent { return kept(now: now)[profile(store)]?.contains(exception) == true }
        guard let decisions = ephemeral.object(forKey: store) else { return false }
        decisions.approved = decisions.approved.filter { !$0.expired(at: now) }
        return decisions.approved.contains(exception)
    }

    static func allow(_ exception: CertificateException, in view: WKWebView) {
        allow(exception, in: view.configuration.websiteDataStore)
    }

    private static func allow(_ exception: CertificateException, in store: WKWebsiteDataStore) {
        if store.isPersistent {
            var next = kept()
            guard next[profile(store), default: []].insert(exception).inserted else { return }
            save(next)
            return
        }
        let decisions = ephemeral.object(forKey: store) ?? Decisions()
        decisions.approved.insert(exception)
        ephemeral.setObject(decisions, forKey: store)
    }

    static func contains(_ exception: CertificateException, in page: ChromiumPage, now: Date = Date()) -> Bool {
        guard let tab = page.navigationTab, tab.chromiumProfile == page.profile,
              tab.shy == page.privateMode else { return false }
        let store = tab.pageStore
        if contains(exception, in: store, now: now) { return true }
        // Migrate only a matching, unexpired grant from the old engine key.
        // Preserve its original date rather than extending trust on lookup.
        guard store.isPersistent, !page.privateMode,
              let old = kept(now: now)["chromium-" + page.profile]?.first(where: { $0 == exception }) else { return false }
        allow(old, in: store)
        var next = kept(now: now)
        next["chromium-" + page.profile]?.remove(old)
        save(next)
        return true
    }

    static func allow(_ exception: CertificateException, in page: ChromiumPage) {
        guard let tab = page.navigationTab, tab.chromiumProfile == page.profile,
              tab.shy == page.privateMode else { return }
        allow(exception, in: tab.pageStore)
    }

    /// A site's data cleared in this store: its hosts ask again.
    static func forget(site: String, in store: WKWebsiteDataStore) {
        guard store.isPersistent else {
            if let decisions = ephemeral.object(forKey: store) { decisions.approved = decisions.approved.filter { !$0.under(site) } }
            return
        }
        var next = kept()
        let before = next
        let shared = profile(store) == profile(Store.websites)
        let ids = shared ? Set([Space.firstID, Space.mailID, Space.pinsID]).union(Spaces.sharing) : Set(store.identifier.map { [$0] } ?? [])
        for key in [profile(store)] + ids.map({ "chromium-" + $0.uuidString }) {
            if let had = next[key] { next[key] = had.filter { !$0.under(site) } }
        }
        if next != before { save(next) }
    }

    /// A space's own sign-ins erased: whatever it excused goes with them.
    static func forget(profile id: UUID) {
        var next = kept()
        let webKit = next.removeValue(forKey: profile(id))
        let chromium = next.removeValue(forKey: "chromium-" + id.uuidString)
        guard webKit != nil || chromium != nil else { return }
        save(next)
    }
}

extension Tab {
    /// "Continue to" on the Untrusted page (and the bench's `untrusted`):
    /// the endpoint excused in this tab's profile, and the page again.
    func continuePastUntrusted() {
        guard let untrusted, let exception = untrusted.exception else { return }
        if let page = builtPage as? ChromiumPage {
            CertificateExceptions.allow(exception, in: page)
            // Chrome holds the refused load three seconds for its own warning.
            page.stopLoading()
        }
        else if let web = webKitOnly("WebKit certificate exception context", build: false) { CertificateExceptions.allow(exception, in: web) }
        else { return }
        self.untrusted = nil
        go(to: untrusted.url)
    }
}
