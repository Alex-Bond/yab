import Foundation

/// Permission belongs to this Yab profile, independently of a CLI's login.
@MainActor
final class ProviderConsent {
    static let shared = ProviderConsent()
    static let refusal = "Connect this AI in Yab › Settings › AI before using it."
    private let authority = UUID().uuidString
    private let settings: UserDefaults
    private let key = "agents.explicit-connections.v1"
    private let revokedKey = "agents.revoked-connections.v1"
    private(set) var revision = 0
    private var connections: [String: ProviderLaunchPermit] = [:]

    init(settings: UserDefaults = Store.settings, history: [Chat]? = nil) {
        self.settings = settings
        if !settings.bool(forKey: "agents.consent-migrated.v1") {
            let old = history ?? (Store.unitTests ? [] : Chats.read(Chats.folder))
            let denied = Set(settings.stringArray(forKey: revokedKey) ?? [])
            let providers = Set(old.filter(Self.manualUse).map(\.cli)).union(Self.standIns()).subtracting(denied)
            settings.set(Array(Set(settings.stringArray(forKey: key) ?? []).union(providers)).sorted(), forKey: key)
            settings.set(true, forKey: "agents.consent-migrated.v1")
        }
    }

    /// A probe world that is handed a stand-in agent (`YAB_AGENT_CLAUDE` and
    /// the like, Agents.found) has been told by its harness to use it: it
    /// counts as connected in a world that was never seeded with a choice
    /// (no `agents.consent-migrated.v1`). A world that seeds its own
    /// consent, or none on purpose, is not touched. Test runs only.
    static func standIns(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        guard Store.testing, !Store.unitTests else { return [] }
        let names = ["claude": "YAB_AGENT_CLAUDE", "codex": "YAB_AGENT_CODEX", "cursor": "YAB_AGENT_CURSOR", "gemini": "YAB_AGENT_GEMINI"]
        return Set(names.filter { environment[$0.value]?.isEmpty == false }.keys)
    }

    static func manualUse(_ chat: Chat) -> Bool {
        guard AgentPlan.clis.contains(chat.cli), chat.knowing != true, chat.remoteTask == nil,
              chat.routine == nil, chat.source == nil,
              [.field, .here, .newTabs].contains(chat.began) else { return false }
        let asked = chat.items.contains { item in
            item.kind == .asked && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && item.text != "Get to know me" && !item.text.hasPrefix(String(Agents.setUpMemoryPrompt.prefix(60)))
        }
        let answered = chat.items.contains { $0.kind == .message && $0.state == .done && !$0.text.isEmpty }
        return asked && (chat.state == "done" || answered)
    }

    func allows(_ cli: String) -> Bool {
        ProviderLaunchPermit.atomic {
            (settings.stringArray(forKey: key) ?? []).contains(cli)
            && !(settings.stringArray(forKey: revokedKey) ?? []).contains(cli)
        }
    }

    func permit(_ cli: String) -> ProviderLaunchPermit? {
        ProviderLaunchPermit.atomic {
            guard allows(cli) else { return nil }
            let key = "agents.connection-generation." + cli
            let epoch = settings.string(forKey: key) ?? UUID().uuidString
            settings.set(epoch, forKey: key)
            return ProviderLaunchPermit(authority: authority, cli: cli, epoch: epoch, settings: settings)
        }
    }

    func beginConnection(_ cli: String) {
        ProviderDisconnectPermit.revoke(authority, cli: cli)
        connections[cli]?.cancelConnection()
        connections[cli] = .connection(authority: authority, cli: cli, settings: settings)
    }
    func connectionPermit(_ cli: String) -> ProviderLaunchPermit? { connections[cli].flatMap { $0.valid ? $0 : nil } }
    func connectionPermits(_ clis: [String]) -> [String: ProviderLaunchPermit]? {
        ProviderLaunchPermit.atomic {
            let captured = Dictionary(uniqueKeysWithValues: clis.compactMap { cli in connectionPermit(cli).map { (cli, $0) } })
            return captured.count == clis.count ? captured : nil
        }
    }
    func endConnection(_ cli: String, permit: ProviderLaunchPermit? = nil) {
        guard let current = connections[cli], permit == nil || current.epoch == permit?.epoch else { return }
        current.cancelConnection(); connections[cli] = nil
    }
    func cancelConnections() {
        for cli in AgentPlan.clis { ProviderDisconnectPermit.revoke(authority, cli: cli) }
        for permit in connections.values { permit.cancelConnection() }
        connections = [:]
    }
    func disconnectPermit(_ cli: String) -> ProviderDisconnectPermit? {
        ProviderDisconnectPermit.userDisconnect(authority: authority, cli: cli, settings: settings)
    }
    func settleDisconnects() async { await ProviderDisconnectPermit.settled(authority) }

    func grant(_ cli: String) {
        ProviderLaunchPermit.atomic {
            guard AgentPlan.clis.contains(cli) else { return }
            ProviderDisconnectPermit.revoke(authority, cli: cli)
            connections.removeValue(forKey: cli)?.cancelConnection()
            if allows(cli) { return }
            var allowed = Set(settings.stringArray(forKey: key) ?? [])
            var revoked = Set(settings.stringArray(forKey: revokedKey) ?? [])
            allowed.insert(cli); revoked.remove(cli)
            settings.set(UUID().uuidString, forKey: "agents.connection-generation." + cli)
            settings.set(Array(allowed).sorted(), forKey: key)
            settings.set(Array(revoked).sorted(), forKey: revokedKey)
            revision += 1
        }
        NotificationCenter.default.post(name: AppleModelAccess.changed, object: nil)
    }

    func revoke(_ cli: String) {
        ProviderLaunchPermit.atomic {
            ProviderDisconnectPermit.revoke(authority, cli: cli)
            connections.removeValue(forKey: cli)?.cancelConnection()
            var allowed = Set(settings.stringArray(forKey: key) ?? [])
            var revoked = Set(settings.stringArray(forKey: revokedKey) ?? [])
            allowed.remove(cli); revoked.insert(cli)
            settings.set(UUID().uuidString, forKey: "agents.connection-generation." + cli)
            ProviderLaunchPermit.revoke(authority, cli: cli)
            settings.set(Array(allowed).sorted(), forKey: key)
            settings.set(Array(revoked).sorted(), forKey: revokedKey)
            revision += 1
        }
        NotificationCenter.default.post(name: AppleModelAccess.changed, object: nil)
    }
}

/// Admission and completion observations, with no page text or credentials.
enum ConsentAudit {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    static func record(_ event: String) { lock.withLock { counts[event, default: 0] += 1 } }
    static func snapshot() -> [String: Int] { lock.withLock { counts } }
}
