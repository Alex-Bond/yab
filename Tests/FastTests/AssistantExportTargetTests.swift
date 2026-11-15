import Foundation
import Testing
@testable import Fast

/// Inert identifiers only: no registered assistant, Browser, Store or transport.
struct AssistantExportTargetTests {
    private func check(_ request: [String: Any], denied: Set<String> = [], seen: inout [String]) -> String? {
        AssistantBoundary.targetRefusal(request, find: { $0["id"] as? String }, refusal: { id in
            seen.append(id)
            return denied.contains(id) ? "denied: \(id)" : nil
        })
    }

    @Test func everyExplicitExportMemberMeetsThePolicy() {
        var seen: [String] = []
        let request: [String: Any] = ["do": "agent-pdf", "id": "home", "tabs": ["home", "other"]]
        #expect(check(request, denied: ["other"], seen: &seen) == "denied: other")
        #expect(seen == ["home", "other"])
        seen = []
        #expect(check(request, seen: &seen) == nil)
        #expect(seen == ["home", "other"])
    }

    @Test func explicitListOutranksTheSingleID() {
        var seen: [String] = []
        let request: [String: Any] = ["do": "agent-pdf", "id": "blocked", "tabs": ["", "allowed"]]
        #expect(check(request, denied: ["blocked"], seen: &seen) == nil)
        #expect(seen == ["allowed"])
    }

    @Test func emptyListsAndOtherVerbsKeepTheirSingleTarget() {
        let requests: [[String: Any]] = [
            ["do": "agent-pdf", "id": "home"],
            ["do": "agent-pdf", "id": "home", "tabs": [""]],
            ["do": "snapshot", "id": "home", "tabs": ["other"]]
        ]
        for request in requests {
            var seen: [String] = []
            #expect(check(request, denied: ["home"], seen: &seen) == "denied: home")
            #expect(seen == ["home"])
        }
    }

    @Test func everyPolicyDenialStopsBeforeALaterTarget() {
        for denied in ["other-space", "private", "other-agent", "site-denied"] {
            var seen: [String] = []
            let request: [String: Any] = ["do": "agent-pdf", "id": "home", "tabs": ["home", denied, "later"]]
            #expect(check(request, denied: [denied], seen: &seen) == "denied: \(denied)")
            #expect(seen == ["home", denied])
        }
    }
}
