import Foundation

/// Actual outbound helper peer observation only, not native ownership,
/// document authority or authentication of this caller by the helper.
public struct NativeOriginalPeerSource: Equatable, Sendable {
    public let evidence: NativePeerIdentity.Evidence
    public let connection: String
    init(evidence: NativePeerIdentity.Evidence, connection: String) { self.evidence = evidence; self.connection = connection }
}
public enum NativeOriginalPeerObservation: Equatable, Sendable {
    case unavailable, unknown
    case observed(NativeOriginalPeerSource)
}
// The actual sealed-image/kernel counterpart factory lives beside the private launch witness.

struct NativeOriginalJournalBinding {
    let journal: NativeSwitchJournal
    let cursor: NativeSwitchJournal.Cursor
    let intent: NativeSwitchJournal.Intent
}
public enum NativeOriginalJournalTracking: Equatable, Sendable { case tracked, unavailable, unknown }
public enum NativeOriginalJournalLoss: Equatable, Sendable { case pending, storedUnknown, unknown }

extension YabCoreClient {
    public func originalPeerSource() async -> NativeOriginalPeerObservation {
        guard originalEndpointConnected, !originalPeerLost else { return .unknown }
        let result = await originalSocketObservation()
        guard originalEndpointConnected, !originalPeerLost else { return .unknown }
        if result == .unknown { loseOriginalPeer(.unreadableIdentity) }
        return result
    }
    func originalGroupReady() async -> Bool {
        // Only the actual original socket sealed-image/kernel factory can
        // supply this. Default0/empty policy keeps it unavailable.
        guard let counterpart = originalGroupCounterpart else { return false }
        guard case .observed(let source) = await originalPeerSource() else { return false }
        return counterpart.helper == source.evidence && counterpart.clientNonce == source.connection &&
            nativeGroupSource["helperOwner"] == .string(counterpart.factoryOwner) && nativeGroupSource["connection"] == .string(counterpart.groupConnection) &&
            Self.sameHelperHello(nativeGroupSource, source: source)
    }
    // Diagnostic matching seam only. It cannot create the counterpart seal or
    // bypass originalGroupReady's actual sealed-image factory.
    static func sameHelperHello(_ hello: [String: JSONValue], source: NativeOriginalPeerSource) -> Bool {
        hello["helperPID"] == .number(Double(source.evidence.pid)) &&
        hello["helperBirthSec"] == .string(String(source.evidence.startSec)) &&
        hello["helperBirthUsec"] == .number(Double(source.evidence.startUsec)) &&
        !(hello["connection"]?.string ?? "").isEmpty && !(hello["helperOwner"]?.string ?? "").isEmpty
    }
    public func trackOriginalJournal(_ journal: NativeSwitchJournal, cursor: NativeSwitchJournal.Cursor) async -> NativeOriginalJournalTracking {
        guard originalJournalBindings.count < 32 || originalJournalBindings[cursor.id] != nil else { return .unavailable }
        guard case .observed(let source) = await originalPeerSource() else { return .unknown }
        guard case .stored(let record) = await journal.load(cursor.id), record.cursor == cursor,
              record.intent.peer == source.evidence, record.intent.connection == source.connection,
              record.phase != .unknown, originalEndpointConnected, !originalPeerLost else { return .unknown }
        if let old = originalJournalBindings[cursor.id] {
            guard old.journal === journal, old.intent == record.intent, cursor.revision >= old.cursor.revision else { return .unknown }
        }
        originalJournalBindings[cursor.id] = NativeOriginalJournalBinding(journal: journal, cursor: cursor, intent: record.intent)
        return .tracked // Metadata only, never native admission/dispatch.
    }
    func loseOriginalPeer(_ reason: NativeSwitchJournal.Loss) {
        guard !originalPeerLost else { return }
        originalPeerLost = true // BEFORE any continuation/late result can run.
        loseOriginalNativeReplies()
        for (id, binding) in originalJournalBindings {
            originalJournalLoss[id] = .pending
            Task { [weak self] in
                // One local read/CAS, no native request or recovery retry.
                // Reconcile a newer metadata cursor only with the exact SAME
                // original immutable intent and actor, not replacement labels.
                let result: NativeOriginalJournalLoss
                // One locked latest-read/Intent-match/persist. A stale cursor
                // from a concurrently completing source phase cannot win here.
                let saved = await binding.journal.sourceLostLatest(reason, original: binding.intent)
                if case .stored(let unknown) = saved, unknown.phase == .unknown, unknown.intent == binding.intent {
                    result = .storedUnknown
                } else { result = .unknown }
                await self?.recordOriginalJournalLoss(id, result: result)
            }
        }
    }
    private func recordOriginalJournalLoss(_ id: UUID, result: NativeOriginalJournalLoss) {
        originalJournalLoss[id] = result // A status, never a reply to any peer.
    }
}
