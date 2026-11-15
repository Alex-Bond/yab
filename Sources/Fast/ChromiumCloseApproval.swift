import Foundation
import YabCoreClient

/// A native engine decision, not the user's UI answer. The opaque token is
/// accepted only with the exact helper request and current batch owner.
struct ChromiumCloseApproval {
    let request: String
    let document: String
    let token: String
    let browserID: Int

    init?(_ value: JSONValue, owner: String) {
        guard !owner.isEmpty, value["version"] == .number(1),
              value["decision"] == .bool(true), value["allow"] == .bool(true),
              value["phase"] == .string("approved"), value["withdrawn"] != .bool(true),
              value["owner"] == .string(owner),
              let browser = value["browserId"].number, browser.isFinite,
              browser >= 1, browser <= Double(Int32.max), browser.rounded() == browser,
              let request = value["request"].string, !request.isEmpty, request.utf8.count <= 2048,
              let document = value["document"].string, !document.isEmpty, document.utf8.count <= 2048,
              let token = value["token"].string, !token.isEmpty, token.utf8.count <= 2048 else { return nil }
        self.request = request; self.document = document; self.token = token; browserID = Int(browser)
    }
}

/// Dispatch acceptance is never a closed receipt. Every requested endpoint
/// appears exactly once in the final closed/retained/unknown partition.
struct ChromiumCloseOutcome {
    let closed: Set<String>
    let retained: Set<String>
    let unknown: Set<String>
    let complete: Bool
    var allClosed: Bool { complete && retained.isEmpty && unknown.isEmpty }

    init?(_ value: JSONValue, requested: Set<String>) {
        func ids(_ key: String) -> Set<String>? {
            guard case .array(let rows) = value[key], rows.count <= 256 else { return nil }
            let strings = rows.compactMap(\.string)
            guard strings.count == rows.count, Set(strings).count == rows.count else { return nil }
            return Set(strings)
        }
        guard !requested.isEmpty, case .bool(let complete) = value["complete"],
              let closed = ids("closed"), let retained = ids("retained"), let unknown = ids("unknown"),
              closed.isDisjoint(with: retained), closed.isDisjoint(with: unknown), retained.isDisjoint(with: unknown),
              closed.union(retained).union(unknown) == requested,
              !complete || unknown.isEmpty else { return nil }
        self.closed = closed; self.retained = retained; self.unknown = unknown; self.complete = complete
    }
}
