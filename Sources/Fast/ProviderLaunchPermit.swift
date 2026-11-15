import Foundation

/// Checked on the worker immediately around process.run, not before an await.
struct ProviderLaunchPermit: @unchecked Sendable {
    let authority: String
    let cli: String
    let epoch: String
    let settings: UserDefaults
    var connecting = false
    /// A text-only Tidy request, authorized by its own feature switch.
    var tidy = false
    private static let lock = NSRecursiveLock()
    private struct Child {
        let authority: String
        let cli: String
        let epoch: String
        let connecting: Bool
        let process: Process
    }
    private static var children: [String: Child] = [:]
    private static var connections: Set<String> = []
    static func atomic<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
    private var connectionID: String { authority + "|" + cli + "|" + epoch }
    var valid: Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if tidy { return settings.object(forKey: "tidy.tabs") as? Bool ?? true }
        if connecting { return Self.connections.contains(connectionID) }
        return settings.string(forKey: "agents.connection-generation." + cli) == epoch
            && (settings.stringArray(forKey: "agents.explicit-connections.v1") ?? []).contains(cli)
            && !(settings.stringArray(forKey: "agents.revoked-connections.v1") ?? []).contains(cli)
    }
    static func forTidy(_ cli: String, settings: UserDefaults = Store.settings) -> Self {
        Self(authority: "tidy", cli: cli, epoch: UUID().uuidString, settings: settings, tidy: true)
    }
    static func connection(authority: String, cli: String, settings: UserDefaults) -> Self {
        lock.lock(); defer { lock.unlock() }
        let permit = Self(authority: authority, cli: cli, epoch: UUID().uuidString, settings: settings, connecting: true)
        connections.insert(permit.connectionID)
        return permit
    }
    func cancelConnection() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.connections.remove(connectionID)
        for child in Self.children.values where child.connecting && child.authority == authority && child.cli == cli && child.epoch == epoch && child.process.isRunning {
            child.process.terminate()
        }
        Self.children = Self.children.filter { $0.value.process.isRunning }
    }
    func start(_ process: Process) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard valid else { return false }
        try process.runValidated()
        ConsentAudit.record("cli.start." + cli)
        Self.children[UUID().uuidString] = Child(authority: authority, cli: cli, epoch: epoch, connecting: connecting, process: process)
        Self.children = Self.children.filter { $0.value.process.isRunning }
        return true
    }
    static func revoke(_ authority: String, cli: String) {
        lock.lock(); defer { lock.unlock() }
        connections = connections.filter { !$0.hasPrefix(authority + "|" + cli + "|") }
        for child in children.values where child.authority == authority && child.cli == cli && child.process.isRunning { child.process.terminate() }
        children = children.filter { $0.value.process.isRunning && !($0.value.authority == authority && $0.value.cli == cli) }
    }
}
