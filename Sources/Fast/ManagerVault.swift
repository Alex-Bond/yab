import Foundation
import os

/// A connected password manager read through its own supported local
/// interface, so Yab can list a site's logins in its own menu and fill one
/// without the manager's in-page icon (docs/password-manager-vaults.md).
/// One adapter a manager, behind one protocol: the state of its vault, the
/// logins for a site (names only), one login's secret at the moment it is
/// filled, and saving a new one where the manager allows it.
///
/// Secrets: never logged, never written to disk, never passed as a
/// command-line argument (other processes can read those); they go in on
/// stdin or in the environment of the one child process that needs them,
/// and come back only from `secret`, to be filled at once and dropped.
enum ManagerVault {
    /// How deep Yab can go with a manager.
    enum Depth: String, Equatable, Sendable {
        /// Its official CLI or local API: Yab lists, fills, and maybe saves.
        case vault
        /// No API: Yab's menu over the extension's own, which still fills.
        case hybrid
        /// Only the extension's own UI.
        case extensionOnly
        /// Not reachable by Yab today (Apple's entitlement).
        case blocked
    }

    enum State: Equatable, Sendable {
        /// Its tool isn't on this Mac.
        case noTool
        /// The tool is there, but nobody signed in to it here.
        case signedOut
        /// Signed in, locked: Yab can unlock it with the saved password.
        case locked
        /// The manager's app asks the person (1Password's Touch ID).
        case needsApproval
        case open
        /// Something else; the words are for the row, never a secret.
        case failed(String)
    }

    /// One login as a menu row: never its password.
    struct Login: Identifiable, Equatable, Hashable, Sendable {
        let provider: String
        /// The manager's own id for the item.
        let item: String
        let title: String
        let user: String
        let urls: [String]
        var id: String { provider + "/" + item }
    }

    /// A login's secret, for one fill. Its description never shows it.
    struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let user: String
        let password: String
        /// The manager asked the person for this one before giving it (Apple
        /// Passwords' helper's Touch ID, 1Password's approval): the question
        /// Settings' "Ask before filling" puts, already answered
        /// (Vault.proveToFill).
        var proven = false
        var description: String { "Secret(\(user), ••••)" }
        var debugDescription: String { description }
    }

    enum Failure: Error, Equatable {
        case noTool, locked, signedOut, notFound, refused, timedOut, unreadable, unsupported
    }
}

/// What each adapter does. Every call may run a child process and is never
/// on the main thread.
protocol ManagerAdapter: Sendable {
    var provider: String { get }
    var depth: ManagerVault.Depth { get }
    /// It can save a new login through its API.
    var saves: Bool { get }
    func state() async -> ManagerVault.State
    /// Unlocks with the password Yab keeps for it (ManagerUnlock); false
    /// when it didn't take. Managers whose app asks the person ignore it.
    func unlock(_ password: String) async -> Bool
    func logins(for host: String) async throws -> [ManagerVault.Login]
    func secret(_ login: ManagerVault.Login) async throws -> ManagerVault.Secret
    func save(host: String, user: String, password: String) async throws
    /// Forgets whatever unlocked state Yab holds (a session key).
    func lock() async
}

extension ManagerAdapter {
    var saves: Bool { false }
    func unlock(_ password: String) async -> Bool { false }
    func save(host: String, user: String, password: String) async throws { throw ManagerVault.Failure.unsupported }
    func lock() async {}
}

// MARK: - the managers

extension ManagerVault {
    static let keeper = "bfogiafebfohielmmehodmfbbebbbpei"
    static let enpass = "kmcfomidfpdkfieipokbalgegidffkal"

    /// Every manager Yab lists, and how far Yab goes with each.
    static let adapters: [String: any ManagerAdapter] = {
        let list: [any ManagerAdapter] = [
            // Read by Yab only where it was checked against the tool
            // (stand-ins of `bw` and `op`). Proton Pass, Dashlane, LastPass
            // and Keeper had adapters for their CLIs never run against the
            // real tool: gone 2026-10-20, their extensions fill alone
            // (docs/password-manager-fields.md).
            BitwardenCLI(), OnePasswordCLI(),
            ExtensionOnlyVault(provider: PasswordManagers.nordPass, depth: .hybrid),
            ExtensionOnlyVault(provider: PasswordManagers.protonPass, depth: .extensionOnly),
            ExtensionOnlyVault(provider: PasswordManagers.dashlane, depth: .extensionOnly),
            ExtensionOnlyVault(provider: PasswordManagers.lastPass, depth: .extensionOnly),
            ExtensionOnlyVault(provider: keeper, depth: .extensionOnly),
            ExtensionOnlyVault(provider: enpass, depth: .hybrid),
            // Apple Passwords through its helper, no extension (ApplePasswords.swift).
            AppleVault(),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.provider, $0) })
    }()

    static func adapter(_ provider: String) -> (any ManagerAdapter)? {
        adapters[PasswordManagers.canonical(provider)]
    }

    /// Whether a login's addresses are for this host: the same registrable
    /// domain, as the managers' own default ("base domain") match does.
    static func matches(_ urls: [String], host: String) -> Bool {
        let site = Vault.registrable(host.lowercased())
        guard !site.isEmpty else { return false }
        return urls.contains { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
            guard let other = url?.host()?.lowercased(), !other.isEmpty else { return false }
            return Vault.registrable(other) == site
        }
    }

    /// The same login once, its user first by title.
    static func tidy(_ logins: [Login]) -> [Login] {
        var seen = Set<String>()
        return logins.filter { seen.insert($0.item).inserted }
            .sorted { ($0.user.lowercased(), $0.title.lowercased()) < ($1.user.lowercased(), $1.title.lowercased()) }
    }
}

/// A manager with no API Yab can use: what it shows is the extension's own
/// menu (NordPass, Enpass), or nothing yet (Apple Passwords).
struct ExtensionOnlyVault: ManagerAdapter {
    let provider: String
    let depth: ManagerVault.Depth
    func state() async -> ManagerVault.State { .noTool }
    func logins(for host: String) async throws -> [ManagerVault.Login] { throw ManagerVault.Failure.unsupported }
    func secret(_ login: ManagerVault.Login) async throws -> ManagerVault.Secret { throw ManagerVault.Failure.unsupported }
}

// MARK: - running a tool

/// A manager's command-line tool, found where its installers put it, run as
/// a child process with a clean environment. Its output is never logged.
struct ManagerTool: Sendable {
    let names: [String]
    /// YAB_<KEY>_CLI points a test world at a stand-in.
    let key: String
    /// A stand-in at this path, for tests.
    var at: String? = nil

    static let places = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                         NSHomeDirectory() + "/.npm-global/bin", NSHomeDirectory() + "/bin", "/usr/bin",
                         NSHomeDirectory() + "/.asdf/shims", NSHomeDirectory() + "/.local/share/mise/shims", NSHomeDirectory() + "/.volta/bin"]
        // Node version managers keep a bin a version (nvm, mise installs).
        + versions(NSHomeDirectory() + "/.nvm/versions/node", "bin")
        + versions(NSHomeDirectory() + "/.local/share/mise/installs/node", "bin")

    private static func versions(_ root: String, _ bin: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { root + "/" + $0 + "/" + bin }
    }

    var path: String? {
        if let at { return FileManager.default.isExecutableFile(atPath: at) ? at : nil }
        if Store.testing, let stand = ProcessInfo.processInfo.environment["YAB_\(key)_CLI"], !stand.isEmpty {
            return FileManager.default.isExecutableFile(atPath: stand) ? stand : nil
        }
        for place in Self.places {
            for name in names where FileManager.default.isExecutableFile(atPath: place + "/" + name) {
                return place + "/" + name
            }
        }
        return nil
    }

    struct Output: Sendable {
        let status: Int32
        let out: Data
        /// For telling locked from signed out; never shown or logged.
        let err: String
        var ok: Bool { status == 0 }
        var text: String { String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Runs it with these arguments (never a secret), `env` added to a
    /// minimal environment and `input` on stdin, for at most `timeout`.
    func run(_ arguments: [String], env: [String: String] = [:], input: Data? = nil,
             timeout: TimeInterval = 20) async throws -> Output {
        guard let path else { throw ManagerVault.Failure.noTool }
        return try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ProcessLaunch.executableURL(path)
                process.arguments = arguments
                let here = ProcessInfo.processInfo.environment
                var environment: [String: String] = [
                    "PATH": ([URL(fileURLWithPath: path).deletingLastPathComponent().path] + Self.places + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"),
                    "HOME": NSHomeDirectory(),
                    "LANG": "en_US.UTF-8",
                    "NO_COLOR": "1",
                ]
                // A test world's own data folders for the tools.
                for name in ["BITWARDENCLI_APPDATA_DIR", "OP_CONFIG_DIR", "XDG_CONFIG_HOME", "LPASS_HOME", "TMPDIR"] {
                    if let value = here[name] { environment[name] = value }
                }
                environment.merge(env) { $1 }
                process.environment = environment
                let out = Pipe(), err = Pipe(), into = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input == nil ? FileHandle.nullDevice : into
                var collected = Data(), complaint = Data()
                let reading = DispatchGroup()
                reading.enter()
                DispatchQueue.global().async { collected = out.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
                reading.enter()
                DispatchQueue.global().async { complaint = err.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
                do { try process.runValidated() } catch {
                    done.resume(throwing: ManagerVault.Failure.noTool)
                    return
                }
                if let input {
                    try? into.fileHandleForWriting.write(contentsOf: input)
                    try? into.fileHandleForWriting.close()
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                reading.wait()
                if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM {
                    done.resume(throwing: ManagerVault.Failure.timedOut)
                    return
                }
                done.resume(returning: Output(status: process.terminationStatus, out: collected,
                                              err: String(decoding: complaint, as: UTF8.self)))
            }
        }
    }
}

extension ManagerVault {
    static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }
}

// MARK: - Bitwarden: `bw`

/// Bitwarden's official CLI (bitwarden.com/help/cli). Signed in by the
/// person once (`bw login`); Yab unlocks it with the saved unlock password
/// (`bw unlock --passwordenv`) and keeps the session key in memory only.
/// Lists with `bw list items --url`, reads one with `bw get item`, saves
/// with `bw create item` from stdin.
final class BitwardenCLI: ManagerAdapter, @unchecked Sendable {
    let provider = PasswordManagers.bitwarden
    let depth = ManagerVault.Depth.vault
    let saves = true
    let tool: ManagerTool
    private let session = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let synced = OSAllocatedUnfairLock<Date?>(initialState: nil)

    init(tool: ManagerTool = ManagerTool(names: ["bw"], key: "BW")) { self.tool = tool }

    private var sessionEnv: [String: String] {
        session.withLock { $0 }.map { ["BW_SESSION": $0] } ?? [:]
    }

    func state() async -> ManagerVault.State {
        guard tool.path != nil else { return .noTool }
        guard let out = try? await tool.run(["status"], env: sessionEnv),
              let status = (ManagerVault.json(out.out) as? [String: Any])?["status"] as? String
        else { return .failed("bw didn't answer") }
        return Self.state(status)
    }

    static func state(_ status: String) -> ManagerVault.State {
        switch status {
        case "unlocked": return .open
        case "locked": return .locked
        case "unauthenticated": return .signedOut
        default: return .failed(status)
        }
    }

    func unlock(_ password: String) async -> Bool {
        guard let out = try? await tool.run(["unlock", "--passwordenv", "YAB_BW_UNLOCK", "--raw"],
                                            env: ["YAB_BW_UNLOCK": password]),
              out.ok, !out.text.isEmpty, !out.text.contains(" ")
        else { return false }
        session.withLock { $0 = out.text }
        // One sync an unlock, so a login added elsewhere is listed.
        _ = try? await tool.run(["sync"], env: sessionEnv, timeout: 30)
        synced.withLock { $0 = Date() }
        return true
    }

    func lock() async {
        session.withLock { $0 = nil }
    }

    func logins(for host: String) async throws -> [ManagerVault.Login] {
        guard session.withLock({ $0 }) != nil else { throw ManagerVault.Failure.locked }
        if synced.withLock({ $0.map { Date().timeIntervalSince($0) > 600 } ?? true }) {
            _ = try? await tool.run(["sync"], env: sessionEnv, timeout: 30)
            synced.withLock { $0 = Date() }
        }
        let out = try await tool.run(["list", "items", "--url", "https://" + host], env: sessionEnv)
        guard out.ok else { throw out.err.lowercased().contains("locked") ? ManagerVault.Failure.locked : ManagerVault.Failure.unreadable }
        return Self.logins(out.out, host: host)
    }

    /// Names only: the password `bw list` also gives is dropped here.
    static func logins(_ data: Data, host: String) -> [ManagerVault.Login] {
        guard let items = ManagerVault.json(data) as? [[String: Any]] else { return [] }
        return ManagerVault.tidy(items.compactMap { item in
            guard item["type"] as? Int == 1, let id = item["id"] as? String,
                  let login = item["login"] as? [String: Any] else { return nil }
            let urls = (login["uris"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
            return ManagerVault.Login(provider: PasswordManagers.bitwarden, item: id, title: item["name"] as? String ?? host,
                                      user: login["username"] as? String ?? "", urls: urls)
        })
    }

    /// Never proven: the vault is open on the session key Yab got with the
    /// saved unlock password, and `bw get` asks nobody.
    func secret(_ login: ManagerVault.Login) async throws -> ManagerVault.Secret {
        guard session.withLock({ $0 }) != nil else { throw ManagerVault.Failure.locked }
        let out = try await tool.run(["get", "item", login.item], env: sessionEnv)
        guard out.ok, let item = ManagerVault.json(out.out) as? [String: Any],
              let fields = item["login"] as? [String: Any], let password = fields["password"] as? String
        else { throw ManagerVault.Failure.notFound }
        return ManagerVault.Secret(user: fields["username"] as? String ?? "", password: password)
    }

    func save(host: String, user: String, password: String) async throws {
        guard session.withLock({ $0 }) != nil else { throw ManagerVault.Failure.locked }
        let item: [String: Any] = [
            "type": 1, "name": host, "notes": NSNull(), "favorite": false, "folderId": NSNull(),
            "login": ["username": user, "password": password, "uris": [["uri": "https://" + host, "match": NSNull()]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: item)
        // `bw create item` takes base64 of the JSON, here on stdin.
        let out = try await tool.run(["create", "item"], env: sessionEnv, input: Data(data.base64EncodedString().utf8))
        guard out.ok else { throw ManagerVault.Failure.refused }
    }
}

// MARK: - 1Password: `op`

/// 1Password's official CLI with the app integration (Settings › Developer
/// › Integrate with 1Password CLI): the app asks the person with Touch ID
/// for Yab, and keeps that for 10 minutes of use. Yab never types the
/// account password here. `op item list --categories Login`, `op item get
/// --reveal`, `op item create -` from a JSON template on stdin.
struct OnePasswordCLI: ManagerAdapter {
    let provider = PasswordManagers.onePassword
    let depth = ManagerVault.Depth.vault
    let saves = true
    var tool = ManagerTool(names: ["op"], key: "OP")

    func state() async -> ManagerVault.State {
        guard tool.path != nil else { return .noTool }
        guard let accounts = try? await tool.run(["account", "list", "--format", "json"]) else { return .failed("op didn't answer") }
        if accounts.ok, (ManagerVault.json(accounts.out) as? [Any])?.isEmpty ?? true { return .signedOut }
        // whoami answers without asking the person: signed in now, or not.
        guard let who = try? await tool.run(["whoami", "--format", "json"]) else { return .failed("op didn't answer") }
        return who.ok ? .open : .needsApproval
    }

    func logins(for host: String) async throws -> [ManagerVault.Login] {
        // Asks the person in 1Password when Yab isn't allowed yet.
        let out = try await tool.run(["item", "list", "--categories", "Login", "--format", "json"], timeout: 90)
        guard out.ok else { throw ManagerVault.Failure.refused }
        return Self.logins(out.out, host: host)
    }

    static func logins(_ data: Data, host: String) -> [ManagerVault.Login] {
        guard let items = ManagerVault.json(data) as? [[String: Any]] else { return [] }
        return ManagerVault.tidy(items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let urls = (item["urls"] as? [[String: Any]] ?? []).compactMap { $0["href"] as? String }
            guard ManagerVault.matches(urls, host: host) else { return nil }
            return ManagerVault.Login(provider: PasswordManagers.onePassword, item: id, title: item["title"] as? String ?? host,
                                      user: item["additional_information"] as? String ?? "", urls: urls)
        })
    }

    /// Proven when Yab wasn't allowed as it asked (whoami answers without
    /// asking anyone): then 1Password's app asked the person for this get,
    /// with Touch ID or the account password. Allowed already, within the
    /// app's 10 minutes, nobody was asked for it.
    func secret(_ login: ManagerVault.Login) async throws -> ManagerVault.Secret {
        let allowed = (try? await tool.run(["whoami", "--format", "json"]))?.ok == true
        let out = try await tool.run(["item", "get", login.item, "--reveal", "--format", "json"], timeout: 90)
        guard out.ok, var secret = Self.secret(out.out) else { throw ManagerVault.Failure.notFound }
        secret.proven = !allowed
        return secret
    }

    static func secret(_ data: Data) -> ManagerVault.Secret? {
        guard let item = ManagerVault.json(data) as? [String: Any],
              let fields = item["fields"] as? [[String: Any]] else { return nil }
        func value(_ purpose: String, _ id: String) -> String? {
            (fields.first { $0["purpose"] as? String == purpose } ?? fields.first { $0["id"] as? String == id })?["value"] as? String
        }
        guard let password = value("PASSWORD", "password") else { return nil }
        return ManagerVault.Secret(user: value("USERNAME", "username") ?? "", password: password)
    }

    func save(host: String, user: String, password: String) async throws {
        let template: [String: Any] = [
            "title": host, "category": "LOGIN",
            "urls": [["href": "https://" + host, "primary": true]],
            "fields": [
                ["id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username", "value": user],
                ["id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": password],
            ],
        ]
        let out = try await tool.run(["item", "create", "-", "--format", "json"],
                                     input: try JSONSerialization.data(withJSONObject: template), timeout: 90)
        guard out.ok else { throw ManagerVault.Failure.refused }
    }
}
