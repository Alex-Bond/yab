import Foundation
import Testing
@testable import Fast

// The arguments each CLI is started with, word for word, for the sessions
// that differ: new, resumed, forked, bypassed, plan mode, browser only,
// text only, a model and an effort.
@MainActor
struct AgentArgsTests {
    private let me = "/Applications/Yab.app/Contents/MacOS/Yab"
    private let mcp = ["mcp", "--socket", "/tmp/yab.sock", "--session", "S1", "--inner"]
    private let list = "\"mcp\",\"--socket\",\"/tmp/yab.sock\",\"--session\",\"S1\",\"--inner\""

    private func launch(thread: String? = nil, fork: String? = nil, full: Bool = true, textOnly: Bool = false,
                        permissionMode: String? = nil, model: String? = nil, effort: String? = nil) -> Agents.Launch {
        Agents.Launch(me: me, mcp: mcp, brief: "BRIEF", thread: thread, fork: fork, full: full, textOnly: textOnly,
                      permissionMode: permissionMode, model: model, effort: effort)
    }

    /// Claude's arguments with its --mcp-config read back: a dictionary's
    /// keys come out of JSONSerialization in no fixed order.
    private func claude(_ launch: Agents.Launch) throws -> (args: [String], config: NSDictionary) {
        var args = Agents.claudeArgs(launch)
        let at = try #require(args.firstIndex(of: "--mcp-config")) + 1
        let config = try #require(try JSONSerialization.jsonObject(with: Data(args[at].utf8)) as? NSDictionary)
        args[at] = "CONFIG"
        return (args, config)
    }

    private let claudeHead = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--replay-user-messages", "--mcp-config", "CONFIG", "--strict-mcp-config", "--append-system-prompt", "BRIEF",
    ]

    private var yabServer: NSDictionary {
        let server: [String: Any] = ["command": me, "args": mcp]
        return ["mcpServers": ["yab-browser": server]]
    }

    @Test func claudeNewBypassedWithModelAndEffort() throws {
        let (args, config) = try claude(launch(model: "opus", effort: "high"))
        #expect(args == claudeHead + ["--permission-mode", "bypassPermissions", "--model", "opus", "--effort", "high",
                                      "--include-partial-messages"])
        #expect(config == yabServer)
    }

    @Test func claudeResumedWithTheBrowserOnly() throws {
        let (args, config) = try claude(launch(thread: "T1", full: false))
        #expect(args == claudeHead + ["--tools", "", "--allowedTools", "mcp__yab-browser", "--resume", "T1",
                                      "--include-partial-messages"])
        #expect(config == yabServer)
    }

    @Test func claudeForkedInPlanMode() throws {
        let (args, _) = try claude(launch(fork: "P1", permissionMode: "plan"))
        #expect(args == claudeHead + ["--permission-mode", "plan", "--permission-prompts", "host",
                                      "--resume", "P1", "--fork-session", "--include-partial-messages"])
    }

    @Test func claudeResumingIsNotForkedAgain() throws {
        let (args, _) = try claude(launch(thread: "T1", fork: "P1"))
        #expect(args == claudeHead + ["--permission-mode", "bypassPermissions", "--resume", "T1", "--include-partial-messages"])
    }

    @Test func claudeTextOnlyHasNoServersAndNoTools() throws {
        let (args, config) = try claude(launch(full: false, textOnly: true, permissionMode: "plan"))
        #expect(args == claudeHead + ["--tools", "", "--include-partial-messages"])
        #expect(config == ["mcpServers": [String: Any]()] as NSDictionary)
    }

    private func codexShared(full: Bool) -> [String] {
        [
            "-c", "mcp_servers.yab-browser.command=\"\(me)\"",
            "-c", "mcp_servers.yab-browser.args=[\(list)]",
            "-c", "mcp_servers.yab-browser.tool_timeout_sec=900",
            "-c", "mcp_servers.yab-browser.default_tools_approval_mode=\"approve\"",
            "-c", "approval_policy=\"never\"",
            "-c", "sandbox_mode=\"\(full ? "danger-full-access" : "read-only")\"",
        ]
    }

    private let browserOnly = ["--ignore-user-config", "-c", "features.shell_tool=false"]

    @Test func codexExecNewWithTheWholeMac() {
        let args = Agents.codexArgs(launch(model: "gpt-5.5", effort: "high"), serving: false, browserOnly: browserOnly, message: "Hi")
        #expect(args == ["exec", "--json", "--skip-git-repo-check"] + codexShared(full: true)
                + ["-m", "gpt-5.5", "-c", "model_reasoning_effort=\"high\"", "BRIEF\n\nHi"])
    }

    @Test func codexExecResumedWithTheBrowserOnly() {
        let args = Agents.codexArgs(launch(thread: "T1", full: false), serving: false, browserOnly: browserOnly, message: "Hi")
        #expect(args == ["exec", "resume", "T1", "--json", "--skip-git-repo-check"] + codexShared(full: false)
                + browserOnly + ["Hi"])
    }

    @Test func codexServerWithTheBrowserOnly() {
        let args = Agents.codexArgs(launch(thread: "T1", full: false, model: "gpt-5.5"), serving: true, browserOnly: browserOnly, message: "Hi")
        #expect(args == ["app-server", "-c", "model_reasoning_summary=\"concise\""] + codexShared(full: false)
                + browserOnly + Agents.codexServerQuiet + ["-c", "model=\"gpt-5.5\""])
    }

    @Test func codexServerTextOnly() {
        let args = Agents.codexArgs(launch(textOnly: true, effort: "low"), serving: true, browserOnly: browserOnly, message: "Hi")
        #expect(args == ["app-server", "-c", "model_reasoning_summary=\"concise\""] + codexShared(full: true)
                + ["-c", "mcp_servers.yab-browser.enabled=false", "-c", "model_reasoning_effort=\"low\""])
    }

    @Test func aSessionsAgentIsItsCliAsKept() {
        for (cli, agent) in [("claude", AgentKind.claude), ("codex", .codex), ("external", .external), ("aside", .aside)] {
            let session = Agents.Session(id: "S", cli: cli, name: "N", prompt: "", state: .done)
            #expect(session.agent == agent)
            #expect(agent.rawValue == cli)
        }
        #expect(Agents.Session(id: "S", cli: "someday", name: "N", prompt: "", state: .done).agent == nil)
    }

    @Test func codexServerQuietIsAsItWas() {
        #expect(Agents.codexServerQuiet == [
            "-c", "features.hooks=false", "-c", "features.computer_use=false", "-c", "features.memories=false",
            "-c", "features.multi_agent=false", "-c", "features.image_generation=false",
            "-c", "features.skill_mcp_dependency_install=false", "-c", "features.tool_suggest=false",
            "-c", "suppress_unstable_features_warning=true",
        ])
    }
}
