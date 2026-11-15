import AppKit
import WebKit
import YabCoreClient

/// WebKit gives unrelated private tabs distinct nonpersistent stores. CEF must
/// use that same boundary; a space UUID would leak one private tab into another.
@MainActor
enum ChromiumPrivateProfiles {
    private final class Owner { weak var tab: Tab?; init(_ tab: Tab) { self.tab = tab } }
    private final class Identity {
        let profile = "private-" + UUID().uuidString
        var owners: [UUID: Owner] = [:]
    }
    private static let stores = NSMapTable<WKWebsiteDataStore, Identity>.weakToStrongObjects()

    static func authorize(_ profile: String, store: WKWebsiteDataStore, privateMode: Bool) throws {
        if !privateMode { try ChromiumPersistentProfiles.authorize(profile, store: store); return }
        guard !store.isPersistent, let identity = stores.object(forKey: store), identity.profile == profile,
              identity.owners.values.contains(where: { $0.tab?.gone == false }) else {
            throw ChromiumPersistentProfiles.Refused.unverifiedAssociation
        }
    }

    static func profile(for tab: Tab) -> String {
        let store = tab.pageStore
        precondition(tab.shy || !store.isPersistent)
        let value = stores.object(forKey: store) ?? Identity()
        value.owners = value.owners.filter { $0.value.tab?.gone == false }
        value.owners[tab.id] = Owner(tab)
        stores.setObject(value, forKey: store)
        return value.profile
    }

    static func release(_ tab: Tab) {
        guard tab.shy || !tab.pageStore.isPersistent, let value = stores.object(forKey: tab.pageStore) else { return }
        if value.owners[tab.id]?.tab === tab { value.owners[tab.id] = nil }
        value.owners = value.owners.filter { $0.value.tab?.gone == false }
        guard value.owners.isEmpty else { return }
        stores.removeObject(forKey: tab.pageStore)
        ChromiumDRMCookies.retirePrivate(value.profile)
        ChromiumDRMExtensionSession.retirePrivate(value.profile)
        ChromiumExtensions.retirePrivate(value.profile)
        ChromiumProcess.shared.retirePrivateProfile(value.profile)
    }
}

extension ChromiumProcess {
    /// Context destruction follows real native tab closure. No helper is
    /// started just to release a private context and no profile is force-killed.
    func retirePrivateProfile(_ profile: String) {
        guard let core = connectedClient else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                guard isCurrent(core), !Task.isCancelled else { return }
                // detach/native close can complete after the last Tab owner
                // goes away. Wait for that page rather than abandoning cleanup.
                if livePages.contains(where: { $0.profile == profile }) {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                do {
                    _ = try await core.request("profile.close", params: ["profile": .string(profile)])
                    return
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            DebugLog.note("private-profile", ["profile": profile, "error": "Native context did not retire within two seconds"])
        }
    }
}
