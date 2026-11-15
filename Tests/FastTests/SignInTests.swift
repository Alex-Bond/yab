import Foundation
import Testing
@testable import Fast

// Connect's sign-in (Agents.connect): the page's address as each CLI prints
// it, kept to open again when the page isn't in Yab; and the shell runs a
// connect waits on, which always come back, whatever holds their output.
struct SignInTests {
    /// `claude auth login`, as it printed on this Mac: the address to paste
    /// a code from, then the prompt for it, with no line after.
    static let claude = """
    Opening browser to sign in\u{2026}
    If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=zTkPg&code_challenge_method=S256&state=TT4Hh
    Paste code here if prompted >
    """

    /// `codex login`: its own server first (plain http, not the page),
    /// then the page, colored as a terminal draws it.
    static let codex = """
    Starting local login server on http://localhost:1455.
    If your browser did not open, navigate to this URL to authenticate:

    \u{1B}[94mhttps://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid%20profile%20email%20offline_access&state=abc&originator=codex_cli_rs\u{1B}[0m

    """

    @Test func claudeCodesPageIsFound() throws {
        let url = try #require(Agents.signInURL(in: Self.claude))
        #expect(url.host == "claude.com")
        #expect(url.path == "/cai/oauth/authorize")
        #expect(url.absoluteString.hasSuffix("state=TT4Hh"))
    }

    @Test func codexsPageIsFoundPastItsServer() throws {
        let url = try #require(Agents.signInURL(in: Self.codex))
        #expect(url.host == "auth.openai.com")
        #expect(url.absoluteString.hasSuffix("originator=codex_cli_rs"))
    }

    @Test func anAddressNotWholeYetIsLeft() {
        // Half a line so far: the rest of it is still to come.
        #expect(Agents.signInURL(in: "visit: https://claude.com/cai/oauth/authorize?code=tr") == nil)
        #expect(Agents.signInURL(in: "visit: https://claude.com/cai/oauth/authorize?code=true\n") != nil)
        // An address about something else isn't the page.
        #expect(Agents.signInURL(in: "Docs: https://docs.anthropic.com/en/cli.\n") == nil)
    }

    @Test func connectAndAddAccountGoByNamesOfTheirOwn() {
        #expect(Agents.connectID("claude", privately: false) == "connect.claude")
        #expect(Agents.connectID("claude", privately: true) == "connect.claude.private")
        #expect(Agents.connectID("codex", privately: true).hasPrefix(Agents.connecting))
    }

    @Test func aChildHoldingTheOutputDoesntHoldTheRun() async {
        // The shell is gone at once; the sleep it left behind keeps the pipe.
        let started = Date()
        let (code, output) = await Shell.run("/bin/sh", ["-c", "(sleep 30 &); echo hi"], env: ["PATH": "/usr/bin:/bin"], limit: 1)
        // Stopped at its limit (1 s), well before the 30 s it would run;
        // a Mac busy with other suites takes seconds over it.
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        #expect(code == 0)
    }

    @Test func aRunPastItsTimeIsStoppedAndSaysSo() async {
        let started = Date()
        let ran = await Shell.timed("/bin/sh", ["-c", "echo early; sleep 30"], env: ["PATH": "/usr/bin:/bin"], limit: 1)
        // Stopped at its limit (1 s), before the 30 s it would run; a full
        // run on m4 took over 10 s to get there.
        #expect(Date().timeIntervalSince(started) < 25)
        #expect(ran.late)
        #expect(ran.output.contains("early"))
    }

    @MainActor @Test func startedHasTheProcess() async {
        var got: Process?
        let (_, output) = await Shell.run("/bin/echo", ["hi"], env: [:], started: { got = $0 })
        #expect(output == "hi\n")
        #expect(got?.executableURL?.path == "/bin/echo")
    }
}
