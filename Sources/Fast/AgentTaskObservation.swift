import Foundation
import SyncKit

/// Only current native engine fields become a task observation. This value
/// cannot make a failed or empty answer look complete.
struct AgentTaskObservation: Equatable, Sendable {
    let status: TaskRecords.Status
    let title: String
    let progress: String
    let result: String?

    @MainActor init(_ session: Agents.Session) {
        // Its own name once it gave one, else the words it came with.
        title = session.title ?? Chat.title(from: session.prompt)
        let currentProgress = session.progress ?? session.now
        switch session.state {
        case .starting, .signingIn, .running, .attached:
            status = .running; result = nil; progress = currentProgress
        case .waiting:
            status = .needsYou; result = nil; progress = currentProgress
        case .stopped:
            status = .stopped; result = nil; progress = currentProgress
        case .failed:
            status = .failed; result = nil
            progress = session.result.isEmpty ? currentProgress : session.result
        case .done:
            if session.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = .failed; result = nil; progress = "The agent ended without a result."
            } else {
                status = .done; result = session.result; progress = currentProgress
            }
        }
    }

    func record(request: TaskRecords.Request, mapping: TaskLaunch.Mapping, revision: UInt64) throws -> TaskRecords.Observation {
        try TaskRecords.Observation(request: request, revision: revision, session: mapping.session,
                                    status: status, title: title, progress: progress, result: result)
    }
}
