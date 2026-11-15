import Testing
import YabCoreClient

/// Controlled adapter receipts only. No original native approval is created by
/// this suite; actual CEF cases and authenticated helper runtime remain required.
struct ChromiumNativeGroupApprovalAdapterTests {
    private func command() throws -> NativeGroupApprovalCommand {
        let a = try #require(NativeGroupApprovalMember(tab: "a", profile: "private-a", document: "native-doc-a"))
        let b = try #require(NativeGroupApprovalMember(tab: "b", profile: "shared-b", document: "native-doc-b"))
        return try #require(NativeGroupApprovalCommand.reserve(transaction: "client-correlation", members: [a, b], coordinator: "a", id: "original-command"))
    }
    private func reply(_ command: NativeGroupApprovalCommand) -> [String: JSONValue] {
        let mapping: [JSONValue] = command.members.enumerated().map { index, member in
            .object(["tab": .string(member.tab), "profile": .string(member.profile), "document": .string(member.document), "browserId": .number(Double(index + 11))])
        }
        let originals: [JSONValue] = command.members.enumerated().map { index, member in
            .object(["browserId": .number(Double(index + 11)), "document": .string(member.document), "request": .string("native-request-\(index)"),
                     "token": .string("native-token-\(index)"), "approvalDecided": .bool(true), "originalDestroyed": .bool(false), "nativeDestroyed": .bool(false)])
        }
        let native: [String: JSONValue] = ["version": .number(1), "command": .string(command.id), "action": .string(command.action.rawValue),
            "group": .string("native-group"), "recoveryToken": .string("native-recovery"),
            "owner": .string("original-helper-owner"), "transaction": .string("original-helper-transaction"), "members": .array(originals),
            "phase": .string("approved"), "outcome": .string("pending"), "complete": .bool(false), "processOwned": .bool(true), "clientAttached": .bool(true),
            "irreversible": .bool(false), "ownedPauseReleased": .bool(false), "exclusiveNativeApprovals": .bool(true), "commitAvailable": .bool(false),
            "nativeAtomicSwitchCommit": .bool(false), "closed": .array([]), "retained": .array([]), "unknown": .array([.number(11), .number(12)])]
        return ["version": .number(1), "command": .string(command.id), "action": .string(command.action.rawValue), "transaction": .string(command.transaction),
            "status": .string("observed"), "resultSource": .string("native"), "nativeAcknowledged": .bool(true), "currentOriginalsVerified": .bool(true),
            "operationCurrent": .bool(true), "helperOwner": .string("original-helper-owner"), "nativeTransaction": .string("original-helper-transaction"),
            "members": .array(mapping), "nativeReceipt": .object(native), "commitAvailable": .bool(false), "nativeAtomicSwitchCommit": .bool(false)]
    }
    private func observed(_ command: NativeGroupApprovalCommand, _ row: [String: JSONValue]) throws -> NativeGroupApprovalObservation {
        guard case .observed(let value) = command.outcome(.object(row)) else { Issue.record("Controlled exact adapter receipt was rejected"); throw Missing.controlledReceipt }
        return value
    }
    private enum Missing: Error { case controlledReceipt }

    @Test func missingOrWrongCapabilityCannotForwardAndOpaqueIdentifiersCannotAlias() throws {
        #expect(!NativeGroupApprovalCommand.available([:]))
        #expect(!NativeGroupApprovalCommand.available(["nativeClosePreflight": .bool(true)]))
        #expect(!NativeGroupApprovalCommand.available(["nativeGroupApprovals": .bool(true), "nativeGroupApprovalVersion": .bool(true)]))
        #expect(!NativeGroupApprovalCommand.available(["nativeGroupApprovals": .bool(true), "nativeGroupApprovalVersion": .number(1)]))
        #expect(NativeGroupApprovalCommand.available(["nativeGroupApprovals": .bool(true), "nativeGroupApprovalVersion": .number(1), "nativeGroupOwnerVersion": .number(1)]))
        #expect(NativeGroupApprovalMember(tab: "a\0alias", profile: "p", document: "d") == nil)
        let original = try command()
        #expect(NativeGroupApprovalCommand.reserve(members: original.members, coordinator: "foreign") == nil)
        #expect(NativeGroupApprovalCommand.reserve(members: [original.members[0], original.members[0]], coordinator: "a") == nil)
    }
    @Test func controlledOriginalNativeReceiptKeepsEveryMemberAndOpaqueReference() throws {
        let request = try command(), state = try observed(try command(), reply(try command()))
        #expect(state.exclusiveApprovalsObserved)
        #expect(state.members == request.members && state.native["commitAvailable"] == .bool(false))
        let next = try #require(NativeGroupApprovalCommand.followup(.prepare, original: state, id: "next-command"))
        #expect(next.parameters["group"] == .string(state.group) && next.parameters["recoveryToken"] == .string(state.recoveryToken))
        #expect(next.parameters["owner"] == nil && next.parameters["nativeOwner"] == nil)
        #expect(NativeGroupApprovalCommand.followup(.reserve, original: state) == nil)
        let discovery = try #require(NativeGroupApprovalCommand.inspectOwner(transaction: request.transaction, members: request.members))
        #expect(discovery.parameters["group"] == nil && discovery.parameters["recoveryToken"] == nil)
    }
    @Test func allEnvelopeAndNativeReferenceFieldsAreRequired() throws {
        let request = try command(), row = reply(try command())
        for key in ["command", "action", "transaction", "helperOwner", "nativeTransaction", "members", "nativeReceipt", "resultSource", "nativeAcknowledged", "operationCurrent", "currentOriginalsVerified"] {
            var missing = row; missing[key] = nil
            #expect(request.outcome(.object(missing)) == .unknown)
        }
        for key in ["command", "action", "owner", "transaction", "group", "recoveryToken", "exclusiveNativeApprovals", "commitAvailable", "members"] {
            var missing = row, native = try #require(row["nativeReceipt"]?.object); native[key] = nil; missing["nativeReceipt"] = .object(native)
            #expect(request.outcome(.object(missing)) == .unknown)
        }
    }
    @Test func memberDocumentBrowserAndProfileCannotRetargetTheOriginals() throws {
        let request = try command(), row = reply(try command())
        for field in ["document", "profile", "tab", "browserId"] {
            var bad = row
            let changed: [String: JSONValue] = ["tab": .string(field == "tab" ? "b" : "a"), "profile": .string(field == "profile" ? "foreign" : "private-a"),
                "document": .string(field == "document" ? "replacement" : "native-doc-a"), "browserId": field == "browserId" ? .bool(true) : .number(11)]
            bad["members"] = .array([.object(changed), .object(["tab": .string("b"), "profile": .string("shared-b"), "document": .string("native-doc-b"), "browserId": .number(12)])])
            #expect(request.outcome(.object(bad)) == .unknown)
        }
        var bad = row, native = try #require(row["nativeReceipt"]?.object)
        native["unknown"] = .array([.number(11), .number(11)]); bad["nativeReceipt"] = .object(native)
        #expect(request.outcome(.object(bad)) == .unknown)
    }
    @Test func helperTimeoutDispatchAndStaleCallbacksNeverBecomeApprovals() throws {
        let request = try command(), row = reply(try command())
        for source in ["helper-timeout", "native-dispatch-rejected", "", "helper-retired"] {
            var bad = row; bad["resultSource"] = .string(source)
            #expect(request.outcome(.object(bad)) == .unknown)
        }
        for key in ["operationCurrent", "currentOriginalsVerified"] {
            var stale = row; stale[key] = .bool(false)
            let state = try observed(request, stale)
            #expect(!state.exclusiveApprovalsObserved)
        }
        var noAck = row; noAck["nativeAcknowledged"] = .bool(false)
        #expect(request.outcome(.object(noAck)) == .unknown)
    }
    @Test func actualUnknownRemainsExplicitAndCannotMasqueradeAsRetained() throws {
        let request = try command(); var row = reply(request), native = try #require(row["nativeReceipt"]?.object)
        native["outcome"] = .string("unknown"); native["phase"] = .string("unknown"); row["nativeReceipt"] = .object(native)
        let unknown = try observed(request, row)
        #expect(unknown.native["outcome"] == .string("unknown") && !unknown.exclusiveApprovalsObserved)
        native["outcome"] = .string("retained"); row["nativeReceipt"] = .object(native)
        #expect(request.outcome(.object(row)) == .unknown)
    }
    @Test func copiedFollowupOwnerOrOversizeSnapshotCannotGainAuthority() throws {
        let original = try command(), state = try observed(try command(), reply(try command()))
        let next = try #require(NativeGroupApprovalCommand.followup(.inspect, original: state, id: "next-command"))
        var row = reply(next), native = try #require(row["nativeReceipt"]?.object)
        row["helperOwner"] = .string("copied-owner"); native["owner"] = .string("copied-owner"); row["nativeReceipt"] = .object(native)
        #expect(next.outcome(.object(row)) == .unknown)
        row = reply(original); native = try #require(row["nativeReceipt"]?.object); native["frames"] = .array([]); row["nativeReceipt"] = .object(native)
        #expect(original.outcome(.object(row)) == .unknown)
    }
}
