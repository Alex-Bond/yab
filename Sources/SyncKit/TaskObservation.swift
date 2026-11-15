import Foundation

/// A local engine checkpoint and encrypted outbox update share one checked
/// transaction. The caller observes a real session; this starts nothing.
public enum TaskObservation {
    public enum Failure: Error, Equatable { case context, stale, corrupt, terminal }

    @discardableResult
    public static func checkpoint(_ observation: TaskRecords.Observation, mapping: TaskLaunch.Mapping,
                                  client: SyncClient, knownPhones: [SyncClient.Listed]) throws -> Record {
        guard client.state == .live, mapping.mac == client.device.id,
              mapping.account == client.seal.account,
              knownPhones.contains(where: { $0.id == mapping.phone && !$0.revoked
                  && $0.isMobile }) else { throw Failure.context }
        let saved = try client.journal.checkpointTaskObservation(observation, mapping: mapping,
                                                                account: client.seal.account, device: client.device.id)
        client.kick()
        return saved
    }

    /// Terminal results cannot be rewritten by a late stream callback. The
    /// mapping never grants retry, including after a clean process restart.
    public static func mayAdvance(from old: TaskRecords.Observation, to next: TaskRecords.Observation) -> Bool {
        guard old.revision < UInt64.max, next.revision == old.revision + 1 else { return false }
        return ![TaskRecords.Status.done, .failed, .stopped].contains(old.status)
    }
}
