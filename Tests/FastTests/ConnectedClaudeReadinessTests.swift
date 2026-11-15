import Foundation
import Testing
@testable import Fast

@MainActor
struct ConnectedClaudeReadinessTests {
    @Test(arguments: [true, false])
    func extraClaudeLoginDeterminesReadinessWhenUsualIsSignedOut(_ connected: Bool) async throws {
        let domain = "connected-claude-" + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: domain))
        defer { settings.removePersistentDomain(forName: domain) }
        let usual = PlanAccount(id: "claude", cli: "claude", home: "/fixture/usual")
        let extra = PlanAccount(id: "claude.connected", cli: "claude", home: "/fixture/connected")
        settings.set(try JSONEncoder().encode(["claude": usual]), forKey: "plans.usual")
        settings.set(try JSONEncoder().encode([extra]), forKey: "plans.accounts")
        let consent = ProviderConsent(settings: settings, history: [])
        consent.grant("claude")
        let plans = PlanAccounts(settings: settings, consent: consent)
        let status = AgentSetup.Status(claude: true)
        let setup = AgentSetupModel(status: status, consent: consent)
        let found = Shell.Found(claude: "/fixture/claude", env: [:])
        var checked: [String] = []
        await setup.look(find: { _ in found }, readStatus: { status }, plans: plans,
                         readIdentity: { account, _, _ in
            checked.append(account.id)
            return (account.id == extra.id && connected, nil, nil)
        })
        #expect(checked == [usual.id, extra.id])
        #expect(setup.connected("claude"))
        #expect(setup.signedIn["claude"] == connected)
        #expect(setup.canRunTasks() == connected)
        consent.revoke("claude")
        #expect(!setup.canRunTasks(), "An extra login is not permission after disconnect")
    }
    @Test func verifiedExtraLoginCannotBeOverwrittenByAnOlderNegative() async throws {
        let domain = "connected-claude-race-" + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: domain))
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        consent.grant("claude")
        let plans = PlanAccounts(settings: settings, consent: consent)
        let status = AgentSetup.Status(claude: true)
        let setup = AgentSetupModel(status: status, consent: consent)
        let found = Shell.Found(claude: "/fixture/claude", env: [:])
        let (started, start) = AsyncStream<Void>.makeStream()
        let (resume, release) = AsyncStream<Void>.makeStream()
        let pending = Task {
            await setup.look(find: { _ in found }, readStatus: { status }, plans: plans,
                             readIdentity: { _, _, _ in
                start.yield(())
                var gate = resume.makeAsyncIterator()
                _ = await gate.next()
                return (false, nil, nil)
            })
        }
        var begins = started.makeAsyncIterator()
        _ = await begins.next()
        setup.didConnect("claude")
        release.yield(())
        await pending.value
        #expect(setup.signedIn["claude"] == true)
        #expect(setup.canRunTasks())
        start.finish(); release.finish()
    }

}

/// #1687: readiness looks where a task runs. Discovery from files alone
/// can't see a claude only the login shell's PATH has, nor a sign-in only
/// exported there (CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token`);
/// Agents.task reads both, so ⌘J's Return refused words a chat would take.
/// The whole matrix against the launcher's own code: AgentLaunchReadinessTests.
@MainActor
struct LoginShellReadinessTests {
    private func world(_ name: String) throws -> (UserDefaults, String, ProviderConsent, PlanAccounts, URL) {
        let domain = name + "-" + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: domain))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "{}".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let usual = PlanAccount(id: "claude", cli: "claude", home: home.path)
        settings.set(try JSONEncoder().encode(["claude": usual]), forKey: "plans.usual")
        let consent = ProviderConsent(settings: settings, history: [])
        return (settings, domain, consent, PlanAccounts(settings: settings, consent: consent), home)
    }

    /// The real reader, with no keychain item: only the files and the
    /// environment it is handed can say signed in.
    private static func read(_ account: PlanAccount, _ env: [String: String], _ revision: Int) async -> (signedIn: Bool, email: String?, plan: String?) {
        await PlanAccounts.read(account, env: env, revision: revision, keychain: { _ in false })
    }

    @Test func claudeOnlyOnTheLoginShellsPathIsReady() async throws {
        let (settings, domain, consent, plans, home) = try world("login-path")
        defer { settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        consent.grant("claude")
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: consent)
        let bare = Shell.Found(claude: nil, env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        var terminal = Shell.Found(claude: home.path + "/tools/bin/claude", env: ["HOME": home.path, "PATH": home.path + "/tools/bin:/usr/bin:/bin"])
        terminal.env[Shell.claudeToken] = "fixture-token"
        var asked: [Bool] = []
        await setup.look(find: { login in asked.append(login); return login ? terminal : bare },
                         readStatus: { AgentSetup.Status(claude: true) }, plans: plans, readIdentity: Self.read)
        #expect(asked == [true], "Connected: one look, where its task runs")
        #expect(setup.found?.claude == terminal.claude)
        #expect(setup.signedIn["claude"] == true)
        #expect(setup.canRunTasks(), "Return in ⌘J sends: the chat would run on this claude")
    }

    @Test func tokenExportedOnlyInTheShellIsSignedIn() async throws {
        let (settings, domain, consent, plans, home) = try world("login-token")
        defer { settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        consent.grant("claude")
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: consent)
        let claude = home.path + "/.local/bin/claude"
        let files = Shell.Found(claude: claude, env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        var terminal = files
        terminal.env[Shell.claudeToken] = "fixture-token"
        await setup.look(find: { $0 ? terminal : files },
                         readStatus: { AgentSetup.Status(claude: true) }, plans: plans, readIdentity: Self.read)
        #expect(setup.signedIn["claude"] == true)
        #expect(setup.canRunTasks())
    }

    @Test func signedOutInTheTerminalTooStaysNotReady() async throws {
        let (settings, domain, consent, plans, home) = try world("login-none")
        defer { settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        consent.grant("claude")
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: consent)
        let files = Shell.Found(claude: home.path + "/.local/bin/claude", env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        var terminal = files
        terminal.env["PATH"] = home.path + "/.local/bin:/usr/bin:/bin"
        await setup.look(find: { $0 ? terminal : files },
                         readStatus: { AgentSetup.Status(claude: true) }, plans: plans, readIdentity: Self.read)
        #expect(setup.signedIn["claude"] == false)
        #expect(!setup.canRunTasks())
    }

    /// Cortex (8aeb35e5): nothing not connected ever runs the login shell.
    @Test func notConnectedNeverAsksTheLoginShell() async throws {
        let (settings, domain, consent, plans, home) = try world("login-unconnected")
        defer { settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: consent)
        let files = Shell.Found(claude: nil, env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        await setup.look(find: { login in
            if login { Issue.record("The login shell ran for a provider nobody connected") }
            return files
        }, readStatus: { AgentSetup.Status(claude: true) }, plans: plans, readIdentity: Self.read)
        #expect(!setup.canRunTasks())
    }

    /// Signed in from files too: still one look, in the environment its
    /// task runs in, never a second one from files that could say otherwise.
    @Test func signedInFromFilesIsLookedAtWhereItsTaskRuns() async throws {
        let (settings, domain, consent, plans, home) = try world("login-files")
        defer { settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: home) }
        consent.grant("claude")
        try #"{"oauthAccount":{"accountUuid":"fixture","emailAddress":"probe@example.test"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: consent)
        let files = Shell.Found(claude: home.path + "/.local/bin/claude", env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        var asked: [Bool] = []
        await setup.look(find: { login in asked.append(login); return files },
                         readStatus: { AgentSetup.Status(claude: true) }, plans: plans, readIdentity: Self.read)
        #expect(asked == [true])
        #expect(setup.canRunTasks())
    }
}
