import Foundation
import YabCoreClient

/// A restricted page is never adopted as an ordinary ChromiumPage. Only the
/// dedicated native read routes accept its immutable owner/session capability.
/// This transport does not enable the backend while nativeRemoteRead is false.
@MainActor
final class ChromiumRemoteRead {
    struct Identity: Equatable, Sendable {
        let tab: String
        let profile: String
        let owner: String
        let session: String
        let token: String

        init?(_ value: JSONValue, profile: String, owner: String, session: String) {
            guard value["private"] == .bool(false), value["profile"] == .string(profile),
                  value["owner"] == .string(owner), value["session"] == .string(session),
                  let tab = value["tab"].string, Self.bounded(tab),
                  let token = value["token"].string, Self.bounded(token),
                  Self.bounded(profile), Self.bounded(owner), Self.bounded(session) else { return nil }
            self.tab = tab; self.profile = profile; self.owner = owner
            self.session = session; self.token = token
        }

        static func bounded(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }

        var parameters: [String: JSONValue] {
            ["tab": .string(tab), "profile": .string(profile), "private": .bool(false),
             "owner": .string(owner), "session": .string(session), "token": .string(token)]
        }

        func matches(_ value: JSONValue) -> Bool {
            Self(value, profile: profile, owner: owner, session: session) == self
        }
    }

    struct State: Equatable, Sendable {
        let url: String
        let title: String
        let loading: Bool
        let canGoBack: Bool
        let canGoForward: Bool
        let document: String?

        init?(_ value: JSONValue) {
            guard let url = value["url"].string, url.utf8.count <= 8192,
                  let title = value["title"].string, title.utf8.count <= 65536,
                  case .bool(let loading) = value["loading"],
                  case .bool(let back) = value["canGoBack"],
                  case .bool(let forward) = value["canGoForward"] else { return nil }
            // A fresh native blank is not a readable HTTP document. No URL
            // outside the immutable policy can become the current read target.
            guard url.isEmpty || url == "about:blank" || Self.httpURL(url) != nil else { return nil }
            if case .string(let document) = value["document"] {
                guard Identity.bounded(document) else { return nil }
                self.document = document
            } else {
                guard value["document"] == .null else { return nil }
                document = nil
            }
            self.url = url; self.title = title; self.loading = loading
            canGoBack = back; canGoForward = forward
        }

        static func httpURL(_ raw: String) -> URL? {
            guard raw.utf8.count <= 8192, let url = URL(string: raw),
                  RemoteReadPage.permits(URLRequest(url: url)) else { return nil }
            return url
        }
    }

    struct Receipt: Equatable, Sendable {
        // Autoplay alone is not a read policy. Every native boundary must be
        // installed before the first target navigation, including workers and
        // extension isolation in the captured profile's cookie context.
        static let safeguards = ["immutable", "fullTree", "httpGetOnly", "noRequestBody", "noURLCredentials",
                                 "noPopups", "noDownloads", "noDialogs", "noAuthPrompts", "noClientCertificates",
                                 "noPermissions", "noCapture", "noFileChooser", "autoplayLocked", "workerIsolated",
                                 "extensionIsolated"]
        let identity: Identity
        let state: State

        init?(_ value: JSONValue, profile: String, owner: String, session: String) {
            let policy = value["policy"]
            guard let identity = Identity(value, profile: profile, owner: owner, session: session),
                  policy["version"] == .number(1), policy["mode"] == .string("http-read"),
                  policy["cookies"] == .string("captured-profile"),
                  Self.safeguards.allSatisfy({ policy[$0] == .bool(true) }),
                  let state = State(value["state"]) else { return nil }
            self.identity = identity; self.state = state
        }
    }

    enum Navigation: String { case back, forward, reload }
    enum Read: String { case snapshot, text }
    enum Failure: Error, LocalizedError {
        case unavailable, invalidReceipt, retired, changedDocument, invalidAddress
        var errorDescription: String? {
            switch self {
            case .unavailable: "The native iPhone read policy is not available."
            case .invalidReceipt: "The native read policy could not be verified."
            case .retired: "The owned read page is no longer available."
            case .changedDocument: "The owned read document changed. Read it again."
            case .invalidAddress: "Only an HTTP(S) GET page can be read."
            }
        }
    }

    let identity: Identity
    private(set) var state: State
    private(set) var retired = false
    private var stateRevision = 0
    private let core: YabCoreClient
    private let isCurrent: @MainActor () -> Bool
    private let authorize: @MainActor () throws -> Void
    var changed: (@MainActor (State) -> Void)?

    private init(core: YabCoreClient, receipt: Receipt,
                 current: @escaping @MainActor () -> Bool,
                 authorize: @escaping @MainActor () throws -> Void) {
        self.core = core; identity = receipt.identity; state = receipt.state
        isCurrent = current; self.authorize = authorize
    }

    /// The caller captures and rechecks the canonical physical profile with
    /// ChromiumPersistentProfiles before connecting or calling this method.
    static func create(core: YabCoreClient, profile: String, owner: String, session: String, url: URL,
                       current: @escaping @MainActor () -> Bool,
                       authorize: @escaping @MainActor () throws -> Void) async throws -> ChromiumRemoteRead {
        guard current(), ChromiumProcess.shared.isCurrent(core), !Task.isCancelled else { throw Failure.retired }
        guard Identity.bounded(profile), Identity.bounded(owner), Identity.bounded(session),
              State.httpURL(url.absoluteString) != nil else { throw Failure.invalidAddress }
        try authorize()
        let hooks = await core.nativeHooks
        guard hooks["nativeRemoteRead"] == .bool(true) else { throw Failure.unavailable }
        guard current(), ChromiumProcess.shared.isCurrent(core), !Task.isCancelled else { throw Failure.retired }
        try authorize()
        // Native create refuses unknown contexts. This opens exactly the
        // already authorized captured public profile, without copying cookies.
        try await core.openProfile(profile, privateMode: false)
        guard current(), ChromiumProcess.shared.isCurrent(core), !Task.isCancelled else { throw Failure.retired }
        try authorize()
        let value: JSONValue
        do {
            value = try await core.request("read.page.create", params: ["profile": .string(profile), "private": .bool(false),
                "owner": .string(owner), "session": .string(session), "url": .string(url.absoluteString)])
        } catch {
            // A lost/cancelled reply does not prove native create had no
            // effect. Revocation also covers a still-pending native create.
            revoke(core: core, owner: owner, session: session)
            throw error
        }
        // Revocation may race the create reply. Retire the task in the same
        // original helper even when the receipt itself is malformed.
        guard current(), ChromiumProcess.shared.isCurrent(core), !Task.isCancelled,
              let receipt = Receipt(value, profile: profile, owner: owner, session: session) else {
            revoke(core: core, owner: owner, session: session)
            throw Failure.invalidReceipt
        }
        do { try authorize() }
        catch {
            revoke(core: core, owner: owner, session: session)
            throw error
        }
        return ChromiumRemoteRead(core: core, receipt: receipt, current: current, authorize: authorize)
    }

    private func check() throws {
        guard !retired, isCurrent(), ChromiumProcess.shared.isCurrent(core), !Task.isCancelled else {
            revoke(); throw Failure.retired
        }
        do { try authorize() } catch { revoke(); throw error }
    }

    private func request(_ method: String, _ parameters: [String: JSONValue] = [:]) async throws -> JSONValue {
        try check()
        let value = try await core.request(method, params: identity.parameters.merging(parameters) { _, added in added })
        try check()
        guard identity.matches(value) else { revoke(); throw Failure.invalidReceipt }
        return value
    }

    @discardableResult
    func refresh() async throws -> State {
        let revision = stateRevision
        let value = try await request("read.page.state")
        // A native changed event may beat the pending state reply to MainActor.
        // Never overwrite the newer document with an earlier queried mirror.
        if stateRevision == revision { try acceptState(value["state"]) }
        return state
    }

    func navigate(to url: URL) async throws {
        guard State.httpURL(url.absoluteString) != nil else { throw Failure.invalidAddress }
        try await navigate(["url": .string(url.absoluteString)])
    }

    func navigate(_ action: Navigation) async throws {
        try await navigate(["action": .string(action.rawValue)])
    }

    private func navigate(_ parameters: [String: JSONValue]) async throws {
        let revision = stateRevision
        let value = try await request("read.page.navigate", parameters)
        guard value["accepted"] == .bool(true) else { throw Failure.invalidReceipt }
        if stateRevision == revision { try acceptState(value["state"]) }
    }

    func read(_ kind: Read, interactive: Bool = true) async throws -> JSONValue {
        let before = try await refresh()
        guard let document = before.document, State.httpURL(before.url) != nil else { throw Failure.changedDocument }
        var parameters: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if kind == .snapshot { parameters["interactive"] = .bool(interactive) }
        let value = try await request("read.page.read", parameters)
        guard value["document"] == .string(document), value["framesComplete"] == .bool(true),
              value["result"].object != nil else { throw Failure.changedDocument }
        let after = try await refresh()
        guard before.document == after.document, before.url == after.url else { throw Failure.changedDocument }
        let result = value["result"]
        guard let encoded = try? JSONEncoder().encode(result), encoded.count <= 2 * 1024 * 1024 else {
            throw Failure.invalidReceipt
        }
        return result
    }

    private func acceptState(_ value: JSONValue) throws {
        guard let next = State(value) else { revoke(); throw Failure.invalidReceipt }
        stateRevision &+= 1
        state = next; changed?(next)
    }

    /// Routed before generic Chromium adoption or consent. Native read events
    /// contain only authenticated state; page strings cannot supply identity.
    func receive(_ event: YabCoreEvent) {
        guard event.name == "read.page.changed" || event.name == "read.page.closed" else { return }
        let value = JSONValue.object(event.params)
        guard identity.matches(value) else { return }
        guard !retired else { return }
        do {
            try check()
            if event.name == "read.page.closed" { retired = true; return }
            try acceptState(value["state"])
        } catch { revoke() }
    }

    func close() {
        guard !retired else { return }
        retired = true
        let parameters = identity.parameters
        guard ChromiumProcess.shared.isCurrent(core) else { return }
        Task { try? await core.request("read.page.close", params: parameters) }
    }

    /// Logical retirement is immediate. Cleanup uses only the original live
    /// helper and can never connect or make a replacement ordinary page.
    func revoke() {
        guard !retired else { return }
        retired = true
        Self.revoke(core: core, owner: identity.owner, session: identity.session)
    }

    private static func revoke(core: YabCoreClient, owner: String, session: String) {
        guard ChromiumProcess.shared.isCurrent(core) else { return }
        Task { try? await core.request("read.page.revoke", params: ["owner": .string(owner), "session": .string(session)]) }
    }
}
