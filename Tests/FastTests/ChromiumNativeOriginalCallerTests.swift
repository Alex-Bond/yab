import Foundation
import Darwin
import Testing
@testable import YabCoreClient

/// Controlled parser/nonce negatives only. Never creates the accepted
/// counterpart, inherited kernel channel or native CEF ownership.
struct ChromiumNativeOriginalCallerTests {
    private let clientNonce = "01234567-89ab-4cde-8123-456789abcdef"
    private let helperNonce = "11234567-89ab-4cde-8123-456789abcdef"
    private func evidence(_ pid: Int32) -> NativePeerIdentity.Evidence {
        .init(pid: pid, parent: 10, uid: getuid(), startSec: 1000, startUsec: 1, executable: "/controlled/\(pid)", argvSHA256: String(repeating: "a", count: 64),
              bootSession: "01234567-89AB-4CDE-8123-456789ABCDEF", auditSHA256: String(repeating: "b", count: 64), codeIdentifier: "controlled", codeUnique: String(repeating: "c", count: 40))
    }
    private func fields(_ value: NativePeerIdentity.Evidence) -> JSONValue {
        .object(["pid": .number(Double(value.pid)), "parent": .number(Double(value.parent)), "uid": .number(Double(value.uid)), "startSec": .string(String(value.startSec)),
                 "startUsec": .number(Double(value.startUsec)), "executable": .string(value.executable), "argvSHA256": .string(value.argvSHA256), "bootSession": .string(value.bootSession),
                 "auditSHA256": .string(value.auditSHA256), "codeIdentifier": .string(value.codeIdentifier), "codeUnique": .string(value.codeUnique)])
    }
    private func hello() -> [String: JSONValue] {
        ["nativeOriginalCaller": .object(["version": .number(1), "status": .string("observed"), "acceptedVersion": .number(1), "clientNonce": .string(clientNonce), "helperNonce": .string(helperNonce),
            "initialParent": fields(evidence(123)), "caller": fields(evidence(123)), "helper": fields(evidence(124)), "factoryOwner": .string("original-factory"), "groupConnection": .string("original-connection")]),
         "nativeGroupSource": .object(["helperOwner": .string("original-factory"), "connection": .string("original-connection")]),
         "nativeHooks": .object(["nativeOriginalCallerAuthenticated": .bool(true), "nativeOriginalCallerVersion": .number(1)])]
    }
    @Test func controlledPairMatchesOnlyCompleteExactMetadata() {
        let pair = NativePeerIdentity.checkedCallerPair(.object(hello()), caller: evidence(123), helper: evidence(124), clientNonce: clientNonce)
        #expect(pair?.nonce == helperNonce && pair?.owner == "original-factory")
    }
    @Test func actualCallerAndInitialParentAuditBirthCodeAndArgvCannotDiffer() throws {
        for section in ["initialParent", "caller", "helper"] {
            for field in ["pid", "parent", "uid", "startSec", "startUsec", "executable", "argvSHA256", "bootSession", "auditSHA256", "codeIdentifier", "codeUnique"] {
                var h = hello(), proof = try #require(h["nativeOriginalCaller"]?.object)
                var row = try #require(proof[section]?.object); row[field] = .null; proof[section] = .object(row); h["nativeOriginalCaller"] = .object(proof)
                #expect(NativePeerIdentity.checkedCallerPair(.object(h), caller: evidence(123), helper: evidence(124), clientNonce: clientNonce) == nil)
            }
        }
    }
    @Test func staleOrMalformedNoncesFactoryOrConnectionCannotCreatePair() throws {
        for key in ["clientNonce", "helperNonce", "factoryOwner", "groupConnection"] {
            var h = hello(), proof = try #require(h["nativeOriginalCaller"]?.object); proof[key] = .string("wrong-or-stale"); h["nativeOriginalCaller"] = .object(proof)
            #expect(NativePeerIdentity.checkedCallerPair(.object(h), caller: evidence(123), helper: evidence(124), clientNonce: clientNonce) == nil)
        }
        #expect(NativePeerIdentity.checkedCallerPair(.object(hello()), caller: evidence(123), helper: evidence(124), clientNonce: helperNonce) == nil)
    }
    @Test func callerBoolOrUnacceptedDiagnosticReceiptIsNotAcceptedMetadata() throws {
        for replacement in [JSONValue.bool(true), .number(0), .number(2)] {
            var h = hello(), proof = try #require(h["nativeOriginalCaller"]?.object); proof["acceptedVersion"] = replacement; h["nativeOriginalCaller"] = .object(proof)
            #expect(NativePeerIdentity.checkedCallerPair(.object(h), caller: evidence(123), helper: evidence(124), clientNonce: clientNonce) == nil)
        }
        var h = hello(); h["nativeHooks"] = .object(["nativeOriginalCallerAuthenticated": .bool(true), "nativeOriginalCallerVersion": .bool(true)])
        #expect(NativePeerIdentity.checkedCallerPair(.object(h), caller: evidence(123), helper: evidence(124), clientNonce: clientNonce) == nil)
    }
}

// These are launch-policy/Objective-C setter-safety controls, not a native
// original-helper positive. The compiled accepted policy intentionally stays0.
private final class OriginalCallerUntouchedProcess: Process, @unchecked Sendable {
    var reads = 0, writes = 0
    var fixturePID: Int32 = 0
    override var processIdentifier: Int32 { reads += 1; return fixturePID }
    override var isRunning: Bool { reads += 1; return false }
    override var standardInput: Any? {
        get { reads += 1; return nil }
        set { writes += 1 }
    }
    override var executableURL: URL? {
        get { reads += 1; return nil }
        set { writes += 1 }
    }
}
@Suite("Original caller disabled policy")
struct ChromiumNativeOriginalCallerPolicyTests {
    @Test func disabledPolicyDoesNoOptionalProcessOrCodeWork() {
        let process = OriginalCallerUntouchedProcess()
        let beforeReads = process.reads, beforeWrites = process.writes
        #expect(NativePeerIdentity.prepareLaunch(process) == nil)
        #expect(process.reads == beforeReads && process.writes == beforeWrites)
    }
    @Test func alreadyUsedTaskIsRejectedBeforeStdinGetterOrSetter() {
        let process = OriginalCallerUntouchedProcess(); process.fixturePID = 42
        let beforeReads = process.reads, beforeWrites = process.writes
        #expect(!NativePeerIdentity.canConfigureOriginalBootstrap(process))
        #expect(process.reads == beforeReads + 1 && process.writes == beforeWrites)
    }
    @Test func realCustomInputRemainsOwnedByItsCaller() {
        let process = Process(), pipe = Pipe(); process.standardInput = pipe
        #expect(!NativePeerIdentity.canConfigureOriginalBootstrap(process))
        #expect(NativePeerIdentity.prepareLaunch(process) == nil)
        #expect((process.standardInput as? Pipe) === pipe)
        let fresh = Process()
        let actual = fresh.standardInput
        print("ORIGINAL_CALLER_DEFAULT_STDIN nil=\(actual == nil) standard=\((actual as? FileHandle) === FileHandle.standardInput)")
        // Observation only: no assumption the framework getter is always nil.
    }
}
