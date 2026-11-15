import Foundation

/// A proxy is shared by all requests in a network profile. Coalesce its
/// challenges, and keep a refusal for this session instead of asking once
/// per image, tab, or background request. Nothing is persisted to disk.
@MainActor
final class ProxyAuthentication {
    static let shared = ProxyAuthentication()

    struct Key: Hashable {
        let scope: String
        let host: String
        let port: Int
        let realm: String
        let method: String
    }
    private struct Pending {
        let token: UUID
        var replies: [@MainActor (PageAuthenticationReply) -> Void]
    }
    private var pending: [Key: Pending] = [:]
    private var cancelled: Set<Key> = []
    private var configurations: [String: String] = [:]

    func authenticate(scope: String, host: String, port: Int, realm: String?, method: String,
                      configuration: String = "",
                      reply: @escaping @MainActor (PageAuthenticationReply) -> Void,
                      ask: (@escaping @MainActor (PageAuthenticationReply) -> Void) -> Void) {
        if configurations[scope] != configuration {
            reset(scope: scope)
            configurations[scope] = configuration
        }
        let key = Key(scope: scope, host: host.lowercased(), port: port, realm: realm ?? "", method: method.lowercased())
        guard !cancelled.contains(key) else { reply(.cancel); return }
        if pending[key] != nil {
            pending[key]?.replies.append(reply)
            return
        }
        let token = UUID()
        pending[key] = Pending(token: token, replies: [reply])
        ask { [weak self] answer in
            guard let self, self.pending[key]?.token == token,
                  let waiting = self.pending.removeValue(forKey: key) else { return }
            let answer = answer == .performDefaultHandling ? .cancel : answer
            // Default handling must not reopen a system prompt either.
            if case .credential = answer { } else { self.cancelled.insert(key) }
            for finish in waiting.replies { finish(answer) }
        }
    }

    /// A changed proxy configuration is a new opportunity to sign in. Retire
    /// outstanding callbacks before new challenges can join the old sheet.
    func reset(scope: String) {
        cancelled = cancelled.filter { $0.scope != scope }
        let old = pending.filter { $0.key.scope == scope }
        for key in old.keys { pending.removeValue(forKey: key) }
        for value in old.values { for reply in value.replies { reply(.cancel) } }
        configurations.removeValue(forKey: scope)
    }
}
