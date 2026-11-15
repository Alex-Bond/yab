import Foundation
import WebKit
import YabCoreClient

/// What Clear Data or Sign Out everywhere could not take from Chromium's side
/// of a sign-in, with WebKit's already gone: owed, and paid before the
/// profile's next page under a helper, so no Chromium page or worker starts
/// on the account the person signed out of. Until it is paid, an origin of
/// the site is never carried from Chromium (EngineStorageCarry): the old
/// account would come back into WebKit from there.
@MainActor
enum ChromiumClearingDebt {
    nonisolated static let key = "chromium.clearing.owed"
    /// Sign Out everywhere: the whole sign-in's cookies and site data.
    nonisolated static let everything = "*"

    /// Chromium profile to the sites owed there.
    static var owed: [String: [String]] {
        get { Store.settings.dictionary(forKey: key) as? [String: [String]] ?? [:] }
        set {
            if newValue.isEmpty { Store.settings.removeObject(forKey: key) } else { Store.settings.set(newValue, forKey: key) }
        }
    }

    static func owe(_ site: String, store: WKWebsiteDataStore) {
        guard store.isPersistent else { return }
        let profile = ChromiumPersistentProfiles.profile(store: store, placement: Space.firstID)
        owed = adding(site, profile: profile, to: owed)
        DebugLog.note("chromium-clear", ["owed": site == everything ? "everything" : "site"])
    }

    nonisolated static func adding(_ site: String, profile: String, to owed: [String: [String]]) -> [String: [String]] {
        var all = owed
        var sites = all[profile] ?? []
        if !sites.contains(site) { sites.append(site) }
        all[profile] = sites
        return all
    }

    nonisolated static func paying(_ site: String, profile: String, in owed: [String: [String]]) -> [String: [String]] {
        var all = owed
        let sites = (all[profile] ?? []).filter { $0 != site }
        all[profile] = sites.isEmpty ? nil : sites
        return all
    }

    /// True while clearing a site this host belongs to is owed in `profile`.
    nonisolated static func owes(host: String, profile: String, in owed: [String: [String]]) -> Bool {
        let host = host.lowercased()
        return (owed[profile] ?? []).contains { $0 == everything || host == $0 || host.hasSuffix("." + $0) }
    }

    static func owes(host: String, profile: String) -> Bool { owes(host: host, profile: profile, in: owed) }

    private static var settling: [String: Task<Void, Never>] = [:]
    /// Once a helper per profile: one that fails leaves it for the next.
    private static var tried = Set<String>()

    /// Before the profile's first page or worker under this helper.
    static func settle(_ profile: String, core: YabCoreClient) async {
        guard let sites = owed[profile], !sites.isEmpty else { return }
        if let running = settling[profile] { await running.value; return }
        guard tried.insert(String(describing: ObjectIdentifier(core)) + "|" + profile).inserted else { return }
        guard let store = ChromiumSiteData.stores.first(where: {
            $0.isPersistent && ChromiumPersistentProfiles.profile(store: $0, placement: Space.firstID) == profile
        }) else {
            // The space is gone, and its Chromium folder with it.
            var all = owed; all[profile] = nil; owed = all
            return
        }
        let task = Task { @MainActor in
            for site in sites {
                let done: Bool
                if site == everything {
                    done = await ChromiumSiteData.clear([.cookies, .cache], in: [store])
                } else {
                    done = await ChromiumSiteData.forget(site: site, store: store)
                }
                if done { Self.owed = Self.paying(site, profile: profile, in: Self.owed) }
            }
        }
        settling[profile] = task
        await task.value
        settling[profile] = nil
    }
}
