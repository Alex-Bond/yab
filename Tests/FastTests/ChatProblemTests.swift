import Foundation
import Testing
@testable import Fast

struct ChatProblemTests {
    // The exact error recorded in the production Investor help chat.
    static let unsupported = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."}}"#

    @Test func productionModelErrorHasUsefulRecovery() {
        let problem = ChatProblem(Self.unsupported, agent: "ChatGPT")
        #expect(problem.kind == .modelUnavailable)
        #expect(problem.status == 400)
        #expect(problem.code == "HTTP 400 · MODEL_UNAVAILABLE")
        #expect(problem.providerCode == "invalid_request_error")
        #expect(problem.recovery == .model)
        #expect(problem.action == "Choose Model")
        #expect(problem.diagnostics.contains("gpt-6.1-sol"))
        #expect(!problem.diagnostics.contains("{\""))
    }

    @Test func jsonInsideRpcErrorIsUnwrapped() throws {
        let data = try JSONSerialization.data(withJSONObject: ["code": -32603, "message": Self.unsupported])
        let problem = ChatProblem(String(decoding: data, as: UTF8.self), agent: "ChatGPT")
        #expect(problem.kind == .modelUnavailable)
        #expect(problem.status == 400)
        #expect(problem.providerCode == "invalid_request_error")
    }

    @Test func claudePrefixAndPrettyJsonRetainHttpStatus() {
        let raw = """
        API Error: 401 {"type": "error", "error": {
          "type": "authentication_error", "message": "Your token has expired"
        }, "request_id": "req_test"}
        """
        let problem = ChatProblem(raw, agent: "Claude")
        #expect(problem.kind == .signIn)
        #expect(problem.status == 401)
        #expect(problem.recovery == .account)
        #expect(problem.message == "Your token has expired")
    }

    @Test func rateLimitAndExhaustedPlanNeedDifferentActions() {
        let rate = ChatProblem(#"{"status":429,"error":{"code":"rate_limit_exceeded","message":"Slow down"}}"#, agent: "ChatGPT")
        let quota = ChatProblem(#"{"status":429,"error":{"code":"insufficient_quota","message":"Check your plan"}}"#, agent: "ChatGPT")
        #expect(rate.kind == .rateLimit)
        #expect(rate.recovery == .retry)
        #expect(quota.kind == .quota)
        #expect(quota.recovery == .account)
    }

    @Test func statusOnlyEnvelopesAreRecognized() {
        #expect(ChatProblem(#"{"status":503,"error":{"type":"overloaded_error"}}"#, agent: "Claude").kind == .service)
        #expect(ChatProblem(#"{"status":403,"error":{}}"#, agent: "Claude").kind == .access)
        #expect(ChatProblem(#"{"status":400,"error":{}}"#, agent: "Claude").kind == .invalidRequest)
    }

    @Test func plainAndNestedNetworkErrorsCanRetry() {
        for raw in ["network connection dropped", "HTTP 408: request timed out", #"{"error":{"message":"ECONNRESET"}}"#] {
            let problem = ChatProblem(raw, agent: "ChatGPT")
            #expect(problem.kind == .network)
            #expect(problem.recovery == .retry)
        }
    }

    @Test(arguments: ["authentication failed or timed out",
                      "Error: authentication required. Run 'agy' to log in, then retry.",
                      "Antigravity CLI requires Google sign-in.", "You are not signed in."])
    func geminiAuthenticationFailureIsNotAConnectionTimeout(raw: String) {
        let problem = ChatProblem(raw, agent: "Gemini")
        #expect(problem.kind == .signIn)
        #expect(problem.recovery == .account)
        #expect(problem.action == "Open AI Settings")
        #expect(problem.title == "Sign in to Gemini again")
        #expect(problem.diagnostics == raw)
    }

    @Test func modelAccessErrorTakesPrecedenceOverGenericForbidden() {
        let problem = ChatProblem(#"{"status":403,"error":{"code":"model_not_found","message":"No access"}}"#, agent: "ChatGPT")
        #expect(problem.kind == .modelUnavailable)
        #expect(problem.recovery == .model)
    }

    @Test func unknownAndMalformedErrorsNeverBecomeJsonCopy() {
        for raw in ["{broken JSON", #"{"error":{}}"#, "something odd"] {
            let problem = ChatProblem(raw, agent: "ChatGPT")
            #expect(problem.kind == .unknown)
            #expect(!problem.title.contains("{"))
            #expect(!problem.detail.contains("{"))
            #expect(!problem.diagnostics.contains("{"))
        }
    }

    @Test func codesCannotInjectLongProviderTextIntoCard() {
        let problem = ChatProblem(#"{"error":{"code":"bad code with spaces and\nnewlines","message":"Oops"}}"#, agent: "ChatGPT")
        #expect(problem.providerCode == nil)
        #expect(problem.code == "AGENT_ERROR")
    }

    @Test func generalHttpErrorDoesNotSuggestBlindRetry() {
        let problem = ChatProblem("HTTP status 422: invalid effort", agent: "ChatGPT")
        #expect(problem.status == 422)
        #expect(problem.kind == .invalidRequest)
        #expect(problem.recovery == .account)
    }

    @Test func messageOnlyLimitsAndStopsStillWork() {
        #expect(ChatProblem("You've hit your weekly limit", agent: "ChatGPT").kind == .quota)
        #expect(ChatProblem("Claude Code stopped (1).", agent: "Claude Code").kind == .stopped)
        #expect(ChatProblem("", agent: "ChatGPT").kind == .stopped)
    }

    @Test func aCrashSaysWhyOnTheCard() {
        let crash = ChatProblem("Error: the session file is locked by another process", agent: "Claude")
        #expect(crash.kind == .unknown)
        #expect(crash.detail == "Claude said: \u{201C}The session file is locked by another process.\u{201D} You can try again to continue this chat.")
        // Yab's own words for a stop, a stack's line, an envelope and nothing say nothing more.
        for raw in ["Claude Code stopped (1).", "    at Object.<anonymous> (/opt/cli.js:12:3)", #"{"error":{"message":"x"}}"#, ""] {
            #expect(ChatProblem(raw, agent: "Claude").detail == "You can try again to continue this chat.")
        }
    }
}
