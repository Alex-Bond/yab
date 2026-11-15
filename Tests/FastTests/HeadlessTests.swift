import XCTest
@testable import Fast

// Yab woken for agents from a terminal (Headless, Mcp.wake, AgentCLI): what
// wakes it, and who a task started from a command line is told is there.

final class HeadlessTests: XCTestCase {
    func testOnlyWorkWakesAClosedYab() {
        // Asking after work under way: with yab closed there is none.
        for verb in ["agents", "agent-wait", "agent-stop", "agent-steer", "agent-queue", "agent-detach", "agent-reply", "app-status", "app-quit", "app-serve"] {
            XCTAssertTrue(Wire.idle.contains(verb), verb)
        }
        // Starting work, or an agent's first call, opens it; so does
        // bringing another browser's sign-ins.
        for verb in ["agent-run", "agent-attach", "agent-caps", "open", "agent-memory-search", "app-import"] {
            XCTAssertFalse(Wire.idle.contains(verb), verb)
        }
    }

    func testNobodyIsSaidOnlyWhenAsked() {
        XCTAssertEqual(AgentCLI.person(["--no-person", "do it"]), "none")
        // A test run's stdin is no terminal: whoever ran it reads the answer.
        XCTAssertEqual(AgentCLI.person(["do it"]), isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 ? "tty" : "caller")
    }

    func testTheWaitForAPersonIsMinutes() {
        // A farm job sets its own (YAB_WAIT_PERSON): the defaults are read without it.
        XCTAssertEqual(AgentCLI.patience([], person: "tty", environment: [:]), 600)
        XCTAssertEqual(AgentCLI.patience(["--wait-person", "2"], person: "tty", environment: [:]), 120)
        XCTAssertEqual(AgentCLI.patience(["--wait-person", "soon"], person: "tty", environment: [:]), 600)
        XCTAssertEqual(AgentCLI.patience([], person: "tty", environment: ["YAB_WAIT_PERSON": "5"]), 300)
    }

    func testAnAgentHearsWhatYabWaitsForIn15Seconds() {
        // An agent reads the command's output only once it ends.
        XCTAssertEqual(AgentCLI.patience([], person: "caller", environment: [:]), 15)
        XCTAssertEqual(AgentCLI.patience(["--wait-person", "2"], person: "caller", environment: [:]), 120)
    }

    func testStatusAndQuitNeedNoSession() {
        for verb in ["app-status", "app-quit", "app-serve", "app-import", "agent-reply"] {
            XCTAssertTrue(Bench.allowed(verb, session: false, open: false), verb)
        }
        // The test runs' own answer to a card, never a shipped caller's:
        // the terminal's reply is agent-reply, and was once this name.
        XCTAssertFalse(Bench.allowed("agent-answer", session: false, open: false))
        XCTAssertFalse(Bench.allowed("quit-ask", session: false, open: false))
    }

    @MainActor func testNobodyServesUntilAsked() {
        XCTAssertFalse(Headless.serving)
        XCTAssertFalse(Headless.nobody)
        XCTAssertFalse(Headless.hidden)
    }

    func testAHiddenLaunchIsTheFlagsOnly() {
        // This test run was given neither.
        XCTAssertFalse(Headless.on)
    }

    func testSessionListJSONIsWhatALauncherReads() {
        let rows = Cli.sessionsJSON([
            ["session": "s1", "name": "Claude", "cli": "claude", "state": "waiting", "prompt": "Book a table for two\nat eight",
             "started": "2026-10-24T09:00:00Z", "finished": NSNull(), "waiting": true],
            // An app from before the new fields: a title from the prompt, waiting from the state.
            ["session": "s2", "name": "ChatGPT", "cli": "codex", "state": "done", "prompt": "Sum up my mail", "title": ""],
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"] as? String, "s1")
        XCTAssertEqual(rows[0]["agent"] as? String, "Claude")
        XCTAssertEqual(rows[0]["cli"] as? String, "claude")
        XCTAssertEqual(rows[0]["title"] as? String, "Book a table for two")
        XCTAssertEqual(rows[0]["started"] as? String, "2026-10-24T09:00:00Z")
        XCTAssertTrue(rows[0]["finished"] is NSNull)
        XCTAssertEqual(rows[0]["waiting"] as? Bool, true)
        XCTAssertEqual(rows[1]["title"] as? String, "Sum up my mail")
        XCTAssertTrue(rows[1]["started"] is NSNull)
        XCTAssertEqual(rows[1]["waiting"] as? Bool, false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(rows))
    }
}
