import Foundation
import CryptoKit
import Testing
import YabCoreClient

/// Controlled transport/typed-frame tests only, not actual CEF capture proof.
struct ChromiumNativeGroupSnapshotTests {
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func encoded(_ row: [String: JSONValue]) throws -> Data { try JSONEncoder().encode(JSONValue.object(row)) }
    private func observation(_ command: NativeGroupApprovalCommand, native: [String: JSONValue], snapshot: [String: JSONValue]? = nil) throws -> NativeGroupApprovalObservation {
        var row: [String: JSONValue] = ["version": .number(1), "command": .string(command.id), "action": .string(command.action.rawValue), "transaction": .string(command.transaction),
            "status": .string("observed"), "resultSource": .string("native"), "nativeAcknowledged": .bool(true), "currentOriginalsVerified": .bool(true), "operationCurrent": .bool(true),
            "helperOwner": .string("original-owner"), "nativeTransaction": .string("native-transaction"), "members": .array([.object(["tab": .string("a"), "profile": .string("private-a"), "document": .string("native-doc"), "browserId": .number(11)])]),
            "nativeReceipt": .object(native), "commitAvailable": .bool(false), "nativeAtomicSwitchCommit": .bool(false)]
        if let snapshot { row["snapshot"] = .object(snapshot) }
        guard case .observed(let result) = command.outcome(.object(row)) else { Issue.record("Controlled original observation rejected"); throw Failure.fixture }
        return result
    }
    private enum Failure: Error { case fixture }
    private func fixture(padding: Int = 0) throws -> (NativeGroupApprovalCommand, NativeGroupApprovalObservation, Data, [String: JSONValue]) {
        let member = try #require(NativeGroupApprovalMember(tab: "a", profile: "private-a", document: "native-doc"))
        let reserve = try #require(NativeGroupApprovalCommand.reserve(transaction: "client-transaction", members: [member], coordinator: "a", id: "reserve-command"))
        let nativeMember: JSONValue = .object(["browserId": .number(11), "document": .string("native-doc"), "request": .string("native-request"), "token": .string("native-token"), "approvalDecided": .bool(true), "originalDestroyed": .bool(false), "nativeDestroyed": .bool(false)])
        var native: [String: JSONValue] = ["version": .number(1), "command": .string(reserve.id), "action": .string("reserve"), "owner": .string("original-owner"),
            "transaction": .string("native-transaction"), "group": .string("native-group"), "recoveryToken": .string("native-recovery"), "members": .array([nativeMember]),
            "phase": .string("reserved"), "outcome": .string("pending"), "complete": .bool(false), "irreversible": .bool(false), "processOwned": .bool(true), "clientAttached": .bool(true),
            "ownedPauseReleased": .bool(false), "exclusiveNativeApprovals": .bool(true), "commitAvailable": .bool(false), "nativeAtomicSwitchCommit": .bool(false),
            "closed": .array([]), "retained": .array([]), "unknown": .array([.number(11)])]
        let original = try observation(reserve, native: native)
        let capture = try #require(NativeGroupApprovalCommand.followup(.capture, original: original, id: "capture-command"))
        native["command"] = .string(capture.id); native["action"] = .string("capture"); native["phase"] = .string("captured")
        native["primitiveAccepted"] = .bool(true); native["seal"] = .string("native-seal"); native["snapshot"] = .string("native-snapshot"); native["frameCount"] = .number(1)
        let frame: [String: JSONValue] = ["browserId": .number(11), "processId": .number(21), "routingId": .number(31), "document": .string("native-doc"), "main": .bool(true)]
        var fullFrame = frame; fullFrame["url"] = .string("https://native.test/")
        fullFrame["state"] = .object(["url": .string("https://native.test/"), "local": .array([.array([.string("original"), .string(String(repeating: "x", count: padding))])]),
            "session": .null, "x": .number(3), "y": .number(7), "fields": .array([])])
        var full = native; full["frames"] = .array([.object(fullFrame)]); let payload = try encoded(full)
        let peer: [String: JSONValue] = ["helperPID": .number(1234), "helperBirthSec": .string("1700000000"), "helperBirthUsec": .number(123456), "connection": .string("original-peer"), "helperOwner": .string("original-owner")]
        var source = peer; source["version"] = .number(1); source["nativeTransaction"] = .string("native-transaction")
        for key in ["group", "recoveryToken", "seal", "snapshot"] { source[key] = native[key] }
        source["members"] = .array([.object(["tab": .string("a"), "profile": .string("private-a"), "document": .string("native-doc"), "browserId": .number(11)])]); source["frames"] = .array([.object(frame)])
        let identity = try encoded(source)
        var descriptor = source; descriptor["frames"] = nil
        descriptor["stream"] = .string("immutable-stream"); descriptor["transaction"] = .string(capture.transaction); descriptor["captureCommand"] = .string(capture.id)
        descriptor["source"] = .string(identity.base64EncodedString()); descriptor["sourceSHA256"] = .string(hash(identity)); descriptor["sha256"] = .string(hash(payload)); descriptor["total"] = .number(Double(payload.count))
        descriptor["maxChunk"] = .number(196608); descriptor["immutable"] = .bool(true); descriptor["partial"] = .bool(true); descriptor["commitAvailable"] = .bool(false); descriptor["nativeAtomicSwitchCommit"] = .bool(false)
        return (capture, try observation(capture, native: native, snapshot: descriptor), payload, peer)
    }
    @Test func multipleChunksReassembleOnlyExactNativeFrameAndFixedState() throws {
        let (_, original, payload, peer) = try fixture(padding: 200000)
        let descriptor = try #require(NativeGroupSnapshotDescriptor(original, sourceIdentity: peer)); var bytes = Data()
        while bytes.count < payload.count {
            let offset = bytes.count, count = min(196608, payload.count-offset), part = payload.subdata(in: offset..<offset+count)
            let row: JSONValue = .object(["descriptor": .object(descriptor.fields), "offset": .number(Double(offset)), "length": .number(Double(count)), "sha256": .string(hash(part)), "data": .string(part.base64EncodedString())])
            bytes.append(try #require(descriptor.chunk(row, offset: offset, length: count)))
        }
        let snapshot = try #require(descriptor.snapshot(bytes))
        #expect(snapshot.frames.count == 1 && snapshot.frames[0].identity["document"] == .string("native-doc"))
        #expect(snapshot.frames[0].state["session"] == .null && snapshot.bytes == payload)
        #expect(snapshot.descriptor.fields["partial"] == .bool(true) && snapshot.descriptor.fields["commitAvailable"] == .bool(false))
    }
    @Test func originalHelloBirthConnectionAndNoReplayAreRequired() throws {
        let (_, original, _, peer) = try fixture()
        for key in ["helperPID", "helperBirthSec", "helperBirthUsec", "connection", "helperOwner"] {
            var wrong = peer; wrong[key] = nil
            #expect(NativeGroupSnapshotDescriptor(original, sourceIdentity: wrong) == nil)
        }
        #expect(!NativeGroupSnapshotDescriptor.available(["nativeGroupSnapshots": .bool(true), "nativeGroupSnapshotVersion": .number(1)]))
    }
    @Test func incorrectChunkIdentityOffsetRangeOrHashCannotBecomeData() throws {
        let (_, original, payload, peer) = try fixture(); let descriptor = try #require(NativeGroupSnapshotDescriptor(original, sourceIdentity: peer))
        var row: [String: JSONValue] = ["descriptor": .object(descriptor.fields), "offset": .number(0), "length": .number(Double(payload.count)), "sha256": .string(hash(payload)), "data": .string(payload.base64EncodedString())]
        row["offset"] = .bool(false)
        #expect(descriptor.chunk(.object(row), offset: 0, length: payload.count) == nil)
        row["offset"] = .number(0); row["sha256"] = .string(String(repeating: "0", count: 64))
        #expect(descriptor.chunk(.object(row), offset: 0, length: payload.count) == nil)
        #expect(descriptor.parameters(offset: 0, length: 196609) == nil)
        #expect(descriptor.parameters(offset: payload.count, length: 1) == nil)
        #expect(descriptor.parameters(offset: 0, length: 0) == nil)
    }
    @Test func incompleteOrMutatedFinalPayloadNeverBecomesSnapshot() throws {
        let (_, original, payload, peer) = try fixture(); let descriptor = try #require(NativeGroupSnapshotDescriptor(original, sourceIdentity: peer))
        var mutated = payload; mutated[0] ^= 1
        #expect(descriptor.snapshot(mutated) == nil)
        #expect(descriptor.snapshot(Data(payload.dropLast())) == nil)
    }
    @Test func sameProcessInspectOwnerCanRecoverFrozenDescriptorWithoutNewCapture() throws {
        let (capture, original, _, peer) = try fixture()
        let inspect = try #require(NativeGroupApprovalCommand.inspectOwner(transaction: capture.transaction, members: capture.members, id: "inspection"))
        var native = original.native; native["command"] = nil; native["action"] = nil; native["primitiveAccepted"] = nil
        let discovered = try observation(inspect, native: native, snapshot: original.snapshot)
        #expect(NativeGroupSnapshotDescriptor(discovered, sourceIdentity: peer) != nil)
    }
}
