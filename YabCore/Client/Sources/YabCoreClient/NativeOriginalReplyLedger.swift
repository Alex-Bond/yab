import Foundation

// Deliberately has NO cases/constructor. A wire ticket, JSON outcome or transport
// ledger must never create an authenticated native phase/journal/install proof.
enum NativeVerifiedPhaseReceipt: Sendable {}

/// Actor-confined production TRANSPORT bookkeeping, not native ownership.
struct NativeOriginalReplyLedger {
    enum Fact: Equatable, Sendable { case waiting, envelope, abandonedEnvelope, duplicate, missing, unknown }
    struct Row {
        let ticket: SocketWriteTicket
        var abandoned = false, seen = false
        var envelopeSHA256: String?
    }
    private(set) var rows: [String: Row] = [:]
    private(set) var poisoned = false
    private(set) var deliveredDigests: [String] = [] // Bounded diagnostics only.
    mutating func reserve(_ id: String, ticket: SocketWriteTicket, connection: String) -> Bool {
        let bytes = ticket.snapshot()
        guard !poisoned, rows.count < 32, rows[id] == nil,
              !id.isEmpty, id.utf8.count <= 128, connection.utf8.count <= 128,
              bytes.request == id, bytes.connection == connection else { return false }
        rows[id] = Row(ticket: ticket); return true
    }
    func contains(_ id: String) -> Bool { rows[id] != nil }
    mutating func abandon(_ id: String) {
        guard var row = rows[id] else { return }
        row.abandoned = true; rows[id] = row; poisoned = true
        // NO remove/cancel/retire/retry, including before a queued Socket write.
    }
    mutating func observedEnvelope(_ id: String, sha256: String) -> Fact {
        guard var row = rows[id] else { return .missing }
        guard !row.seen else { poisoned = true; return .duplicate }
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            abandon(id); return .unknown
        }
        row.seen = true; row.envelopeSHA256 = sha256; rows[id] = row
        if row.abandoned { return .abandonedEnvelope }
        guard !poisoned, row.ticket.snapshot().phase == .allWritten else {
            abandon(id); return .unknown
        }
        return .envelope // Original transport correlation ONLY, not native success.
    }
    mutating func deliveredEnvelope(_ id: String) -> Bool {
        guard let row = rows[id], !poisoned, !row.abandoned, row.seen,
              row.ticket.snapshot().phase == .allWritten,
              let digest = row.envelopeSHA256 else { return false }
        // A fully received, delivered TRANSPORT message may release its transport
        // slot. This does not acknowledge/free native group records/resources.
        deliveredDigests.append(digest)
        if deliveredDigests.count > 64 { deliveredDigests.removeFirst() }
        rows.removeValue(forKey: id); return true
    }
    mutating func sourceLost() {
        poisoned = true
        for id in Array(rows.keys) { rows[id]?.abandoned = true }
        // Retain each original request/ticket and first late digest, no payload.
    }
}
