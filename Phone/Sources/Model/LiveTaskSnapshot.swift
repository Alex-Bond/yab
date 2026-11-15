import Foundation
import SyncKit

/// The authored request plus an actual checked Mac observation. It is not a
/// fixture workflow and contains no guessed steps, provider, or approval.
struct LiveTaskSnapshot: Equatable, Identifiable {
    enum State: Equatable { case pending, observed(TaskRecords.Status) }
    let request: TaskRecords.Request
    let observation: TaskRecords.Observation?
    var id: String { request.id }
    var state: State { observation.map { .observed($0.status) } ?? .pending }
    var title: String { observation?.title ?? request.words }
    /// Its Mac, while it is down and the task waits for it (MacWords):
    /// "Waits for MacBook Pro · asleep since 18:52".
    var macWait: String?
    var progress: String {
        if observation == nil || observation?.status == .waits, let macWait { return macWait }
        guard let observation else { return "Queued for your Mac" }
        if !observation.progress.isEmpty { return observation.progress }
        switch observation.status {
        case .running: return "Working on your Mac"
        case .needsYou: return "Needs your attention"
        case .waits: return "Waiting on your Mac"
        case .failed: return "Failed"
        case .done: return "Completed"
        case .stopped: return "Stopped"
        }
    }
    /// Only terminal notices can leave the Now line without changing a task.
    var dismissibleNotice: Bool { observation?.status == .done || observation?.status == .failed }

    /// Offline wording belongs to presentation, not to the saved observation.
    func sameRecord(as other: Self) -> Bool {
        request == other.request && observation == other.observation
    }

    var result: String? { observation?.status == .done ? observation?.result : nil }
    var resultURL: String? { observation?.status == .done ? observation?.resultURL : nil }

    init(request: TaskRecords.Request, observation: TaskRecords.Observation?) throws {
        try request.validate()
        guard request.readOnlyEpoch != nil else { throw TaskRecords.Failure.unsupported }
        try observation?.validate(request: request)
        self.request = request; self.observation = observation
    }
}
