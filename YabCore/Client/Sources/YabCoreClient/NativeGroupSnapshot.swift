import Foundation
import CryptoKit

private extension JSONValue {
    var snapshotArray: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var snapshotBool: Bool? { if case .bool(let value) = self { return value }; return nil }
}
private func snapshotInt(_ value: JSONValue?, minimum: Int = 0, maximum: Int = Int(Int32.max)) -> Int? {
    guard let number = value?.number, number.isFinite, number.rounded(.towardZero) == number,
          number >= Double(minimum), number <= Double(maximum) else { return nil }
    return Int(number)
}
private func snapshotHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func snapshotDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
private let sourceKeys = ["helperPID", "helperBirthSec", "helperBirthUsec", "connection", "helperOwner", "nativeTransaction", "group", "recoveryToken", "seal", "snapshot", "members"]
private let frameKeys = ["browserId", "processId", "routingId", "document", "main", "parentProcessId", "parentRoutingId"]

/// Immutable transport identity for one real native callback. This is a partial
/// frozen source observation, never current commit/mutation/storage/WK authority.
public struct NativeGroupSnapshotDescriptor: Equatable, Sendable {
    public static let maximumBytes = 16 * 1024 * 1024, maximumChunk = 196608
    public let fields: [String: JSONValue]
    public let total: Int
    public let digest: String
    let source: [String: JSONValue]
    public static func available(_ hooks: [String: JSONValue]) -> Bool {
        NativeGroupApprovalCommand.available(hooks) && hooks["nativeGroupSnapshots"] == .bool(true) && hooks["nativeGroupSnapshotVersion"] == .number(1)
    }
    public init?(_ original: NativeGroupApprovalObservation, sourceIdentity: [String: JSONValue]) {
        guard original.currentOriginalsVerified, original.operationCurrent,
              original.native["phase"] == .string("captured"),
              let fields = original.snapshot, fields["version"] == .number(1), fields["transaction"] == .string(original.transaction),
              fields["helperOwner"] == .string(original.helperOwner), fields["nativeTransaction"] == .string(original.nativeTransaction),
              fields["group"] == .string(original.group), fields["recoveryToken"] == .string(original.recoveryToken),
              fields["seal"] == original.native["seal"], fields["snapshot"] == original.native["snapshot"],
              let captureCommand = fields["captureCommand"]?.string, !captureCommand.isEmpty, captureCommand.utf8.count <= 128,
              let stream = fields["stream"]?.string, !stream.isEmpty, stream.utf8.count <= 128,
              let total = snapshotInt(fields["total"], minimum: 1, maximum: Self.maximumBytes),
              fields["maxChunk"] == .number(Double(Self.maximumChunk)), fields["immutable"] == .bool(true), fields["partial"] == .bool(true),
              fields["commitAvailable"] == .bool(false), fields["nativeAtomicSwitchCommit"] == .bool(false),
              snapshotInt(fields["helperPID"], minimum: 1) != nil,
              let birth = fields["helperBirthSec"]?.string, !birth.isEmpty, birth.utf8.allSatisfy({ (48...57).contains($0) }), (UInt64(birth) ?? 0) > 0,
              snapshotInt(fields["helperBirthUsec"], maximum: 999999) != nil,
              let connection = fields["connection"]?.string, !connection.isEmpty, connection.utf8.count <= 128,
              let digest = fields["sha256"]?.string, snapshotDigest(digest),
              let sourceDigest = fields["sourceSHA256"]?.string, snapshotDigest(sourceDigest),
              let encoded = fields["source"]?.string, encoded.utf8.count <= 1024 * 1024,
              let sourceData = Data(base64Encoded: encoded), sourceData.base64EncodedString() == encoded, snapshotHash(sourceData) == sourceDigest,
              let source = (try? JSONDecoder().decode(JSONValue.self, from: sourceData))?.object, source["version"] == .number(1),
              let mapping = source["members"]?.snapshotArray, mapping.count == original.members.count,
              let topology = source["frames"]?.snapshotArray, !topology.isEmpty, topology.count <= 512 else { return nil }
        for key in sourceKeys { guard source[key] == fields[key] else { return nil } }
        if original.native["action"] == .string("capture") {
            guard original.native["primitiveAccepted"] == .bool(true), fields["captureCommand"] == original.native["command"] else { return nil }
        }
        for key in ["helperPID", "helperBirthSec", "helperBirthUsec", "connection", "helperOwner"] {
            guard fields[key] == sourceIdentity[key] else { return nil }
        }
        var seen = Set<String>(), browsers: [Int: String] = [:]
        for row in mapping {
            guard let tab = row["tab"].string, seen.insert(tab).inserted,
                  let expected = original.members.first(where: { $0.tab == tab }), row["profile"] == .string(expected.profile), row["document"] == .string(expected.document),
                  let browser = snapshotInt(row["browserId"], minimum: 1), browsers[browser] == nil else { return nil }
            browsers[browser] = expected.document
        }
        guard snapshotTopology(topology, browsers: browsers) else { return nil }
        self.fields = fields; self.total = total; self.digest = digest; self.source = source
    }
    public func parameters(offset: Int, length: Int) -> [String: JSONValue]? {
        guard offset >= 0, offset < total, length > 0, length <= Self.maximumChunk, length <= total - offset else { return nil }
        return ["descriptor": .object(fields), "offset": .number(Double(offset)), "length": .number(Double(length))]
    }
    public func chunk(_ response: JSONValue, offset: Int, length: Int) -> Data? {
        guard parameters(offset: offset, length: length) != nil, response["descriptor"] == .object(fields),
              response["offset"] == .number(Double(offset)), response["length"] == .number(Double(length)),
              let text = response["data"].string, text.utf8.count <= ((Self.maximumChunk + 2) / 3) * 4,
              let data = Data(base64Encoded: text), data.count == length, data.base64EncodedString() == text,
              response["sha256"] == .string(snapshotHash(data)) else { return nil }
        return data
    }
    public func snapshot(_ bytes: Data) -> NativeGroupFrozenSnapshot? {
        guard bytes.count == total, snapshotHash(bytes) == digest,
              let native = (try? JSONDecoder().decode(JSONValue.self, from: bytes))?.object,
              native["version"] == .number(1), native["action"] == .string("capture"), native["command"] == fields["captureCommand"],
              native["owner"] == source["helperOwner"], native["transaction"] == source["nativeTransaction"],
              native["group"] == source["group"], native["recoveryToken"] == source["recoveryToken"],
              native["seal"] == source["seal"], native["snapshot"] == source["snapshot"], native["phase"] == .string("captured"),
              native["primitiveAccepted"] == .bool(true), native["exclusiveNativeApprovals"] == .bool(true),
              native["outcome"] == .string("pending"), native["complete"] == .bool(false), native["irreversible"] == .bool(false),
              native["processOwned"] == .bool(true), native["clientAttached"] == .bool(true),
              native["commitAvailable"] == .bool(false), native["nativeAtomicSwitchCommit"] == .bool(false),
              let frames = native["frames"]?.snapshotArray, let topology = source["frames"]?.snapshotArray,
              frames.count == topology.count, native["frameCount"] == .number(Double(frames.count)),
              let primary = source["members"]?.snapshotArray else { return nil }
        var browsers: [Int: String] = [:]
        for row in primary { if let browser = snapshotInt(row["browserId"], minimum: 1), let doc = row["document"].string { browsers[browser] = doc } }
        guard let nativeMembers = native["members"]?.snapshotArray, nativeMembers.count == browsers.count else { return nil }
        var memberSeen = Set<Int>()
        for member in nativeMembers {
            guard let browser = snapshotInt(member["browserId"], minimum: 1), memberSeen.insert(browser).inserted,
                  let doc = browsers[browser], member["document"] == .string(doc) else { return nil }
        }
        guard snapshotTopology(frames, browsers: browsers) else { return nil }
        let byIdentity = Dictionary(uniqueKeysWithValues: topology.map { (snapshotFrameKey($0), $0.object ?? [:]) })
        var decoded: [NativeGroupFrozenFrame] = []
        for frame in frames {
            guard let original = byIdentity[snapshotFrameKey(frame)], let state = frame["state"].object,
                  let url = frame["url"].string, state["url"] == .string(url), snapshotState(state) else { return nil }
            for key in frameKeys { guard frame[key] == (original[key] ?? .null) else { return nil } }
            decoded.append(NativeGroupFrozenFrame(identity: original, state: state))
        }
        return NativeGroupFrozenSnapshot(descriptor: self, bytes: bytes, frames: decoded)
    }
}

public struct NativeGroupFrozenFrame: Equatable, Sendable {
    public let identity, state: [String: JSONValue]
}
public struct NativeGroupFrozenSnapshot: Equatable, Sendable {
    public let descriptor: NativeGroupSnapshotDescriptor
    public let bytes: Data
    public let frames: [NativeGroupFrozenFrame]
}
public enum NativeGroupSnapshotOutcome: Equatable, Sendable {
    case unavailable, unknown
    case frozen(NativeGroupFrozenSnapshot)
}
private func snapshotFrameKey(_ frame: JSONValue) -> String { "\(frame["processId"].number ?? -1):\(frame["routingId"].number ?? -1)" }
private func snapshotTopology(_ frames: [JSONValue], browsers: [Int: String]) -> Bool {
    var seen = Set<String>(), mains = Set<Int>(), parents: [String: String] = [:], owners: [String: Int] = [:]
    for frame in frames {
        guard snapshotInt(frame["processId"], minimum: 1) != nil, snapshotInt(frame["routingId"], minimum: 1) != nil,
              let browser = snapshotInt(frame["browserId"], minimum: 1), let expected = browsers[browser],
              let document = frame["document"].string, !document.isEmpty, document.utf8.count <= 256,
              let main = frame["main"].snapshotBool, seen.insert(snapshotFrameKey(frame)).inserted else { return false }
        let key = snapshotFrameKey(frame); owners[key] = browser
        if main {
            guard document == expected, mains.insert(browser).inserted, frame["parentProcessId"] == .null, frame["parentRoutingId"] == .null else { return false }
        } else {
            guard let process = snapshotInt(frame["parentProcessId"], minimum: 1), let route = snapshotInt(frame["parentRoutingId"], minimum: 1) else { return false }
            parents[key] = "\(Double(process)):\(Double(route))"
        }
    }
    guard mains.count == browsers.count else { return false }
    for (key, _) in parents {
        var at = key, chain = Set<String>()
        while let parent = parents[at] {
            guard chain.insert(at).inserted, seen.contains(parent), owners[parent] == owners[key] else { return false }
            at = parent
        }
    }
    return true
}
private func snapshotState(_ state: [String: JSONValue]) -> Bool {
    for key in ["local", "session"] {
        guard let value = state[key] else { return false }
        if value == .null { continue }
        guard let entries = value.snapshotArray, entries.count <= 4096 else { return false }
        var keys = Set<String>()
        for row in entries {
            guard let pair = row.snapshotArray, pair.count == 2, let key = pair[0].string, pair[1].string != nil, keys.insert(key).inserted else { return false }
        }
    }
    guard let fields = state["fields"]?.snapshotArray, fields.count <= 4096,
          let x = state["x"]?.number, x.isFinite, let y = state["y"]?.number, y.isFinite else { return false }
    var indices = Set<Int>()
    for field in fields {
        guard let index = snapshotInt(field["index"], maximum: 4095), indices.insert(index).inserted,
              let tag = field["tag"].string, ["INPUT", "TEXTAREA", "SELECT"].contains(tag), let type = field["type"].string,
              !["password", "file", "hidden"].contains(type.lowercased()), field["id"].string != nil, field["name"].string != nil,
              field["value"].string != nil, field["checked"].snapshotBool != nil else { return false }
        guard field.object?["selected"] != nil else { return false }
        if tag == "SELECT" {
            guard let selected = field["selected"].snapshotArray, selected.count <= 4096 else { return false }
            var options = Set<Int>()
            for item in selected { guard let option = snapshotInt(item, maximum: 4095), options.insert(option).inserted else { return false } }
        } else if field["selected"] != .null { return false }
    }
    return true
}
extension YabCoreClient {
    public func nativeGroupSnapshot(_ descriptor: NativeGroupSnapshotDescriptor) async -> NativeGroupSnapshotOutcome {
        guard await originalGroupReady(), NativeGroupSnapshotDescriptor.available(nativeHooks) else { return .unavailable }
        for key in ["helperPID", "helperBirthSec", "helperBirthUsec", "connection", "helperOwner"] {
            guard descriptor.fields[key] == nativeGroupSource[key] else { return .unknown }
        }
        var data = Data(); data.reserveCapacity(descriptor.total)
        do {
            while data.count < descriptor.total {
                let offset = data.count, length = min(NativeGroupSnapshotDescriptor.maximumChunk, descriptor.total - offset)
                guard let parameters = descriptor.parameters(offset: offset, length: length) else { return .unknown }
                let response = try await request("switch.group.snapshot.read", params: parameters, timeout: 30)
                guard let bytes = descriptor.chunk(response, offset: offset, length: length) else { return .unknown }
                data.append(bytes)
            }
            guard let frozen = descriptor.snapshot(data) else { return .unknown }
            return .frozen(frozen)
        } catch { return .unknown } // No retry, reconnect, cancel, retire or source release.
    }
}
