import Foundation
import SyncKit
import Testing
@testable import Fast

struct SyncChatAgentTests {
    private func words(_ fields: [String: Value]) -> SyncChats.Words? {
        let base: [String: Value] = ["device": "mac", "text": "Owned test question", "at": .number(1_800_000_000)]
        var input = base.merging(fields) { _, b in b }
        if fields["text"] == .null { input.removeValue(forKey: "text") }
        return SyncChats.waiting([Record(collection: "send", id: "request", fields: input)], device: "mac").first
    }

    @Test func eachExplicitAgentReachesTheStartHandlerWithStrictSelection() throws {
        for agent in ChatAgent.allCases {
            let request = try #require(words(["kind": "agent", "cli": .string(agent.rawValue), "text": .null,
                                               "agentText": "Owned test question"]))
            var calls: [(String, String?, Bool)] = []
            let result = SyncChats.startAgent(request) { text, cli, strict in
                calls.append((text, cli, strict)); return "started"
            }
            #expect(result.reason == nil && result.made == "a:started")
            #expect(calls.count == 1)
            #expect(calls.first?.0 == "Owned test question")
            #expect(calls.first?.1 == agent.rawValue && calls.first?.2 == true)
        }
    }

    @Test func absentOrTombstonedAgentPreservesLegacyMacDefaultWithoutStrictSelection() throws {
        // Record's getter treats .null as deletion, not a present malformed value.
        let cases: [[String: Value]] = [[:], ["cli": .null]]
        for fields in cases {
            let request = try #require(words(fields))
            #expect(request.kind == "agent" && request.cli == nil && !request.invalidAgent)
            var calls = 0
            let result = SyncChats.startAgent(request) { _, cli, strict in
                #expect(cli == nil && !strict); calls += 1; return "legacy"
            }
            #expect(calls == 1 && result.made == "a:legacy")
        }
    }

    @Test func unknownAndMalformedAgentsNeverReachTheHandler() throws {
        for field in [Value.string("other"), .string(""), .bool(true), .number(1), .array(["claude"])] {
            let request = try #require(words(["kind": "agent", "cli": field]))
            #expect(request.invalidAgent)
            var calls = 0
            let result = SyncChats.startAgent(request) { _, _, _ in calls += 1; return "wrong" }
            #expect(result.reason == ChatAgent.invalid && result.made == nil && calls == 0)
        }
    }

    @Test func agentSelectionCannotRebindAnExistingChatOrAnswerAChoice() throws {
        let cases: [[String: Value]] = [
            ["kind": "agent", "cli": "codex", "chat": "a:existing"],
            ["kind": "code", "cli": "codex", "project": "known"],
            ["kind": "agent", "cli": "codex", "chat": "c:existing", "choice": .number(0)]
        ]
        for fields in cases {
            let request = try #require(words(fields))
            var calls = 0
            let result = SyncChats.startAgent(request) { _, _, _ in calls += 1; return "wrong" }
            #expect(result.reason == ChatAgent.invalid && calls == 0)
        }
    }

    @Test func explicitEnvelopeCannotDispatchThroughARolledBackParserWithAStaleCapability() throws {
        // This is the previous parser's executable selection guard, not a mock success.
        func legacyWaiting(_ records: [Record]) -> [String] {
            records.filter { $0.alive() && $0["device"]?.string == "mac" && $0["state"] == nil }.compactMap { record in
                let text = record["text"]?.string ?? ""
                let field = record["choice"]
                let choice = SyncChoice.index(field)
                let invalidChoice = field != nil && choice == nil
                guard !text.isEmpty || choice != nil || invalidChoice else { return nil }
                return text
            }
        }
        let staleCapability = Record(collection: OpenOnMac.capability, id: "mac",
                                     fields: ["device": "mac", "chatAgent": .number(1)])
        #expect(ChatAgent.supports(staleCapability, device: "mac"))
        let request = Record(collection: "send", id: "request", fields: [
            "device": "mac", "kind": "agent", "cli": "codex", "agentText": "Owned test question",
            "question": "Owned human question", "clientChat": "local", "at": .number(1_800_000_000)
        ])
        var oldDispatches = 0
        for _ in legacyWaiting([request]) { oldDispatches += 1 }
        #expect(oldDispatches == 0)
        let accepted = try #require(SyncChats.waiting([request], device: "mac").first)
        var calls = 0
        let result = SyncChats.startAgent(accepted) { text, cli, strict in
            #expect(text == "Owned test question" && cli == "codex" && strict)
            calls += 1; return "selected"
        }
        #expect(calls == 1 && result.made == "a:selected")
        #expect(request["state"] == nil, "a rollback leaves the send pending, never falsely taken")
    }

    @Test func malformedOrMixedExplicitEnvelopesAreRefusedBeforeDispatch() throws {
        let base: [String: Value] = ["device": "mac", "kind": "agent", "cli": "codex",
                                    "agentText": "Owned test question", "at": .number(1_800_000_000)]
        let cases: [[String: Value]] = [
            ["agentText": .number(1)], ["agentText": .string("")], ["agentText": .null],
            ["text": "Mixed legacy question"], ["chat": "a:existing"], ["choice": .number(0)],
            ["kind": "code"], ["project": "known"], ["cli": .string("other")], ["cli": .null]
        ]
        for fields in cases {
            let record = Record(collection: "send", id: "request", fields: base.merging(fields) { _, b in b })
            let request = try #require(SyncChats.waiting([record], device: "mac").first)
            #expect(request.invalidAgent)
            var calls = 0
            let result = SyncChats.startAgent(request) { _, _, _ in calls += 1; return "wrong" }
            #expect(result.reason == ChatAgent.invalid && calls == 0)
        }
        var missingCLI = base
        missingCLI.removeValue(forKey: "cli")
        let request = try #require(SyncChats.waiting([Record(collection: "send", id: "request", fields: missingCLI)], device: "mac").first)
        #expect(request.invalidAgent)
        var calls = 0
        let result = SyncChats.startAgent(request) { _, _, _ in calls += 1; return "wrong" }
        #expect(result.reason == ChatAgent.invalid && calls == 0)
    }

    @Test func legacyContinuationAndCodePayloadsRemainOrdinaryTextWithoutAgentSelection() throws {
        let cases: [[String: Value]] = [["chat": "a:existing"], ["chat": "c:existing"],
                                         ["kind": "code", "project": "known"]]
        for fields in cases {
            let request = try #require(words(fields))
            #expect(request.text == "Owned test question" && request.cli == nil && !request.invalidAgent)
        }
    }

    @Test func capabilityMustBeLiveAndBelongToTheRequestedDevice() throws {
        let journal = try Journal(path: nil, device: "mac")
        let record = try journal.change(.init(collection: OpenOnMac.capability, id: "mac"),
                                        ["device": "mac", "chatAgent": .number(1), "open": .number(1), "chatMetadata": .number(1)])
        #expect(ChatAgent.supports(record, device: "mac"))
        #expect(!ChatAgent.supports(record, device: "other"))
        #expect(!ChatAgent.supports(Record(collection: "other", id: "mac", fields: record.visible), device: "mac"))
        let old = try journal.change(record.key, ["chatAgent": .null])
        #expect(!ChatAgent.supports(old, device: "mac"))
        #expect(OpenOnMac.supports(old, device: "mac") && ChatMetadata.supports(old, device: "mac"))
        try journal.remove(record.key)
        #expect(!ChatAgent.supports(journal.record(record.key), device: "mac"))
    }
}
