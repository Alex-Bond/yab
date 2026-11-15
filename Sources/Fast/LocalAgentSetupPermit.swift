import Foundation

/// A deliberate tool-registration action can install external MCP without
/// authorizing Yab to use an AI account. Each exact local argv runs once.
struct LocalAgentSetupPermit: @unchecked Sendable {
    private let id: UUID
    private let key: String
    private let binary: String
    private static var generations: [String: UUID] = [:]
    private static var remaining: [UUID: Set<[String]>] = [:]
    private static var children: [UUID: [Process]] = [:]

    static func userSetupClaude(binary: String) -> Self {
        ProviderLaunchPermit.atomic {
            let key = Store.folder.standardizedFileURL.path + "|claude"
            if let old = generations[key] { cancel(old) }
            let id = UUID()
            generations[key] = id; remaining[id] = Set(AgentSetup.localClaudeSetupArguments)
            return Self(id: id, key: key, binary: binary)
        }
    }
    var valid: Bool { ProviderLaunchPermit.atomic { Self.generations[key] == id && Self.remaining[id] != nil } }
    func revoke() { ProviderLaunchPermit.atomic { Self.cancel(id) } }
    static func revokeClaude() {
        ProviderLaunchPermit.atomic {
            let key = Store.folder.standardizedFileURL.path + "|claude"
            if let id = generations[key] { cancel(id) }
        }
    }
    private static func cancel(_ id: UUID) {
        remaining[id] = nil
        for process in children.removeValue(forKey: id) ?? [] where process.isRunning { process.terminate() }
    }
    func start(_ process: Process) throws -> Bool {
        try ProviderLaunchPermit.atomic {
            guard valid else { return false }
            let args = process.arguments ?? []
            let actual: [String]
            if process.executableURL?.path == binary { actual = args }
            else if process.executableURL?.path == "/bin/bash", args.count >= 3,
                    args[0] == "-c", args[1] == #"exec "$0" "$@""#, args[2] == binary { actual = Array(args.dropFirst(3)) }
            else { return false }
            guard Self.remaining[id]?.remove(actual) != nil else { return false }
            try process.run()
            Self.children[id, default: []].append(process)
            ConsentAudit.record("cli.start.local-setup")
            return true
        }
    }
}
