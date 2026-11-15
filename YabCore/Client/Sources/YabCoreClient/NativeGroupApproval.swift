import Foundation

private extension JSONValue {
    var groupArray: [JSONValue]? { if case .array(let values) = self { return values }; return nil }
    var groupBool: Bool? { if case .bool(let value) = self { return value }; return nil }
}

private func groupOpaque(_ value: String, maximum: Int = 256) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
}
private func groupBrowserID(_ value: JSONValue?) -> Int? {
    guard let number = value?.number, number.isFinite, number > 0, number <= Double(Int32.max), number.rounded(.towardZero) == number else { return nil }
    return Int(number)
}
public struct NativeGroupApprovalMember: Equatable, Sendable {
    public let tab, profile, document: String
    public init?(tab: String, profile: String, document: String) {
        guard [tab, profile, document].allSatisfy({ groupOpaque($0) }) else { return nil }
        self.tab = tab; self.profile = profile; self.document = document
    }
    var fields: JSONValue { .object(["tab": .string(tab), "profile": .string(profile), "document": .string(document)]) }
}

/// Native state observations only. No commit, snapshot or engine-switch authority.
public struct NativeGroupApprovalObservation: Sendable, Equatable {
    public let transaction, helperOwner, nativeTransaction, group, recoveryToken: String
    public let members: [NativeGroupApprovalMember]
    public let native: [String: JSONValue]
    public let currentOriginalsVerified, operationCurrent: Bool
    public let snapshot: [String: JSONValue]?
    public var exclusiveApprovalsObserved: Bool {
        currentOriginalsVerified && operationCurrent && native["phase"] == .string("approved") &&
        native["exclusiveNativeApprovals"] == .bool(true) && native["irreversible"] == .bool(false) &&
        native["outcome"] == .string("pending") && native["complete"] == .bool(false) && native["processOwned"] == .bool(true) &&
        native["clientAttached"] == .bool(true) && native["ownedPauseReleased"] == .bool(false) &&
        (native["members"]?.groupArray ?? []).allSatisfy {
            $0["approvalDecided"] == .bool(true) && $0["originalDestroyed"] == .bool(false) && $0["nativeDestroyed"] == .bool(false) &&
            groupOpaque($0["request"].string ?? "") && groupOpaque($0["token"].string ?? "")
        }
    }
}
public enum NativeGroupApprovalOutcome: Sendable, Equatable {
    case unavailable, unknown
    case observed(NativeGroupApprovalObservation)
}
public struct NativeGroupApprovalCommand: Sendable {
    public enum Action: String, Sendable {
        case reserve, prepare, drain, seal, capture, validate, inspect, inspectOwner = "inspect-owner", cancel, detach, retire
    }
    public let id, transaction: String
    public let action: Action
    public let members: [NativeGroupApprovalMember]
    private let coordinator: String?
    private let original: NativeGroupApprovalObservation?
    private init?(action: Action, transaction: String, members: [NativeGroupApprovalMember], coordinator: String?,
                  original: NativeGroupApprovalObservation?, id: String) {
        guard groupOpaque(id, maximum: 128), groupOpaque(transaction, maximum: 128), !members.isEmpty, members.count <= 256,
              Set(members.map(\.tab)).count == members.count else { return nil }
        self.id = id; self.transaction = transaction; self.action = action; self.members = members
        self.coordinator = coordinator; self.original = original
    }
    public static func reserve(transaction: String = UUID().uuidString.lowercased(), members: [NativeGroupApprovalMember],
                               coordinator: String, id: String = UUID().uuidString.lowercased()) -> Self? {
        guard members.contains(where: { $0.tab == coordinator }) else { return nil }
        return Self(action: .reserve, transaction: transaction, members: members, coordinator: coordinator, original: nil, id: id)
    }
    public static func inspectOwner(transaction: String, members: [NativeGroupApprovalMember],
                                    id: String = UUID().uuidString.lowercased()) -> Self? {
        Self(action: .inspectOwner, transaction: transaction, members: members, coordinator: nil, original: nil, id: id)
    }
    public static func followup(_ action: Action, original: NativeGroupApprovalObservation,
                               id: String = UUID().uuidString.lowercased()) -> Self? {
        guard action != .reserve else { return nil }
        return Self(action: action, transaction: original.transaction, members: original.members,
                    coordinator: nil, original: original, id: id)
    }
    public var parameters: [String: JSONValue] {
        var values: [String: JSONValue] = ["command": .string(id), "action": .string(action.rawValue),
            "transaction": .string(transaction), "members": .array(members.map(\.fields))]
        if let coordinator { values["coordinator"] = .string(coordinator) }
        if let original, action != .inspectOwner {
            values["group"] = .string(original.group); values["recoveryToken"] = .string(original.recoveryToken)
        }
        return values // Owner CEF object and native owner label are NEVER request parameters.
    }
    public static func available(_ hooks: [String: JSONValue]) -> Bool {
        hooks["nativeGroupApprovals"] == .bool(true) && hooks["nativeGroupApprovalVersion"] == .number(1) && hooks["nativeGroupOwnerVersion"] == .number(1)
    }
    public func outcome(_ value: JSONValue) -> NativeGroupApprovalOutcome {
        guard let row = value.object, row["version"] == .number(1), row["command"] == .string(id),
              row["action"] == .string(action.rawValue), row["transaction"] == .string(transaction),
              row["status"] == .string("observed"), row["resultSource"] == .string("native"),
              row["nativeAcknowledged"] == .bool(true), row["commitAvailable"] == .bool(false), row["nativeAtomicSwitchCommit"] == .bool(false),
              let owner = row["helperOwner"]?.string, groupOpaque(owner, maximum: 128),
              let nativeTransaction = row["nativeTransaction"]?.string, groupOpaque(nativeTransaction, maximum: 128),
              let current = row["currentOriginalsVerified"]?.groupBool, let operation = row["operationCurrent"]?.groupBool,
              let mapping = row["members"]?.groupArray, mapping.count == members.count,
              let native = row["nativeReceipt"]?.object, native["version"] == .number(1),
              native["owner"] == .string(owner), native["transaction"] == .string(nativeTransaction),
              native["exclusiveNativeApprovals"] == .bool(true), native["commitAvailable"] == .bool(false),
              native["nativeAtomicSwitchCommit"] == .bool(false), native["frames"] == nil, native["captures"] == nil,
              let group = native["group"]?.string, groupOpaque(group), let recovery = native["recoveryToken"]?.string, groupOpaque(recovery),
              let nativeMembers = native["members"]?.groupArray, nativeMembers.count == members.count else { return .unknown }
        if action != .inspectOwner {
            guard native["command"] == .string(id), native["action"] == .string(action.rawValue) else { return .unknown }
        }
        if let original {
            guard original.helperOwner == owner, original.nativeTransaction == nativeTransaction,
                  original.group == group, original.recoveryToken == recovery else { return .unknown }
        }
        var byBrowser: [Int: String] = [:], seen = Set<String>()
        for item in mapping {
            guard let tab = item["tab"].string, seen.insert(tab).inserted,
                  let original = members.first(where: { $0.tab == tab }), item["profile"] == .string(original.profile),
                  item["document"] == .string(original.document), let browser = groupBrowserID(item["browserId"]),
                  byBrowser[browser] == nil else { return .unknown }
            byBrowser[browser] = original.document
        }
        var nativeSeen = Set<Int>()
        for item in nativeMembers {
            guard let browser = groupBrowserID(item["browserId"]), nativeSeen.insert(browser).inserted,
                  let document = byBrowser[browser], item["document"] == .string(document),
                  item["approvalDecided"].groupBool != nil, item["originalDestroyed"].groupBool != nil,
                  item["nativeDestroyed"].groupBool != nil, item["request"].string != nil, item["token"].string != nil else { return .unknown }
        }
        var partition = Set<Int>()
        for key in ["closed", "retained", "unknown"] {
            guard let values = native[key]?.groupArray else { return .unknown }
            for item in values {
                guard let browser = groupBrowserID(item), byBrowser[browser] != nil, partition.insert(browser).inserted else { return .unknown }
            }
        }
        guard partition == Set(byBrowser.keys), native["complete"]?.groupBool != nil, native["irreversible"]?.groupBool != nil,
              native["clientAttached"]?.groupBool != nil, native["ownedPauseReleased"]?.groupBool != nil,
              let phase = native["phase"]?.string, groupOpaque(phase, maximum: 128),
              let outcome = native["outcome"]?.string, ["pending", "retained", "closed", "unknown"].contains(outcome),
              (native["processOwned"] == .bool(true) || (native["processOwned"] == .bool(false) && native["recoveryRetired"] == .bool(true))) else { return .unknown }
        if outcome == "unknown", native["complete"] != .bool(false) { return .unknown }
        if outcome == "pending", native["complete"] != .bool(false) { return .unknown }
        if outcome == "retained" {
            guard native["complete"] == .bool(true), native["phase"] == .string("retired"),
                  native["irreversible"] == .bool(false), native["ownedPauseReleased"] == .bool(true),
                  native["retained"]?.groupArray?.count == members.count,
                  native["closed"] == .array([]), native["unknown"] == .array([]),
                  nativeMembers.allSatisfy({ $0["originalDestroyed"] == .bool(false) && $0["nativeDestroyed"] == .bool(false) }) else { return .unknown }
        }
        if outcome == "closed" {
            guard native["complete"] == .bool(true), native["phase"] == .string("closed"),
                  native["closed"]?.groupArray?.count == members.count,
                  native["retained"] == .array([]), native["unknown"] == .array([]) else { return .unknown }
        }
        return .observed(NativeGroupApprovalObservation(transaction: transaction, helperOwner: owner, nativeTransaction: nativeTransaction,
            group: group, recoveryToken: recovery, members: members, native: native, currentOriginalsVerified: current, operationCurrent: operation, snapshot: row["snapshot"]?.object))
    }
}
extension YabCoreClient {
    public func nativeGroupApproval(_ command: NativeGroupApprovalCommand) async -> NativeGroupApprovalOutcome {
        guard await originalGroupReady(), NativeGroupApprovalCommand.available(nativeHooks) else { return .unavailable }
        if [.drain, .seal, .capture].contains(command.action), !NativeGroupSnapshotDescriptor.available(nativeHooks) { return .unavailable }
        do {
            // Native30s -> helper40s/45s request deadline -> client60s.
            return command.outcome(try await request("switch.group.native", params: command.parameters, timeout: 60))
        } catch { return .unknown } // No cancel, retry, recreate, retire or inferred retention.
    }
}
