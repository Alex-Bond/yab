import Foundation
import Testing
@testable import Fast

// Use an API Key: the key reaching claude's env, counting as signed in, and
// Codex keeping its own through its login.
@MainActor
struct AgentKeyTests {
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yab-key-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theKeyGoesIntoTheEnvAndOutAgain() {
        let base = ["PATH": "/test/bin", "HOME": "/test/home"]
        let with = AgentKey.apply(base, claude: "sk-ant-test")
        #expect(with[AgentKey.anthropic] == "sk-ant-test")
        #expect(with["PATH"] == "/test/bin")
        #expect(AgentKey.apply(with, claude: nil)[AgentKey.anthropic] == nil)
    }

    @Test func keptKeyIsWhatApplyGives() {
        defer { AgentKey.keep(claude: nil) }
        AgentKey.keep(claude: "  sk-ant-kept\n")
        #expect(AgentKey.claude() == "sk-ant-kept")
        #expect(AgentKey.keyed("claude"))
        #expect(AgentKey.apply(["PATH": "/bin"])[AgentKey.anthropic] == "sk-ant-kept")
        AgentKey.keep(claude: nil)
        #expect(AgentKey.claude() == nil)
        #expect(AgentKey.apply(["PATH": "/bin", AgentKey.anthropic: "stale"])[AgentKey.anthropic] == nil)
    }

    /// The usual account runs on your key; another account, signed in to
    /// a plan in its own folder, never gets it.
    @Test func onlyTheUsualAccountGetsTheKey() {
        let domain = "yab-key-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        let accounts = PlanAccounts(settings: settings, consent: consent)
        let base = AgentKey.apply(["PATH": "/test/bin"], claude: "sk-ant-test")
        #expect(accounts.env(PlanAccount(id: "claude", cli: "claude"), base: base)[AgentKey.anthropic] == "sk-ant-test")
        let extra = PlanAccount(id: "claude.abc123", cli: "claude", home: "/test/plans/claude.abc123")
        let env = accounts.env(extra, base: base)
        #expect(env[AgentKey.anthropic] == nil)
        #expect(env["CLAUDE_CONFIG_DIR"] == "/test/plans/claude.abc123")
    }

    /// Keys added from Models are accounts of their own: each runs on its
    /// own key, never twice, and one turned away sits out a minute while
    /// the next takes over.
    @Test func keysTakeTurns() async {
        setenv("YAB_AGENT_KEY_CHECK", "taken", 1)
        defer { unsetenv("YAB_AGENT_KEY_CHECK") }
        let domain = "yab-keys-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        let accounts = PlanAccounts(settings: settings, consent: consent)
        #expect(await accounts.addKey("claude", "sk-ant-first1111") == nil)
        #expect(await accounts.addKey("claude", "sk-ant-second2222") == nil)
        #expect(await accounts.addKey("claude", " sk-ant-second2222\n") == PlanAccounts.keyHere)
        let keys = accounts.all("claude").filter(\.keyed)
        #expect(keys.map(\.tail) == ["…1111", "…2222"])
        defer { keys.forEach { accounts.remove($0.id) } }

        let env = accounts.env(keys[0], base: ["PATH": "/bin", Shell.claudeToken: "token"])
        #expect(env[AgentKey.anthropic] == "sk-ant-first1111")
        #expect(env[Shell.claudeToken] == nil)
        #expect(env["CLAUDE_CONFIG_DIR"] == nil)
        // Back on the usual account, a key's key doesn't stay behind.
        #expect(accounts.env(accounts.account("claude"), base: env)[AgentKey.anthropic] == AgentKey.claude())

        #expect(accounts.pick("claude", skipping: ["claude"])?.id == keys[0].id)
        accounts.ranOut(keys[0].id)
        #expect(accounts.pick("claude", skipping: ["claude"])?.id == keys[1].id)
        #expect(!accounts.out(keys[0].id, now: Date().addingTimeInterval(PlanAccounts.keyWait + 1)))

        accounts.move(keys[1].id, by: -1)
        #expect(accounts.all("claude").filter(\.keyed).map(\.id) == [keys[1].id, keys[0].id])
        accounts.remove(keys[1].id)
        #expect(AgentKey.secret(keys[1].id) == nil)
        #expect(accounts.all("claude").filter(\.keyed).map(\.id) == [keys[0].id])
    }

    @Test func aKeptKeyReadsAsSignedIn() async throws {
        let home = try folder("claude")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["CLAUDE_CONFIG_DIR": home.path]
        let none: @Sendable (String) -> Bool = { _ in false }
        #expect(!(await PlanAccounts.read("claude", env: env, keychain: none)).signedIn)
        #expect((await PlanAccounts.read("claude", env: AgentKey.apply(env, claude: "sk-ant-test"), keychain: none)).signedIn)
        #expect(!(await PlanAccounts.read("claude", env: AgentKey.apply(env, claude: nil), keychain: none)).signedIn)
    }

    @Test func codexKeyIsToldFromAPlan() async throws {
        let home = try folder("codex")
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = home.appendingPathComponent("auth.json")
        #expect(!AgentKey.codexKeyed(home: home))
        try Data(#"{"OPENAI_API_KEY":"sk-test","tokens":null}"#.utf8).write(to: auth)
        #expect(AgentKey.codexKeyed(home: home))
        #expect((await PlanAccounts.read("codex", env: ["CODEX_HOME": home.path])).signedIn)
        try Data(#"{"OPENAI_API_KEY":null,"tokens":{"access_token":"a","refresh_token":"r"}}"#.utf8).write(to: auth)
        #expect(!AgentKey.codexKeyed(home: home))
    }

    /// The key reaches `codex login --with-api-key` on stdin, never in its
    /// arguments, and a refusal reads as not kept.
    @Test func codexLoginTakesTheKeyOnStdin() async throws {
        let home = try folder("codex-login")
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent("codex")
        try """
        #!/bin/bash
        [ "$1 $2" = "login --with-api-key" ] || exit 2
        [ -z "$3" ] || exit 3
        read -r key
        [ "$key" = "sk-good" ] || exit 1
        printf '{"OPENAI_API_KEY":"%s"}' "$key" > "$CODEX_HOME/auth.json"
        """.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let env = ["CODEX_HOME": home.path, "PATH": "/usr/bin:/bin"]
        let domain = "key-login-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        consent.beginConnection("codex")
        let permit = try #require(consent.connectionPermit("codex"))
        defer { consent.cancelConnections() }
        #expect(await !AgentKey.codexLogin(binary: codex.path, key: "sk-bad", env: env, permit: permit))
        #expect(!AgentKey.codexKeyed(home: home))
        #expect(await AgentKey.codexLogin(binary: codex.path, key: " sk-good\n", env: env, permit: permit))
        #expect(AgentKey.codexKeyed(home: home))
    }

    @Test func theWayInSaysTheKeySteps() {
        let open = AgentsIntro.words(flow: nil, keyFor: "claude", keyBlank: true)
        #expect(open.button == "Connect Claude")
        #expect(!open.enabled)
        #expect(open.detail == "No Claude plan? Connect with an API key of your own.")
        #expect(AgentsIntro.words(flow: nil, keyFor: "codex", keyBlank: false).enabled)
        let bad = AgentSetupModel.Trouble(clis: ["claude"], words: AgentKey.refused("claude"))
        #expect(AgentsIntro.words(flow: nil, trouble: bad, keyFor: "claude", keyBlank: false).button == "Try Again")
        #expect(AgentsIntro.words(flow: .preparing(["claude"]), keyFor: "claude").detail == "Checking the key with Anthropic…")
        #expect(AgentsIntro.words(flow: .preparing(["codex"]), keyFor: "codex").detail == "Checking the key with OpenAI…")
        #expect(AgentsIntro.words(flow: .finishing(["claude"]), keyFor: "claude").detail == "Key taken. Adding Yab's skill and tools…")
        // No key: the plan's words, as before.
        #expect(AgentsIntro.words(flow: .preparing(["claude"])).detail == "Checking it on this Mac…")
        for words in [AgentKey.hint("claude"), AgentKey.refused("codex"), AgentKey.unreachable("claude"), open.detail] {
            #expect(!words.contains("\u{2014}"))
        }
    }
}
