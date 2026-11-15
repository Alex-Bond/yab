import Foundation

/// Original native renderer-stamped editing identity, never a JS/local-turn lease.
public struct NativeTextFocusIdentity: Equatable, Hashable, Sendable {
    public let focusToken, nativeDocument, frameId, nativeFocusEpoch, nativeFrameFocusEpoch: String
    public let node: Int
    public init?(_ state: [String: JSONValue]) {
        guard state["stateVersion"] == .number(1), state["focusIdentityVersion"] == .number(1),
              state["editable"] == .bool(true), state["cancelled"] != .bool(true),
              let token = state["focusToken"]?.string, Self.positive(token),
              let document = state["nativeDocument"]?.string, Self.opaque(document),
              let frame = state["frameId"]?.string, Self.opaque(frame),
              let epoch = state["nativeFocusEpoch"]?.string, Self.positive(epoch),
              let frameEpoch = state["nativeFrameFocusEpoch"]?.string, Self.positive(frameEpoch),
              let node = state["node"]?.number, node.isFinite, node.rounded(.towardZero) == node,
              node > 0, node <= Double(Int32.max) else { return nil }
        focusToken = token; nativeDocument = document; frameId = frame
        nativeFocusEpoch = epoch; nativeFrameFocusEpoch = frameEpoch; self.node = Int(node)
    }
    private static func opaque(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }
    private static func positive(_ value: String) -> Bool {
        opaque(value) && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && (UInt64(value) ?? 0) > 0
    }
    var fields: [String: JSONValue] {
        ["focusToken": .string(focusToken), "nativeDocument": .string(nativeDocument), "frameId": .string(frameId),
         "nativeFocusEpoch": .string(nativeFocusEpoch), "nativeFrameFocusEpoch": .string(nativeFrameFocusEpoch),
         "node": .number(Double(node))]
    }
}

public enum NativeTextInputOutcome: String, Equatable, Sendable { case applied, rejected, unknown, unavailable }
public struct NativeTextInputCommand: Equatable, Sendable {
    public enum Kind: String, Sendable { case compose, commit, unmark, cancel }
    public let identity: NativeTextFocusIdentity
    public let id: String
    private let kind: Kind
    private let text: String
    private let selectionStart, selectionEnd, replacementStart, replacementEnd: Int
    public init?(identity: NativeTextFocusIdentity, kind: Kind, text: String = "",
                 selectionStart: Int = 0, selectionEnd: Int = 0,
                 replacementStart: Int = -1, replacementEnd: Int = -1,
                 id: String = UUID().uuidString.lowercased()) {
        guard !id.isEmpty, id.utf8.count <= 128, text.utf16.count <= 65_536,
              selectionStart >= 0, selectionEnd >= selectionStart,
              selectionEnd <= (kind == .compose ? text.utf16.count : 0),
              (replacementStart == -1 && replacementEnd == -1) ||
                (replacementStart >= 0 && replacementEnd >= replacementStart && replacementEnd <= Int(Int32.max)),
              ![.unmark, .cancel].contains(kind) ||
                (text.isEmpty && replacementStart == -1 && replacementEnd == -1) else { return nil }
        self.identity = identity; self.kind = kind; self.text = text; self.id = id
        self.selectionStart = selectionStart; self.selectionEnd = selectionEnd
        self.replacementStart = replacementStart; self.replacementEnd = replacementEnd
    }
    public var parameters: [String: JSONValue] {
        identity.fields.merging(["command": .string(id), "kind": .string(kind.rawValue), "text": .string(text),
            "selectionStart": .number(Double(selectionStart)), "selectionEnd": .number(Double(selectionEnd)),
            "replacementStart": .number(Double(replacementStart)), "replacementEnd": .number(Double(replacementEnd))]) { _, value in value }
    }
    public func outcome(_ result: JSONValue, tab: String, profile: String) -> NativeTextInputOutcome {
        guard let row = result.object, row["version"] == .number(1), row["tab"] == .string(tab),
              row["profile"] == .string(profile), let browser = row["browserId"]?.number,
              browser.isFinite, browser > 0, browser.rounded(.towardZero) == browser,
              row["text"] == nil else { return .unknown }
        for (key, value) in parameters where key != "text" {
            guard row[key] == value else { return .unknown }
        }
        switch row["status"]?.string {
        case "applied":
            return row["nativeAcknowledged"] == .bool(true) && row["resultSource"] == .string("native") ? .applied : .unknown
        case "rejected":
            let native = row["nativeAcknowledged"] == .bool(true) && row["resultSource"] == .string("native")
            let beforeEffect = row["nativeAcknowledged"] == .bool(false) && row["resultSource"] == .string("native-dispatch-rejected")
            return native || beforeEffect ? .rejected : .unknown
        default: return .unknown
        }
    }
    public static func available(_ hooks: [String: JSONValue]) -> Bool {
        hooks["nativeTextFocus"] == .bool(true) && hooks["nativeTextFocusVersion"] == .number(1)
    }
}

struct NativeTextInputEndpoint: Hashable, Sendable {
    let tab, profile: String
    let focus: NativeTextFocusIdentity
}

/// Per-connection quarantine. Old uncertain identities are never evicted to
/// make room for new ones. Exhaustion disables forwarding on this client.
public struct NativeTextInputUncertainty: Sendable {
    private var endpoints = Set<NativeTextInputEndpoint>()
    private let limit: Int
    public private(set) var exhausted = false
    public var count: Int { endpoints.count }
    public init(limit: Int = 256) { self.limit = max(1, min(limit, 256)) }
    public func permits(tab: String, profile: String, focus: NativeTextFocusIdentity) -> Bool {
        !exhausted && !endpoints.contains(NativeTextInputEndpoint(tab: tab, profile: profile, focus: focus))
    }
    public mutating func recordUnknown(tab: String, profile: String, focus: NativeTextFocusIdentity) {
        guard !exhausted else { return }
        endpoints.insert(NativeTextInputEndpoint(tab: tab, profile: profile, focus: focus))
        if endpoints.count >= limit { exhausted = true }
    }
}

extension YabCoreClient {
    /// One original client/helper connection, exact native command and terminal
    /// ACK. No cancellation handler discards the accepted command's final ACK.
    public func sendNativeTextInput(tab: String, profile: String,
                                    command: NativeTextInputCommand) async -> NativeTextInputOutcome {
        guard NativeTextInputCommand.available(nativeHooks) else { return .unavailable }
        let endpoint = NativeTextInputEndpoint(tab: tab, profile: profile, focus: command.identity)
        if !nativeTextUncertain.permits(tab: tab, profile: profile, focus: command.identity) { return .unknown }
        guard !Task.isCancelled, !tab.isEmpty, tab.utf8.count <= 128,
              !profile.isEmpty, profile.utf8.count <= 128,
              !nativeTextInFlight.contains(endpoint) else { return .rejected }
        nativeTextInFlight.insert(endpoint)
        defer { nativeTextInFlight.remove(endpoint) }
        var params = command.parameters; params["tab"] = .string(tab); params["profile"] = .string(profile)
        // An unstructured operation consumes the original reply even when its
        // caller is canceled after dispatch. It never retries or reconnects.
        let operation = Task { try await self.request("input.text.native", params: params, timeout: 15) }
        let outcome: NativeTextInputOutcome
        do { outcome = command.outcome(try await operation.value, tab: tab, profile: profile) }
        catch { outcome = .unknown }
        if outcome == .unknown { nativeTextUncertain.recordUnknown(tab: tab, profile: profile, focus: command.identity) }
        return outcome
    }
}
