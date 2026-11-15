import Foundation
import Testing
@testable import YabCoreClient

/// Controlled METADATA decoder tests. No CEF helper/task right/native phase
/// exists here. Actual native producer and signed counterpart acceptance NOT_RUN.
struct ChromiumNativeOriginalSourcesTests {
    private var members: [NativeSwitchJournal.Member] { [.init(tab: "tab", profile: "profile", document: "main-doc", browser: 12)] }
    private func process(pid: Int = 901, incarnation: String = "original-process") -> JSONValue {
        .object(["version": .number(1), "launchIncarnation": .string(incarnation), "osPID": .number(Double(pid)), "pidVersion": .number(3),
            "birthSec": .string("1000"), "birthUsec": .number(1), "boot": .string("01234567-89AB-4CDE-8123-456789ABCDEF"),
            "executable": .string("/fixture/Renderer"), "argvDigest": .string(String(repeating: "A", count: 64)),
            "argvDigestEncoding": .string("sha256-lengthdecimal-colon-arg-nul"), "codeUnique": .string(String(repeating: "B", count: 40)),
            "signingID": .string("fixture.renderer"), "auditDigest": .string(String(repeating: "C", count: 64)),
            "imageIdentityObservedAtAcquisition": .bool(true), "fullImageLease": .bool(false)])
    }
    private func fixture() -> JSONValue {
        let root: JSONValue = .object(["browserId": .number(12), "processId": .number(7), "routingId": .number(1),
            "document": .string("main-doc"), "nativeContext": .string("original-context"), "main": .bool(true), "originalProcess": process()])
        let child: JSONValue = .object(["browserId": .number(12), "processId": .number(8), "routingId": .number(2),
            "document": .string("child-doc"), "nativeContext": .string("original-context"), "main": .bool(false),
            "parentProcessId": .number(7), "parentRoutingId": .number(1), "originalProcess": process(pid: 902, incarnation: "original-child-process")])
        return .object(["version": .number(1), "nativeSourcesVersion": .number(1), "nativeSourcesCurrentAtReply": .bool(true),
            "status": .string("observed"), "available": .bool(true), "fullImageLease": .bool(false),
            "commitAvailable": .bool(false), "nativeAtomicSwitchCommit": .bool(false), "sourceReceipt": .string("native-opaque-source"),
            "nativeTreeSequence": .string("1"), "nativePhaseSequence": .string("2"), "nativeOperationSequence": .string("18446744073709551615"),
            "frames": .array([root, child])])
    }
    private func changing(_ value: JSONValue, _ key: String, _ replacement: JSONValue) -> JSONValue {
        var object = value.object ?? [:]; object[key] = replacement; return .object(object)
    }
    private func frameChange(_ value: JSONValue, index: Int = 1, key: String, value replacement: JSONValue) -> JSONValue {
        guard case .array(var frames) = value["frames"] else { return .null }
        frames[index] = changing(frames[index], key, replacement)
        return changing(value, "frames", .array(frames))
    }
    @Test func exactWholeTreeMetadataPreservesDistinctLogicalAndOSProcesses() throws {
        let value = fixture(), decoded = try #require(NativeOriginalSourceMetadata.decodeMetadata(value, members: members))
        #expect(decoded.frames.count == 2 && decoded.processes.count == 2)
        #expect(decoded.frames[0].processId == 7 && decoded.frames[0].originalProcess.osPID == 901)
        #expect(decoded.frames[1].parentProcessId == 7 && decoded.frames[1].originalProcess.osPID == 902)
        #expect(decoded.operationSequence == "18446744073709551615" && decoded.frameTreeSHA256.count == 64)
        guard case .array(let frames) = value["frames"] else { Issue.record("Missing controlled frame fixture"); return }
        let reordered = changing(value, "frames", .array(Array(frames.reversed())))
        #expect(NativeOriginalSourceMetadata.decodeMetadata(reordered, members: members) == decoded)
    }
    @Test func missingMainForeignDocumentCycleAndCrossBrowserTreeAreRefused() {
        let value = fixture()
        for changed in [frameChange(value, index: 0, key: "document", value: .string("replacement-doc")),
                        frameChange(value, key: "parentRoutingId", value: .number(999)),
                        frameChange(value, key: "parentProcessId", value: .number(8)),
                        frameChange(frameChange(value, key: "parentProcessId", value: .number(8)), key: "parentRoutingId", value: .number(2)),
                        frameChange(value, key: "browserId", value: .number(13)),
                        frameChange(value, key: "nativeContext", value: .string("foreign-context")),
                        frameChange(value, index: 0, key: "main", value: .bool(false))] {
            #expect(NativeOriginalSourceMetadata.decodeMetadata(changed, members: members) == nil)
        }
    }
    @Test func sourceFlagsAndCanonicalSequencesCannotBeReplacedByLabels() {
        let value = fixture()
        for (key, replacement) in [("nativeSourcesCurrentAtReply", JSONValue.bool(false)), ("fullImageLease", .bool(true)),
                                   ("nativeSourcesVersion", .bool(true)), ("nativeTreeSequence", .number(1)),
                                   ("nativeTreeSequence", .string("01")), ("nativePhaseSequence", .string("0")),
                                   ("nativeOperationSequence", .string("18446744073709551616")),
                                   ("commitAvailable", .bool(true)), ("sourceReceipt", .string(""))] {
            let changed = changing(value, key, replacement)
            #expect(NativeOriginalSourceMetadata.decodeMetadata(changed, members: members) == nil)
        }
    }
    @Test func nativeProcessReadGapsBirthAndAuditMetadataAreRequiredWithoutPIDFallback() {
        let value = fixture()
        for (key, replacement) in [("pidVersion", JSONValue.string("3")), ("birthSec", .string("01000")), ("birthUsec", .number(1000000)),
                                   ("osPID", .number(-1)), ("argvDigestEncoding", .string("caller-json")),
                                   ("imageIdentityObservedAtAcquisition", .bool(false)), ("auditDigest", .string("")),
                                   ("launchIncarnation", .string("")), ("codeUnique", .string("x")), ("executable", .string("relative"))] {
            let source = changing(process(pid: 902, incarnation: "original-child-process"), key, replacement)
            let changed = frameChange(value, key: "originalProcess", value: source)
            #expect(NativeOriginalSourceMetadata.decodeMetadata(changed, members: members) == nil)
        }
        let absent = frameChange(value, key: "originalProcess", value: .null)
        #expect(NativeOriginalSourceMetadata.decodeMetadata(absent, members: members) == nil)
    }
    @Test func quotaRefusesWholeAndNeverTruncatesExtraFrames() {
        let value = fixture()
        let over = changing(value, "frames", .array(Array(repeating: .null, count: 4097)))
        #expect(NativeOriginalSourceMetadata.decodeMetadata(over, members: members) == nil)
        let duplicate = frameChange(value, key: "processId", value: .number(7))
        #expect(NativeOriginalSourceMetadata.decodeMetadata(duplicate, members: members) == nil) // Same logical source, different actual process metadata.
        #expect(NativeOriginalSourcesPolicy.version == 0 && NativeOriginalSourcesPolicy.helperCodeDirectories.isEmpty)
    }
}
