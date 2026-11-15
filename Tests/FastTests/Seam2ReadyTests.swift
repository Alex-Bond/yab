import Foundation
import Testing
import YabCoreClient
@testable import Fast

@MainActor @Suite(.serialized)
struct Seam2ReadyTests {
    private static func state(document: Bool, tools: Bool) -> JSONValue {
        .object(["hasDocument": .bool(document), "devToolsReady": .bool(tools)])
    }

    @Test func neitherHalfReadyStateReleasesTheFirstOperation() async throws {
        var calls = 0, navigated = false
        let states = [Self.state(document: false, tools: false),
                      Self.state(document: false, tools: true),
                      Self.state(document: true, tools: false),
                      Self.state(document: true, tools: true)]
        try await Seam2Ready.wait {
            #expect(!navigated)
            defer { calls += 1 }
            return states[min(calls, states.count - 1)]
        }
        navigated = true
        #expect(navigated && calls == 4)
    }

    @Test func aLiveMainContextSurvivesSameDocumentCEFBookkeeping() async throws {
        try await Seam2Ready.wait(timeout: .zero) {
            .object(["hasDocument": .bool(false), "hasMainContext": .bool(true), "devToolsReady": .bool(true)])
        }
    }

    @Test func aMainContextWithoutReadyDevToolsCannotReleaseDispatch() async {
        do {
            try await Seam2Ready.wait(timeout: .zero) {
                .object(["hasDocument": .bool(false), "hasMainContext": .bool(true), "devToolsReady": .bool(false)])
            }
            Issue.record("A context alone must not release script dispatch")
        } catch YabCoreError.timeout {
            // The initial attachment and its script setup must still finish.
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func aClosedBackendIsNotRetried() async {
        enum Closed: Error { case page }
        var calls = 0
        do {
            try await Seam2Ready.wait { calls += 1; throw Closed.page }
            Issue.record("A failed backend must not release the waiting operation")
        } catch Closed.page {
            #expect(calls == 1)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func anUnreadyBackendHasABoundedDeadline() async {
        var calls = 0
        do {
            try await Seam2Ready.wait(timeout: .zero) {
                calls += 1
                return Self.state(document: false, tools: true)
            }
            Issue.record("An unready backend must time out")
        } catch YabCoreError.timeout {
            #expect(calls == 1)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func cancellationWhileReadingCannotReleaseALateReadyReply() async {
        var reply: CheckedContinuation<JSONValue, Never>?
        let task = Task { @MainActor in
            try await Seam2Ready.wait {
                await withCheckedContinuation { reply = $0 }
            }
        }
        for _ in 0..<200 where reply == nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard let reply else {
            task.cancel()
            Issue.record("The backend state read did not start")
            return
        }
        task.cancel()
        reply.resume(returning: Self.state(document: true, tools: true))
        do {
            try await task.value
            Issue.record("A retired page must not dispatch after a late ready reply")
        } catch is CancellationError {
            // The awaited state can finish, but no subsequent operation may run.
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}
