import Foundation

/// The local cleanup requested by Disconnect. It cannot authorize AI, discovery,
/// sign-in or setup, and a later connection attempt retires it before setup.
struct ProviderDisconnectPermit: @unchecked Sendable {
    private let id: UUID
    private let authority: String
    private let cli: String
    private let epoch: String
    private let settings: UserDefaults
    private var binary: String?
    private static var current: [String: UUID] = [:]
    private static var remaining: [UUID: Set<[String]>] = [:]
    private static var children: [UUID: [Process]] = [:]
    private static var retiring: [String: [DispatchGroup]] = [:]
    private var key: String { authority + "|" + cli }

    static func userDisconnect(authority: String, cli: String, settings: UserDefaults) -> Self? {
        ProviderLaunchPermit.atomic {
            guard (settings.stringArray(forKey: "agents.revoked-connections.v1") ?? []).contains(cli),
                  !(settings.stringArray(forKey: "agents.explicit-connections.v1") ?? []).contains(cli),
                  let epoch = settings.string(forKey: "agents.connection-generation." + cli) else { return nil }
            revoke(authority, cli: cli)
            let permit = Self(id: UUID(), authority: authority, cli: cli, epoch: epoch, settings: settings)
            current[permit.key] = permit.id
            remaining[permit.id] = cli == "claude" ? [["mcp", "remove", "--scope", "user", AgentSetup.server]]
                : cli == "codex" ? [["logout"]] : []
            return permit
        }
    }
    var valid: Bool {
        ProviderLaunchPermit.atomic {
            Self.current[key] == id && Self.remaining[id] != nil
                && settings.string(forKey: "agents.connection-generation." + cli) == epoch
                && (settings.stringArray(forKey: "agents.revoked-connections.v1") ?? []).contains(cli)
                && !(settings.stringArray(forKey: "agents.explicit-connections.v1") ?? []).contains(cli)
        }
    }
    func bound(to binary: String) -> Self { var copy = self; copy.binary = binary; return copy }
    @discardableResult func commit(_ work: () -> Void) -> Bool {
        ProviderLaunchPermit.atomic { guard valid else { return false }; work(); return true }
    }
    func revoke() { ProviderLaunchPermit.atomic { Self.cancel(id, authority: authority) } }
    static func revoke(_ authority: String, cli: String) {
        ProviderLaunchPermit.atomic {
            if let id = current.removeValue(forKey: authority + "|" + cli) { cancel(id, authority: authority) }
        }
    }
    private static func cancel(_ id: UUID, authority: String) {
        remaining[id] = nil
        for process in children.removeValue(forKey: id) ?? [] where process.isRunning {
            let done = DispatchGroup(); done.enter()
            retiring[authority, default: []].append(done)
            Shell.end(process, grace: 0.2) { process.waitUntilExit(); done.leave() }
        }
    }
    static func settled(_ authority: String) async {
        let waits = ProviderLaunchPermit.atomic { retiring[authority] ?? [] }
        guard !waits.isEmpty else { return }
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                for wait in waits { wait.wait() }
                ProviderLaunchPermit.atomic {
                    retiring[authority] = retiring[authority]?.filter { $0.wait(timeout: .now()) != .success }
                }
                done.resume()
            }
        }
    }
    func start(_ process: Process) throws -> Bool {
        try ProviderLaunchPermit.atomic {
            guard valid, let binary else { return false }
            let args = process.arguments ?? []
            let actual: [String]
            if process.executableURL?.path == binary { actual = args }
            else if process.executableURL?.path == "/bin/bash", args.count >= 3,
                    args[0] == "-c", args[1] == #"exec "$0" "$@""#, args[2] == binary { actual = Array(args.dropFirst(3)) }
            else { return false }
            guard Self.remaining[id]?.remove(actual) != nil else { return false }
            try process.runValidated()
            Self.children[id, default: []].append(process)
            ConsentAudit.record("cli.start.local-disconnect")
            return true
        }
    }
}
