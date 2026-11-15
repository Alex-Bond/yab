import Foundation
import Testing
@testable import Fast

/// #1687, register 2341: "ready" (Agents.ready, the composer's Return) is
/// exactly "a chat would start". For every way a person can be signed in,
/// readiness from a look must equal what the launcher's own code says: the
/// copy, account and environment AgentLaunch.resolve gives a task, and that
/// copy's answer to the launcher's sign-in check (Agents.signInCheck) in
/// that environment. The copies here are stand-ins that answer as the real
/// CLIs do: Claude Code from an exported token or key, else its config
/// folder's .claude.json; Codex from its CODEX_HOME's auth.json; Cursor
/// from `status --format json`, as the launcher asks it. Gemini's sign-in
/// is its CLI's own, asked by GeminiAccount: the world says it, and the
/// test holds that it is asked of the copy and environment a turn runs in.
@MainActor
struct AgentLaunchReadinessTests {
    /// One person's Mac: what a look from files alone sees, what the
    /// terminal (login shell) adds, who is connected, and their accounts.
    struct World: CustomTestStringConvertible {
        var name: String
        var connected: [String]
        var claude: Place = .none
        var codex: Place = .none
        /// Claude's usual account signed in in its folder.
        var claudeFiles = false
        /// CLAUDE_CODE_OAUTH_TOKEN exported in ~/.zshrc.
        var shellToken = false
        /// An extra Claude account with its own folder: nil none, else signed in there.
        var claudeExtra: Bool?
        var codexFiles = false
        var codexExtra: Bool?
        var cursor: Place = .none
        var cursorSignedIn = false
        var gemini: Place = .none
        var geminiSignedIn = false
        /// Whether a chat would start: what the test says before it looks.
        var ready: Bool

        enum Place { case none, files, loginPath }
        var testDescription: String { name }
    }

    static let worlds: [World] = [
        World(name: "Claude signed in by files", connected: ["claude"], claude: .files, claudeFiles: true, ready: true),
        World(name: "Claude's token only in ~/.zshrc", connected: ["claude"], claude: .files, shellToken: true, ready: true),
        World(name: "claude only on the login shell's PATH, token there", connected: ["claude"], claude: .loginPath, shellToken: true, ready: true),
        World(name: "claude only on the login shell's PATH, signed in by files", connected: ["claude"], claude: .loginPath, claudeFiles: true, ready: true),
        World(name: "Claude's usual signed out, an extra account signed in", connected: ["claude"], claude: .files, claudeExtra: true, ready: true),
        World(name: "Claude's extra signed out, the usual one by the shell's token", connected: ["claude"], claude: .files, shellToken: true, claudeExtra: false, ready: true),
        World(name: "Claude signed out everywhere", connected: ["claude"], claude: .files, claudeExtra: false, ready: false),
        World(name: "Claude signed in but not connected in Yab", connected: [], claude: .files, claudeFiles: true, shellToken: true, ready: false),
        World(name: "Codex signed in by files", connected: ["codex"], codex: .files, codexFiles: true, ready: true),
        World(name: "codex only on the login shell's PATH", connected: ["codex"], codex: .loginPath, codexFiles: true, ready: true),
        World(name: "Codex's usual signed out, an extra account signed in", connected: ["codex"], codex: .files, codexExtra: true, ready: true),
        World(name: "Codex signed out", connected: ["codex"], codex: .files, codexExtra: false, ready: false),
        World(name: "Codex signed in but not connected in Yab", connected: [], codex: .files, codexFiles: true, ready: false),
        World(name: "Both connected, only Codex signed in", connected: ["claude", "codex"], claude: .files, codex: .loginPath, codexFiles: true, ready: true),
        World(name: "Both connected, both signed out", connected: ["claude", "codex"], claude: .loginPath, codex: .files, ready: false),
        World(name: "Cursor signed in, only on the login shell's PATH", connected: ["cursor"], cursor: .loginPath, cursorSignedIn: true, ready: true),
        World(name: "Cursor signed in by files' copy", connected: ["cursor"], cursor: .files, cursorSignedIn: true, ready: true),
        World(name: "Cursor signed out", connected: ["cursor"], cursor: .files, ready: false),
        World(name: "Cursor signed in but not connected in Yab", connected: [], cursor: .files, cursorSignedIn: true, ready: false),
        World(name: "Gemini signed in, agy only on the login shell's PATH", connected: ["gemini"], gemini: .loginPath, geminiSignedIn: true, ready: true),
        World(name: "Gemini signed out", connected: ["gemini"], gemini: .files, ready: false),
        World(name: "Gemini connected, agy nowhere", connected: ["gemini"], geminiSignedIn: true, ready: false),
        World(name: "Claude signed out, Cursor signed in", connected: ["claude", "cursor"], claude: .files, cursor: .files, cursorSignedIn: true, ready: true),
    ]

    private static let claudeStandIn = """
    #!/bin/sh
    if [ "$1 $2" = "auth status" ]; then
      if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || [ -n "$ANTHROPIC_API_KEY" ]; then echo '{"loggedIn":true}'; exit 0; fi
      if /usr/bin/grep -q '"accountUuid":"[^"]' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null; then echo '{"loggedIn":true}'; exit 0; fi
      echo '{"loggedIn":false}'; exit 1
    fi
    exit 2
    """

    private static let cursorStandIn = """
    #!/bin/sh
    if [ "$1 $2 $3" = "status --format json" ]; then
      if [ -f "$HOME/.cursor-signed-in" ]; then echo '{"isAuthenticated":true,"userInfo":{"email":"probe@example.test"}}'
      else echo '{"isAuthenticated":false}'; fi
      exit 0
    fi
    [ "$1" = "models" ] && exit 0
    exit 2
    """

    private static let codexStandIn = """
    #!/bin/sh
    if [ "$1 $2" = "login status" ]; then
      /usr/bin/grep -q '"access_token":"[^"]' "${CODEX_HOME:-$HOME/.codex}/auth.json" 2>/dev/null && exit 0
      exit 1
    fi
    exit 2
    """

    private struct Made {
        let settings: UserDefaults
        let domain: String
        let home: URL
        let consent: ProviderConsent
        let plans: PlanAccounts
        let files: Shell.Found
        let terminal: Shell.Found
        func clean() {
            settings.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: home)
        }
    }

    private func make(_ world: World) throws -> Made {
        let domain = "launch-readiness-" + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: domain))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let manager = FileManager.default
        func folder(_ path: String) throws -> URL {
            let url = home.appendingPathComponent(path)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ text: String, _ url: URL, executable: Bool = false) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if executable { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        }
        let signedInClaude = #"{"oauthAccount":{"accountUuid":"fixture","emailAddress":"probe@example.test"}}"#
        let signedInCodex = #"{"tokens":{"access_token":"fixture-access"}}"#
        // The usual accounts' own folders: never this Mac's real ones.
        let claudeUsual = try folder("claude-usual")
        try write(world.claudeFiles ? signedInClaude : "{}", claudeUsual.appendingPathComponent(".claude.json"))
        let codexUsual = try folder("codex-usual")
        if world.codexFiles { try write(signedInCodex, codexUsual.appendingPathComponent("auth.json")) }
        settings.set(try JSONEncoder().encode([
            "claude": PlanAccount(id: "claude", cli: "claude", home: claudeUsual.path),
            "codex": PlanAccount(id: "codex", cli: "codex", home: codexUsual.path),
        ]), forKey: "plans.usual")
        var extras: [PlanAccount] = []
        if let signedIn = world.claudeExtra {
            let extra = try folder("claude-extra")
            try write(signedIn ? signedInClaude : "{}", extra.appendingPathComponent(".claude.json"))
            extras.append(PlanAccount(id: "claude.extra1", cli: "claude", home: extra.path))
        }
        if let signedIn = world.codexExtra {
            let extra = try folder("codex-extra")
            if signedIn { try write(signedInCodex, extra.appendingPathComponent("auth.json")) }
            extras.append(PlanAccount(id: "codex.extra1", cli: "codex", home: extra.path))
        }
        settings.set(try JSONEncoder().encode(extras), forKey: "plans.accounts")
        // The copies: in a place files show (~/.local/bin), or only on the
        // PATH the login shell gives.
        let local = try folder(".local/bin"), tools = try folder("tools/bin")
        func place(_ name: String, _ where_: World.Place, _ script: String) throws -> (files: String?, terminal: String?) {
            switch where_ {
            case .none: return (nil, nil)
            case .files:
                try write(script, local.appendingPathComponent(name), executable: true)
                return (local.appendingPathComponent(name).path, local.appendingPathComponent(name).path)
            case .loginPath:
                try write(script, tools.appendingPathComponent(name), executable: true)
                return (nil, tools.appendingPathComponent(name).path)
            }
        }
        let claude = try place("claude", world.claude, Self.claudeStandIn)
        let codex = try place("codex", world.codex, Self.codexStandIn)
        let cursor = try place("cursor-agent", world.cursor, Self.cursorStandIn)
        let gemini = try place("agy", world.gemini, "#!/bin/sh\nexit 2\n")
        if world.cursorSignedIn { try write("", home.appendingPathComponent(".cursor-signed-in")) }
        let bare = ["HOME": home.path, "PATH": local.path + ":/usr/bin:/bin"]
        var login = bare
        login["PATH"] = tools.path + ":" + local.path + ":/usr/bin:/bin"
        if world.shellToken { login[Shell.claudeToken] = "fixture-shell-token" }
        let consent = ProviderConsent(settings: settings, history: [])
        for cli in world.connected { consent.grant(cli) }
        let plans = PlanAccounts(settings: settings, consent: consent)
        return Made(settings: settings, domain: domain, home: home, consent: consent, plans: plans,
                    files: Shell.Found(claude: claude.files, codex: codex.files, cursor: cursor.files, gemini: gemini.files, env: bare),
                    terminal: Shell.Found(claude: claude.terminal, codex: codex.terminal, cursor: cursor.terminal, gemini: gemini.terminal, env: login))
    }

    /// The launcher's own answer: AgentLaunch.resolve in the environment a
    /// task runs in, then the copy's sign-in check, as Agents.launch asks
    /// before it starts a chat (Cursor: CursorRunner.identify, as there).
    /// Gemini's turns start on the resolved copy once its CLI said signed
    /// in. A provider not connected never launches.
    private func launches(_ cli: String, _ made: Made, _ world: World) async -> Bool {
        guard made.consent.allows(cli), let launch = AgentLaunch.resolve(cli, in: made.terminal, plans: made.plans) else { return false }
        switch cli {
        case "gemini": return world.geminiSignedIn
        case "cursor": return await CursorRunner.identify(binary: launch.binary, env: launch.env, permit: made.consent.permit(cli)).signedIn
        default:
            let ran = await Shell.timed(launch.binary, Agents.signInCheck(cli), env: launch.env)
            return Agents.saysSignedIn(cli, code: ran.code, output: ran.output)
        }
    }

    /// Gemini's sign-in as the world says it, and which copy it was asked of.
    private func gemini(_ world: World, asked: @escaping (String?, [String: String]) -> Void) -> (Shell.Found, ProviderLaunchPermit?) async -> Bool? {
        { found, _ in
            asked(found.gemini, found.env)
            return world.geminiSignedIn
        }
    }

    @Test(arguments: worlds)
    func readinessIsWhatTheLauncherWouldStart(_ world: World) async throws {
        let made = try make(world)
        defer { made.clean() }
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: world.claude != .none, codex: world.codex != .none), consent: made.consent)
        var asked: [Bool] = []
        var geminiAsked: [String?] = []
        var geminiEnv: [String: String]?
        await setup.look(find: { login in asked.append(login); return login ? made.terminal : made.files },
                         readStatus: { AgentSetup.Status() }, plans: made.plans,
                         readIdentity: { account, env, revision in
            // The real reader, this Mac's keychain left out of it.
            await PlanAccounts.read(account, env: env, revision: revision, keychain: { _ in false })
        }, readGemini: gemini(world) { geminiAsked.append($0); geminiEnv = $1 })
        // One look, in the environment the launcher uses once Claude or
        // Codex is connected; from files alone (no login shell) otherwise.
        #expect(asked == [!world.connected.isEmpty])

        // Gemini asked of exactly the copy and environment its turn gets.
        if made.consent.allows("gemini"), let launch = AgentLaunch.resolve("gemini", in: made.terminal, plans: made.plans) {
            #expect(geminiAsked == [launch.binary])
            #expect(geminiEnv == launch.env)
        } else {
            #expect(geminiAsked.isEmpty, "Not connected or not here: nothing asked")
        }

        var anyLaunches = false
        for cli in AgentLaunch.terminalCLIs {
            let launches = await launches(cli, made, world)
            anyLaunches = anyLaunches || launches
            if made.consent.allows(cli) {
                #expect((setup.signedIn[cli] == true) == launches, "\(cli): signed in for readiness iff its task would start")
            }
        }
        #expect(anyLaunches == world.ready, "The world says what a chat would do")
        #expect(setup.canRunTasks() == anyLaunches)
        #expect(Agents.ready(asked: true, setup: setup) == anyLaunches)
        // ⌘J's Return: a new chat sends iff ready, else Settings › AI.
        #expect(ChatComposer.connectsFirst(newChat: true, answering: false, ready: Agents.ready(asked: true, setup: setup)) == !anyLaunches)
        #expect(!ChatComposer.connectsFirst(newChat: false, answering: false, ready: false), "Words to a running chat never open Settings")
    }

    /// Waits a little for what a Task started, at most a second.
    private func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<50 where !done() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// Nothing looks where tasks run at launch or on a timer of its own:
    /// Agents.ready asked again and again starts no look, and a connected
    /// agent counts until one does (Return then lets the task resolve it).
    /// A person's ask (⌘J, a key in a composer) looks once; a "no" is
    /// looked at again only while a composer or Settings is open; a task's
    /// resolution is projected without a second login shell.
    @Test func onlyAPersonsAskOrATaskLooksWhereTasksRun() async throws {
        let made = try make(World(name: "asks", connected: ["claude"], claude: .files, ready: false))
        defer { made.clean() }
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: made.consent)
        var looks: [(login: Bool, fresh: Bool)] = []
        setup.lookAgain = { fresh in
            await setup.look(fresh: fresh, find: { login in looks.append((login, fresh)); return login ? made.terminal : made.files },
                             readStatus: { AgentSetup.Status() }, plans: made.plans,
                             readIdentity: { await PlanAccounts.read($0, env: $1, revision: $2, keychain: { _ in false }) })
        }
        setup.relookAfter = 0
        // Launch: every surface asks Agents.ready; nothing looks.
        for _ in 0..<5 { #expect(setup.canTakeTasks(), "Connected and not looked at: a chat may start and resolve it") }
        await settle()
        #expect(looks.isEmpty)
        #expect(!setup.lookedInTerminal)
        // A person asks: one look, where tasks run.
        setup.asked()
        await settle { setup.signedIn["claude"] != nil }
        #expect(looks.map { $0.login } == [true])
        #expect(looks.map { $0.fresh } == [true])
        #expect(!setup.canRunTasks(), "Signed out where tasks run")
        // Not ready, nothing open: no look again, however long it has been.
        for _ in 0..<5 { _ = setup.canTakeTasks() }
        await settle()
        #expect(looks.count == 1)
        // A composer with the keys: a "no" is looked at again.
        setup.showing("composer.test", true)
        _ = setup.canTakeTasks()
        await settle { looks.count == 2 }
        #expect(looks.count == 2)
        setup.showing("composer.test", false)
        _ = setup.canTakeTasks()
        await settle()
        #expect(looks.count == 2)
    }

    /// A surface that shows by itself (a bot site's notice) looks from
    /// files only, and never replaces what a look where tasks run found
    /// (Cortex, fix/cortex-helper-tree e41bac1f).
    @Test func aNoticeNobodyAskedForNeverAsksTheLoginShell() async throws {
        let made = try make(World(name: "notice", connected: ["claude"], claude: .files, ready: false))
        defer { made.clean() }
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: made.consent)
        var looks: [Bool] = []
        let look = { (whereTasksRun: Bool) in
            await setup.look(whereTasksRun: whereTasksRun, find: { login in looks.append(login); return login ? made.terminal : made.files },
                             readStatus: { AgentSetup.Status() }, plans: made.plans,
                             readIdentity: { await PlanAccounts.read($0, env: $1, revision: $2, keychain: { _ in false }) })
        }
        await look(false)
        #expect(looks == [false], "Connected, but nobody acted: files alone")
        #expect(!setup.lookedInTerminal)
        await look(true)
        #expect(looks == [false, true])
        #expect(setup.lookedInTerminal)
        let found = setup.found?.env
        await look(false)
        #expect(looks == [false, true], "A notice never replaces the look where tasks run")
        #expect(setup.found?.env == found)
        #expect(setup.lookedInTerminal)
    }

    /// A notice is not a request to execute a connected provider. File-only
    /// discovery must stay passive through identity projection too (Cortex).
    @Test func aPassiveNoticeNeverExecutesConnectedProviderTools() async throws {
        let made = try make(World(name: "passive providers", connected: ["cursor", "gemini"],
                                  cursor: .files, cursorSignedIn: true, gemini: .files, ready: true))
        defer { made.clean() }
        let cursor = try #require(made.files.cursor)
        let marker = made.home.appendingPathComponent(".cursor-readiness-executed")
        let script = try String(contentsOfFile: cursor, encoding: .utf8)
            .replacingOccurrences(of: "#!/bin/sh\n", with: "#!/bin/sh\necho called >> \"$HOME/.cursor-readiness-executed\"\n")
        try script.write(toFile: cursor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cursor)
        let setup = AgentSetupModel(status: AgentSetup.Status(), consent: made.consent)
        var geminiCalls = 0
        var discovery: [Bool] = []
        let look = { (active: Bool) in
            await setup.look(whereTasksRun: active, find: { login in
                discovery.append(login)
                return login ? made.terminal : made.files
            }, readStatus: { AgentSetup.Status() }, plans: made.plans,
               readGemini: { _, _ in geminiCalls += 1; return true })
        }
        await look(false)
        #expect(discovery == [false])
        #expect(geminiCalls == 0, "A passive notice must not run Gemini's models/auth commands")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "A passive notice must not run Cursor status/models")
        #expect(!setup.lookedInTerminal)

        await look(true)
        #expect(geminiCalls == 1, "A person's ask still checks the connected provider")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(setup.signedIn["cursor"] == true)
        #expect(setup.signedIn["gemini"] == true)
        let calls = try String(contentsOf: marker, encoding: .utf8)
        await look(false)
        #expect(geminiCalls == 1)
        #expect(try String(contentsOf: marker, encoding: .utf8) == calls)
        #expect(setup.signedIn["cursor"] == true)
        #expect(setup.signedIn["gemini"] == true)
    }

    /// A task that resolved where it runs is what readiness takes, from the
    /// cache (no fresh login shell), when nothing had looked there yet.
    @Test func aTasksResolutionIsProjectedWithoutASecondShell() async throws {
        let made = try make(World(name: "task", connected: ["claude"], claude: .loginPath, shellToken: true, ready: true))
        defer { made.clean() }
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: made.consent)
        var looks: [(login: Bool, fresh: Bool)] = []
        setup.lookAgain = { fresh in
            await setup.look(fresh: fresh, find: { login in looks.append((login, fresh)); return login ? made.terminal : made.files },
                             readStatus: { AgentSetup.Status() }, plans: made.plans,
                             readIdentity: { await PlanAccounts.read($0, env: $1, revision: $2, keychain: { _ in false }) })
        }
        setup.taskResolved()
        await settle { setup.signedIn["claude"] != nil }
        #expect(looks.count == 1)
        #expect(looks.first?.login == true && looks.first?.fresh == false)
        #expect(setup.signedIn["claude"] == true)
        setup.taskResolved()
        await settle()
        #expect(looks.count == 1, "Looked at where tasks run already")
    }

    /// The extra account readiness found signed in is the one the task
    /// starts on: the launcher's pick reads what the look read.
    @Test func theTaskStartsOnTheAccountTheLookFoundSignedIn() async throws {
        let made = try make(World(name: "extra", connected: ["claude"], claude: .files, claudeExtra: true, ready: true))
        defer { made.clean() }
        let setup = AgentSetupModel(status: AgentSetup.Status(claude: true), consent: made.consent)
        #expect(AgentLaunch.resolve("claude", in: made.terminal, plans: made.plans)?.account?.id == "claude",
                "Before any look the usual account is tried first")
        await setup.look(find: { _ in made.terminal }, readStatus: { AgentSetup.Status() }, plans: made.plans,
                         readIdentity: { await PlanAccounts.read($0, env: $1, revision: $2, keychain: { _ in false }) })
        let launch = try #require(AgentLaunch.resolve("claude", in: made.terminal, plans: made.plans))
        #expect(launch.account?.id == "claude.extra1")
        #expect(launch.configDir == made.home.appendingPathComponent("claude-extra").path)
        #expect(launch.env[Shell.claudeToken] == nil, "Your token is the usual account's only")
    }

    /// Where the sign-in comes from, as the launch resolves it.
    @Test func tokenSourceAndAccountFolderComeFromTheResolution() async throws {
        let made = try make(World(name: "token", connected: ["claude"], claude: .loginPath, shellToken: true, ready: true))
        defer { made.clean() }
        let launch = try #require(AgentLaunch.resolve("claude", in: made.terminal, plans: made.plans))
        #expect(launch.binary == made.home.appendingPathComponent("tools/bin/claude").path)
        #expect(launch.token == .exported)
        #expect(launch.configDir == made.home.appendingPathComponent("claude-usual").path)
        #expect(AgentLaunch.resolve("claude", in: made.files, plans: made.plans) == nil, "Files alone can't show this copy")
    }

    /// Which agent a chat goes to (AgentModels.here, Agents.installed) asks
    /// the same: files alone never rule out a connected Claude the login
    /// shell's PATH may hold; the terminal environment, once known, decides.
    @Test func hereIsWhatATaskWouldFind() async throws {
        let made = try make(World(name: "here", connected: ["claude"], claude: .loginPath, shellToken: true, ready: true))
        defer { made.clean() }
        #expect(AgentLaunch.here("claude", terminal: nil, files: nil, consent: made.consent) == nil)
        #expect(AgentLaunch.here("claude", terminal: nil, files: made.files, consent: made.consent) == true)
        #expect(AgentLaunch.here("codex", terminal: nil, files: made.files, consent: made.consent) == false, "Not connected, files decide")
        #expect(AgentLaunch.here("claude", terminal: made.terminal, files: made.files, consent: made.consent) == true)
        #expect(AgentLaunch.here("codex", terminal: made.terminal, files: made.files, consent: made.consent) == false)
        made.consent.revoke("claude")
        #expect(AgentLaunch.here("claude", terminal: nil, files: made.files, consent: made.consent) == false)
    }

    /// A look reads an account in exactly the environment its task gets,
    /// less a keyed account's secret, which a look never loads.
    @Test func aLookReadsTheEnvironmentTheTaskGets() async throws {
        let made = try make(World(name: "env", connected: ["claude", "codex"], claude: .files, codex: .files, shellToken: true,
                                  claudeExtra: true, codexExtra: true, ready: true))
        defer { made.clean() }
        for cli in AgentLaunch.terminalCLIs {
            for account in made.plans.all(cli) {
                #expect(AgentLaunch.lookEnvironment(account, in: made.terminal)
                        == AgentLaunch.on(account, cli: cli, binary: "/fixture/" + cli, in: made.terminal, plans: made.plans).env)
            }
        }
    }
}
