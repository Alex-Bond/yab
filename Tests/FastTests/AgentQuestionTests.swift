import Foundation
import Testing
@testable import Fast

// What a chat waits on: read from the tool it wants to use, answered on the wire as
// Claude Code and Codex read it. No CLI, no window.
@MainActor
struct AgentQuestionTests {
    static let question: [String: Any] = [
        "questions": [
            ["question": "Build on this Mac?", "header": "Where to build?", "multiSelect": false,
             "options": [["label": "Build here", "description": "--host main"], ["label": "Wait for the queue", "description": "farm queue"]]],
            ["question": "Which checks?", "header": "Checks", "multiSelect": true,
             "options": [["label": "Unit", "description": ""], ["label": "Eval", "description": ""]]],
        ],
    ]

    // MARK: - answers on the wire

    @Test func questionAnswersGoInTheInput() throws {
        let response = AgentQuestion.response(.answers(["Build on this Mac?": ["Build here"], "Which checks?": ["Unit", "Eval"]]),
                                        input: Self.question, suggestions: nil)
        #expect(response["behavior"] as? String == "allow")
        let input = try #require(response["updatedInput"] as? [String: Any])
        #expect((input["questions"] as? [Any])?.count == 2)
        #expect(input["answers"] as? [String: String] == ["Build on this Mac?": "Build here", "Which checks?": "Unit, Eval"])
    }

    @Test func modesAndRulesAndNo() throws {
        let input: [String: Any] = ["command": "./farm build"]
        let rules: [Any] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "./farm build:*"]], "behavior": "allow", "destination": "session"]]
        let always = AgentQuestion.response(.always, input: input, suggestions: rules)
        #expect((always["updatedPermissions"] as? [Any])?.count == 1)
        #expect(AgentQuestion.response(.allow, input: input, suggestions: rules)["updatedPermissions"] == nil)

        let edits = AgentQuestion.response(.mode("acceptEdits"), input: input, suggestions: nil)
        let update = try #require((edits["updatedPermissions"] as? [[String: Any]])?.first)
        #expect(update["type"] as? String == "setMode")
        #expect(update["mode"] as? String == "acceptEdits")
        #expect(update["destination"] as? String == "session")

        #expect(AgentQuestion.response(.deny(nil), input: input, suggestions: nil)["message"] as? String == AgentQuestion.denied)
        #expect(AgentQuestion.response(.deny("use adhd"), input: input, suggestions: nil)["message"] as? String == "use adhd")
        #expect(AgentQuestion.ours("default") == "manual")
    }

    @Test func codexAnswersByQuestionID() throws {
        let questions = AgentQuestion.questions([["id": "q1", "header": "Where", "question": "Where to build?", "isOther": true,
                                            "options": [["label": "Here", "description": "main"]]]])
        let answers = AgentQuestion.codexAnswers(["Where to build?": ["Here"]], questions: questions)
        #expect((answers["q1"] as? [String: Any])?["answers"] as? [String] == ["Here"])

        let (server, wire) = CodexServerTests.opened()
        server.asks = true
        _ = CodexServerTests.ready(server, wire)
        let heard = server.heard(["id": 9, "method": "item/tool/requestUserInput",
                                  "params": ["threadId": "T1", "turnId": "u", "itemId": "i", "questions": [["id": "q1", "question": "Where to build?"]]]])
        guard case .asked(9, let params) = heard.first else { Issue.record("not asked"); return }
        #expect(AgentQuestion.questions(params["questions"]).first?.id == "q1")
        server.reply(9, answers: answers)
        #expect(wire.last["id"] as? Int == 9)
        let result = try #require(wire.last["result"] as? [String: Any])
        #expect(((result["answers"] as? [String: Any])?["q1"] as? [String: Any])?["answers"] as? [String] == ["Here"])
    }
}
