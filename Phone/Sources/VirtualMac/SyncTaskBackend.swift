import Foundation
import SyncKit

/// A distinct live request API. Construction does not enable TaskDesk, replace
/// fixture events, publish a capability, trust a key, or start a Mac provider.
@MainActor
final class SyncTaskBackend {
    private weak var app: AppModel?
    private weak var engine: PhoneSync?
    private let account: String
    private let mac: String
    private let epoch: String
    private let origin: TaskRecords.Origin

    private init(app: AppModel, engine: PhoneSync, mac: String, epoch: String, origin: TaskRecords.Origin) {
        self.app = app; self.engine = engine; account = engine.seal.account
        self.mac = mac; self.epoch = epoch; self.origin = origin
    }

    static func capture(in app: AppModel, mac: String) -> SyncTaskBackend? {
        guard let engine = app.sync.engine, app.sync.phase == .on, app.sync.ready,
              let origin = app.sync.currentTaskOrigin(), !origin.isPrivate,
              let epoch = engine.readOnlyTaskEpoch(on: mac) else { return nil }
        return SyncTaskBackend(app: app, engine: engine, mac: mac, epoch: epoch, origin: origin)
    }

    /// Commit is the first local fact. Failure returns no synthetic sending row
    /// and never falls back to old chat sends or another provider/account.
    func send(_ words: String) throws -> LiveTaskSnapshot {
        guard let app, let engine, app.sync.engine === engine, app.sync.phase == .on,
              app.sync.ready, engine.seal.account == account,
              app.sync.currentTaskOrigin() == origin, engine.readOnlyTaskEpoch(on: mac) == epoch else {
            throw TaskRecords.Failure.owner
        }
        let request = try engine.sendReadOnlyTaskRecord(words, on: mac, origin: origin, epoch: epoch)
        return try LiveTaskSnapshot(request: request, observation: nil)
    }

    /// Actual saved results remain readable after read-only authority ends;
    /// current account, engine and known Mac ownership are still mandatory.
    /// Only new sends require the original displayed route and producer epoch.
    func snapshots() -> [LiveTaskSnapshot] {
        guard let app, let engine, app.sync.engine === engine, app.sync.phase == .on,
              app.sync.ready, engine.seal.account == account,
              engine.macs.contains(where: { $0.id == mac }) else { return [] }
        if case .refused = engine.state { return [] }
        let observations = Dictionary(engine.taskRecords().map { ($0.task, $0) }, uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
        return engine.taskRequests().filter { $0.mac == mac && $0.readOnlyEpoch != nil }.compactMap {
            try? LiveTaskSnapshot(request: $0, observation: observations[$0.id])
        }
    }
}
