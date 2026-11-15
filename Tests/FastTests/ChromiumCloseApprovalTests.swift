import Testing
import YabCoreClient
@testable import Fast

struct ChromiumCloseApprovalTests {
    private var receipt: [String: JSONValue] {
        ["version": .number(1), "decision": .bool(true), "allow": .bool(true),
         "phase": .string("approved"), "owner": .string("batch"), "browserId": .number(4),
         "request": .string("native-request"), "document": .string("native-document-tree"),
         "token": .string("opaque-native-approval")]
    }
    @Test func onlyAnExactNativeApprovalAuthorizesCommit() {
        let approval = ChromiumCloseApproval(.object(receipt), owner: "batch")
        #expect(approval?.request == "native-request")
        #expect(approval?.document == "native-document-tree")
        #expect(approval?.token == "opaque-native-approval")
        #expect(approval?.browserID == 4)
        #expect(ChromiumCloseApproval(.object(receipt), owner: "another-batch") == nil)
    }
    @Test func stayWithdrawalAndMalformedReceiptsCannotAuthorizeCommit() {
        let invalid: [(String, JSONValue)] = [
            ("version", .number(2)), ("decision", .bool(false)), ("allow", .bool(false)),
            ("phase", .string("retired")), ("withdrawn", .bool(true)),
            ("browserId", .number(0)), ("browserId", .number(1.5)),
            ("request", .string("")), ("document", .string("")), ("token", .string("")),
            ("token", .string(String(repeating: "x", count: 2049)))
        ]
        for (key, value) in invalid {
            var input = receipt; input[key] = value
            #expect(ChromiumCloseApproval(.object(input), owner: "batch") == nil, "Rejected \(key)")
        }
    }

    @Test func dispatchAcceptanceIsNeverAClosedDocumentReceipt() {
        #expect(ChromiumCloseOutcome(.object(["committed": .bool(true), "count": .number(1)]), requested: ["a"]) == nil)
        let closed: JSONValue = .object(["complete": .bool(true), "closed": .array([.string("a")]),
                                       "retained": .array([]), "unknown": .array([])])
        #expect(ChromiumCloseOutcome(closed, requested: ["a"])?.allClosed == true)
    }

    @Test func retainedOrUnknownDocumentsMustKeepTheirRows() {
        let mixed: JSONValue = .object(["complete": .bool(true), "closed": .array([.string("a")]),
                                      "retained": .array([.string("b")]), "unknown": .array([])])
        let outcome = ChromiumCloseOutcome(mixed, requested: ["a", "b"])
        #expect(outcome?.allClosed == false && outcome?.closed == ["a"] && outcome?.retained == ["b"])
        let timeout: JSONValue = .object(["complete": .bool(false), "closed": .array([]),
                                        "retained": .array([]), "unknown": .array([.string("a")])])
        #expect(ChromiumCloseOutcome(timeout, requested: ["a"])?.allClosed == false)
    }

    @Test func duplicatedForeignOrMissingEndpointsInvalidateTheFinalReceipt() {
        let invalid: [JSONValue] = [
            .object(["complete": .bool(true), "closed": .array([.string("a"), .string("a")]), "retained": .array([]), "unknown": .array([])]),
            .object(["complete": .bool(true), "closed": .array([.string("foreign")]), "retained": .array([]), "unknown": .array([])]),
            .object(["complete": .bool(true), "closed": .array([]), "retained": .array([]), "unknown": .array([])]),
            .object(["complete": .bool(true), "closed": .array([.string("a")]), "retained": .array([.string("a")]), "unknown": .array([])]),
            .object(["complete": .bool(true), "closed": .array([]), "retained": .array([]), "unknown": .array([.string("a")])])
        ]
        for value in invalid { #expect(ChromiumCloseOutcome(value, requested: ["a"]) == nil) }
    }
}
