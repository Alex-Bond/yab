import CryptoKit
import Foundation

/// Local read receipts only. A receipt contains digests, never the request or
/// result text, and cannot update a Mac or approve an action.
@MainActor
final class LiveTaskSeenStore {
    nonisolated struct Scope: Equatable {
        let folder: URL
        let account: String
        let phone: String
    }

    nonisolated struct Fingerprint: Equatable {
        let account: String
        let phone: String
        let id: String
        fileprivate let receipt: Receipt
    }

    fileprivate nonisolated struct Receipt: Codable, Equatable {
        let request: String
        let observation: String
    }

    private nonisolated struct Saved: Codable, Equatable {
        let version: Int
        let account: String
        let phone: String
        var receipts: [String: Receipt]
    }

    let scope: Scope
    private let file: URL
    private var saved: Saved
    private(set) var readable = true

    init(scope: Scope) {
        self.scope = scope
        let key = Self.digest(Data(("yab local task seen v1\n" + scope.account + "\n" + scope.phone).utf8))
        file = scope.folder.appendingPathComponent("task-seen-" + key + ".json")
        saved = Saved(version: 1, account: scope.account, phone: scope.phone, receipts: [:])
        do {
            if FileManager.default.fileExists(atPath: file.path) { saved = try read() }
        } catch { readable = false }
    }

    func contains(_ snapshot: LiveTaskSnapshot) -> Bool {
        guard let value = fingerprint(snapshot) else { return false }
        return contains(value)
    }

    /// Seen changes only after an atomic write and exact readback succeed.
    /// A failed/corrupt local store keeps the notice visible and reports failure.
    func mark(_ snapshot: LiveTaskSnapshot) -> Bool {
        guard let value = fingerprint(snapshot) else { return false }
        return mark(value)
    }

    func contains(_ value: Fingerprint) -> Bool {
        readable && value.account == scope.account && value.phone == scope.phone
            && saved.receipts[value.id] == value.receipt
    }

    func mark(_ value: Fingerprint) -> Bool {
        guard readable, value.account == scope.account, value.phone == scope.phone else { return false }
        if saved.receipts[value.id] == value.receipt { return true }
        var next = saved
        next.receipts[value.id] = value.receipt
        guard next.receipts.count <= 4096 else { return false }
        do {
            try FileManager.default.createDirectory(at: scope.folder, withIntermediateDirectories: true)
            try requireRegularFileIfPresent()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            guard data.count <= 1_048_576 else { return false }
            try data.write(to: file, options: .atomic)
            guard try read() == next else { return false }
            saved = next
            return true
        } catch { return false }
    }

    /// Compute at real reconciliation, never from a repeated UI projection.
    func fingerprint(_ snapshot: LiveTaskSnapshot) -> Fingerprint? {
        guard let receipt = try? receipt(snapshot) else { return nil }
        return Fingerprint(account: scope.account, phone: scope.phone, id: snapshot.id, receipt: receipt)
    }

    private func receipt(_ snapshot: LiveTaskSnapshot) throws -> Receipt {
        guard snapshot.request.account == scope.account, snapshot.request.phone == scope.phone,
              let observation = snapshot.observation, snapshot.dismissibleNotice else {
            throw TaskSeenFailure.invalid
        }
        try observation.validate(request: snapshot.request)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Receipt(request: try snapshot.request.digest(), observation: Self.digest(try encoder.encode(observation)))
    }

    private func requireRegularFileIfPresent() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 1_048_576 else {
            throw TaskSeenFailure.storage
        }
    }

    private func read() throws -> Saved {
        try requireRegularFileIfPresent()
        let data = try Data(contentsOf: file)
        guard data.count <= 1_048_576 else { throw TaskSeenFailure.storage }
        let value = try JSONDecoder().decode(Saved.self, from: data)
        guard value.version == 1, value.account == scope.account, value.phone == scope.phone,
              value.receipts.count <= 4096 else { throw TaskSeenFailure.storage }
        return value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum TaskSeenFailure: Error { case invalid, storage }
}
