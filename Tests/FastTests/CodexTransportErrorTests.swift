import Foundation
import Testing
@testable import Fast

/// A provider's structured HTTP status must reach recovery even when its
/// human message only describes the WebSocket/HTTPS transport failure.
@MainActor
struct CodexTransportErrorTests {
    private func server() -> (CodexServer, CodexServerTests.Wire) {
        let (server, wire) = CodexServerTests.opened()
        _ = CodexServerTests.ready(server, wire)
        return (server, wire)
    }

    private func error(_ variant: String = "httpConnectionFailed", status: Any = 401) -> [String: Any] {
        ["message": "WebSocket connection failed", "codexErrorInfo": [variant: ["httpStatusCode": status]],
         "additionalDetails": "Authorization: Bearer fixture-secret; https://private.test/?key=fixture-secret"]
    }

    @Test func terminalTransportStatusSelectsAccountRecoveryWithoutRetrying() throws {
        for variant in ["httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts"] {
            let (server, wire) = server()
            let writes = wire.lines.count
            let events = server.heard(["method": "error", "params": ["threadId": "T1", "willRetry": false, "error": error(variant)]])
            guard case .failed(let message, false) = events.first else { Issue.record("No terminal error"); continue }
            let problem = ChatProblem(message, agent: "ChatGPT")
            #expect(problem.status == 401)
            #expect(problem.kind == .signIn)
            #expect(problem.recovery == .account)
            #expect(message.contains("WebSocket connection failed"))
            #expect(!message.contains("fixture-secret") && !message.contains("private.test"))
            #expect(wire.lines.count == writes)
        }
    }

    @Test func turnCompletionRetainsItsStructuredTransportStatus() {
        for (status, expected) in [(401, ChatProblem.Kind.signIn), (403, .access), (429, .rateLimit), (503, .service)] {
            let (server, wire) = server()
            let writes = wire.lines.count
            let events = server.heard(["method": "turn/completed", "params": ["threadId": "T1", "turn": ["id": "U1", "status": "failed", "error": error(status: status)]]])
            guard case .turnEnded("failed", let message?) = events.first else { Issue.record("No turn error"); continue }
            let problem = ChatProblem(message, agent: "ChatGPT")
            #expect(problem.status == status)
            #expect(problem.kind == expected)
            #expect(wire.lines.count == writes)
        }
    }

    @Test func temporaryTransportFailureDoesNotBecomeAnExtraRetry() {
        let (server, wire) = server()
        let writes = wire.lines.count
        #expect(server.heard(["method": "error", "params": ["threadId": "T1", "willRetry": true, "error": error()]]).isEmpty)
        #expect(wire.lines.count == writes)
    }

    @Test func structuredUnauthorizedOutranksStatusAndModelWordsInsideTheMessage() {
        for message in [#"{"error":{"status":503,"message":"transport failed"}}"#,
                        #"{"error":{"code":"model_not_found","message":"model not available"}}"#] {
            let (server, wire) = server()
            let writes = wire.lines.count
            var raw = error()
            raw["message"] = message
            let events = server.heard(["method": "error", "params": ["willRetry": false, "error": raw]])
            guard case .failed(let text, false) = events.first else { Issue.record("No error"); continue }
            let problem = ChatProblem(text, agent: "ChatGPT")
            #expect(problem.status == 401)
            #expect(problem.kind == .signIn)
            #expect(problem.recovery == .account)
            #expect(wire.lines.count == writes)
        }
    }

    @Test func transientFallbackFollowedBySuccessNeverBecomesAnAuthenticationFailure() {
        let (server, wire) = server()
        let writes = wire.lines.count
        let warning = server.heard(["method": "warning", "params": ["message": "Falling back from WebSockets to HTTPS transport"]])
        guard case .notice = warning.first else { Issue.record("No warning"); return }
        #expect(server.heard(["method": "error", "params": ["threadId": "T1", "willRetry": true, "error": error()]]).isEmpty)
        #expect(wire.lines.count == writes)
        let ended = server.heard(["method": "turn/completed", "params": ["turn": ["id": "U1", "status": "completed"]]])
        guard case .turnEnded("completed", nil) = ended.first else { Issue.record("Fallback changed success"); return }
        #expect(wire.lines.count == writes)
    }

    @Test func unknownOrMissingTransportStatusIsNotInvented() {
        for raw in [error(status: NSNull()), error(status: 200), error(status: 999), error("unknownVariant"), ["message": "WebSocket connection failed"]] {
            let (server, _) = server()
            let events = server.heard(["method": "error", "params": ["willRetry": false, "error": raw]])
            guard case .failed(let message, false) = events.first else { Issue.record("No error"); continue }
            #expect(ChatProblem(message, agent: "ChatGPT").status == nil)
            #expect(message == "WebSocket connection failed")
        }
    }
}
