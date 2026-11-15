import Foundation
import Testing
@testable import YabCoreClient

/// Controlled decoder metadata only, not live process identity/native authority.
struct ChromiumNativeSourceProcessIdentityTests {
    private func source(incarnation: String, pid: Int, birth: String = "1000") -> JSONValue {
        .object(["version": .number(1), "launchIncarnation": .string(incarnation), "osPID": .number(Double(pid)),
            "pidVersion": .number(2), "birthSec": .string(birth), "birthUsec": .number(3),
            "boot": .string("01234567-89AB-4CDE-8123-456789ABCDEF"), "executable": .string("/controlled/Renderer"),
            "argvDigest": .string(String(repeating: "A", count: 64)), "argvDigestEncoding": .string("sha256-lengthdecimal-colon-arg-nul"),
            "codeUnique": .string(String(repeating: "B", count: 40)), "signingID": .string("controlled.renderer"),
            "auditDigest": .string(String(repeating: "C", count: 64)), "imageIdentityObservedAtAcquisition": .bool(true), "fullImageLease": .bool(false)])
    }
    private func tree(childLogical: Int, childSource: JSONValue) -> JSONValue {
        .object(["version": .number(1), "nativeSourcesVersion": .number(1), "nativeSourcesCurrentAtReply": .bool(true),
            "status": .string("observed"), "available": .bool(true), "fullImageLease": .bool(false), "commitAvailable": .bool(false),
            "nativeAtomicSwitchCommit": .bool(false), "sourceReceipt": .string("opaque-observation"),
            "nativeTreeSequence": .string("1"), "nativePhaseSequence": .string("1"), "nativeOperationSequence": .string("1"),
            "frames": .array([
                .object(["browserId": .number(1), "processId": .number(10), "routingId": .number(1),
                    "document": .string("main-doc"), "main": .bool(true), "nativeContext": .string("original-context"),
                    "originalProcess": source(incarnation: "first-native-rph", pid: 901)]),
                .object(["browserId": .number(1), "processId": .number(Double(childLogical)), "routingId": .number(2),
                    "document": .string("child-doc"), "main": .bool(false), "nativeContext": .string("original-context"),
                    "parentProcessId": .number(10), "parentRoutingId": .number(1), "originalProcess": childSource])])])
    }
    private var members: [NativeSwitchJournal.Member] { [.init(tab: "tab", profile: "profile", document: "main-doc", browser: 1)] }
    @Test func distinctNativeRPHInstancesCannotClaimOneOSBirth() {
        let sameBirth = tree(childLogical: 11, childSource: source(incarnation: "second-native-rph", pid: 901))
        #expect(NativeOriginalSourceMetadata.decodeMetadata(sameBirth, members: members) == nil)
        let conflictingBirth = tree(childLogical: 11, childSource: source(incarnation: "second-native-rph", pid: 901, birth: "1001"))
        #expect(NativeOriginalSourceMetadata.decodeMetadata(conflictingBirth, members: members) == nil)
    }
    @Test func sharedActualNativeProcessRemainsValidOnlyForSameLogicalInstance() throws {
        let shared = tree(childLogical: 10, childSource: source(incarnation: "first-native-rph", pid: 901))
        let decoded = try #require(NativeOriginalSourceMetadata.decodeMetadata(shared, members: members))
        #expect(decoded.frames.count == 2 && decoded.processes.count == 1 && decoded.processes.first?.osPID == 901)
        let distinct = tree(childLogical: 11, childSource: source(incarnation: "second-native-rph", pid: 902))
        #expect(NativeOriginalSourceMetadata.decodeMetadata(distinct, members: members)?.processes.count == 2)
    }
}
