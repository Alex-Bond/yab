import Foundation
import Testing
@testable import Fast

// Keep every use of McpRun's session context in the existing serialized
// suite, including tests in McpToolsTests.swift.
extension McpToolsTests {
    static func words(_ result: [String: Any]) -> String {
        (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    static func tool(_ name: String, _ input: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": "tab: t1"]], "isError": false]
    }

    @Test func pendingPromiseIsAnError() {
        let result = McpRun.run("await new Promise(() => {})", tool: Self.tool)
        #expect(result["isError"] as? Bool == true)
        #expect(Self.words(result).contains("unresolved promise"))
    }

    @Test func pendingPromiseCannotResumeOnNextRun() {
        _ = McpRun.run("keep.secret = 42; await new Promise(r => keep.resume = r); tab('t1').click('e1')", tool: Self.tool)
        var actions = 0
        let next = McpRun.run("if (keep.resume) keep.resume(); return typeof keep.secret") { _, _ in
            actions += 1
            return Self.tool("", [:])
        }
        #expect(next["isError"] as? Bool == false)
        #expect(Self.words(next).hasPrefix("undefined"))
        #expect(actions == 0)
    }

    @Test func awaitedToolsAndKeepStillWork() {
        let result = McpRun.run("keep.answer = 41; await tab('t1').click('e1'); return await Promise.resolve(keep.answer + 1)", tool: Self.tool)
        #expect(result["isError"] as? Bool == false)
        #expect(Self.words(result).hasPrefix("42"))
        let next = McpRun.run("return keep.answer", tool: Self.tool)
        #expect(Self.words(next).hasPrefix("41"))
    }

    @Test func failuresDoNotBecomeSuccess() {
        for code in ["throw new Error('bad step')", "await Promise.reject(new Error('bad step'))", "return )"] {
            let result = McpRun.run(code, tool: Self.tool)
            #expect(result["isError"] as? Bool == true)
        }
        #expect(McpRun.run("return 'ok'", tool: Self.tool)["isError"] as? Bool == false)
    }

    @Test func outputIsBoundedWhileLoggingAndResets() {
        let result = McpRun.run("for (let i=0;i<10000;i++) console.log('😀'.repeat(100))", outputLimit: 256, tool: Self.tool)
        let metadata = result["structuredContent"] as? [String: Any]
        #expect(metadata?["outputCharacters"] as? Int == 256)
        #expect(metadata?["truncated"] as? Bool == true)
        #expect(Self.words(result).count < 400)
        let next = McpRun.run("return 'ok'", outputLimit: 256, tool: Self.tool)
        #expect((next["structuredContent"] as? [String: Any])?["truncated"] as? Bool == false)
        #expect(Self.words(next).hasPrefix("ok"))
    }

    @Test func invalidBudgetDoesNotRunTools() {
        var actions = 0
        let result = McpRun.run("tab('t1').click('e1')", outputLimit: 0) { _, _ in actions += 1; return [:] }
        #expect(result["isError"] as? Bool == true)
        #expect(actions == 0)
    }

    @Test func errorsAlsoRespectOutputBudget() {
        let result = McpRun.run("console.log('x'.repeat(1000)); throw new Error('failure '.repeat(10000))", outputLimit: 256, tool: Self.tool)
        #expect(result["isError"] as? Bool == true)
        #expect(Self.words(result).hasPrefix("Error: failure"))
        #expect(Self.words(result).count < 400)
        #expect((result["structuredContent"] as? [String: Any])?["outputCharacters"] as? Int == 256)
    }

    @Test func toolBudgetAndApprovalErrorsRemain() {
        var actions = 0
        let result = McpRun.run("for(let i=0;i<500;i++) tab('t1').click('e1')") { _, _ in actions += 1; return Self.tool("", [:]) }
        #expect(result["isError"] as? Bool == true)
        #expect(actions == 200)
        let approval = McpRun.run("tab('t1').click('e1')") { _, _ in
            ["content": [["type": "text", "text": "status: needs_user"]], "isError": true]
        }
        #expect(approval["isError"] as? Bool == true)
        #expect(Self.words(approval).contains("status: needs_user"))
    }
}
