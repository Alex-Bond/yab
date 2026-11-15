import Foundation
import SyncKit

// Tasks sent from the iPhone (docs/sync.md, "Tasks from the iPhone"): what
// marks a session as one, kept with it and its chat, and the boundary every
// call from it meets. The origin is never a permission: it only narrows.

/// The local reservation a task from the iPhone runs under (TaskLaunch).
/// A session or chat that has one can't lose it to a resume, a rule or MCP.
struct RemoteTaskOrigin: Codable, Equatable, Sendable {
    let mapping: TaskLaunch.Mapping

    init(_ mapping: TaskLaunch.Mapping) throws {
        try mapping.validate()
        self.mapping = mapping
    }
}

enum RemoteTaskBoundary {
    static let unavailable = "A task from iPhone can only read pages of its own. No action was performed."

    /// The MCP server's own session goes with every call it makes, even one
    /// that names another session as its target, so a task from the iPhone
    /// can't speak through a call about someone else. Outside clients are
    /// left as they are.
    static func bindMCP(_ request: [String: Any], inner: Bool, session: String?) -> [String: Any] {
        guard inner, let session else { return request }
        var bound = request
        bound["callerSession"] = session
        return bound
    }

    static func sourceIDs(_ request: [String: Any]) -> [String] {
        ["callerSession", "session", "resume"].compactMap { request[$0] as? String }
    }

    /// Any call that comes from, or carries on, a task from the iPhone and
    /// didn't go through SyncTaskRead is refused.
    @MainActor static func refusal(_ request: [String: Any], agents: Agents = .shared) -> String? {
        sourceIDs(request).contains(where: { agents.remoteTaskOrigin($0) != nil }) ? unavailable : nil
    }
}

extension Agents {
    /// The origin of a live session or of its kept chat; a subagent has its
    /// parent's. Looking it up changes nothing.
    func remoteTaskOrigin(_ id: String?) -> RemoteTaskOrigin? {
        var id = id
        var visited: Set<String> = []
        while let current = id, visited.insert(current).inserted {
            if let live = session(current) {
                if let origin = live.remoteTask { return origin }
                id = live.parent
            } else {
                return Chats.shared.chat(current)?.remoteTask
            }
        }
        return nil
    }
}
