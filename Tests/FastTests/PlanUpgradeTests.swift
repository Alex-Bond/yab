import Foundation
import Testing
@testable import Fast

// A ChatGPT plan changed after Connect (feedback #734: Free, then Plus).
// Codex's id token keeps the plan it was minted with until Codex renews
// it, so the plan Codex's server says with its limits stands until then,
// and an account the server disagrees with has its token renewed by Codex.
// Every Codex here is a stand-in in a temporary folder; no real ~/.codex
// is read or written.
@MainActor
struct PlanUpgradeTests {
    private struct World {
        let root: URL
        let home: URL
        let settings: UserDefaults
        let suite: String
        let consent: ProviderConsent

        func close() {
            settings.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let id = "codex.upgr01"

    /// An extra Codex account in its own folder, signed in on `plan`.
    private func world(plan: String) throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-plan-upgrade-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try signIn(home, plan: plan)
        let suite = "dev.serafim.fast.test.plan-upgrade." + UUID().uuidString
        let settings = UserDefaults(suiteName: suite)!
        let account = PlanAccount(id: Self.id, cli: "codex", home: home.path, email: "me@example.com", plan: plan)
        settings.set(try JSONEncoder().encode([account]), forKey: "plans.accounts")
        // The usual account is left out of every ask: it is ~/.codex.
        settings.set(["codex"], forKey: "plans.signedOut")
        let consent = ProviderConsent(settings: settings, history: [])
        if !consent.allows("codex") { consent.grant("codex") }
        return World(root: root, home: home, settings: settings, suite: suite, consent: consent)
    }

    private func token(plan: String) -> String {
        let claims = try! JSONSerialization.data(withJSONObject: [
            "email": "me@example.com", "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
        ])
        let body = claims.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "x." + body + ".y"
    }

    private func authData(plan: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": [
            "id_token": token(plan: plan), "access_token": "a", "refresh_token": "r",
        ]])
    }

    private func signIn(_ home: URL, plan: String) throws {
        try authData(plan: plan).write(to: home.appendingPathComponent("auth.json"))
    }

    private func usage(plan: String?) -> [String: Any] {
        var limits: [String: Any] = [
            "primary": ["usedPercent": 10, "windowDurationMins": 300, "resetsAt": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)],
            "secondary": NSNull(), "rateLimitReachedType": NSNull(),
        ]
        limits["planType"] = plan ?? NSNull()
        return ["ordinaryUsageAllowed": true, "rateLimits": limits]
    }

    /// A Codex that answers app-server's usage read with `answer`, and on
    /// account/read renews its sign-in to `renewed` when one is given.
    private func codex(in world: World, answer: [String: Any], renewed: String?) throws -> (found: Shell.Found, log: URL) {
        let binary = world.root.appendingPathComponent("codex")
        let log = world.root.appendingPathComponent("requests.jsonl")
        let reply = world.root.appendingPathComponent("reply.json")
        let renewal = world.root.appendingPathComponent("renewed.json")
        try """
        #!/bin/sh
        [ "$1" = "app-server" ] || exit 1
        renew=0
        for count in 1 2 3; do
          IFS= read -r line || exit 1
          printf '%s\\n' "$line" >> "$PLAN_LOG"
          case "$line" in *refreshToken*) renew=1 ;; esac
        done
        if [ "$renew" = "1" ]; then
          [ -f "$PLAN_RENEWED" ] && /bin/cp "$PLAN_RENEWED" "$CODEX_HOME/auth.json"
          printf '%s\\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
        else
          /bin/cat "$PLAN_REPLY"
          printf '\\n'
        fi
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try JSONSerialization.data(withJSONObject: ["id": 2, "result": answer]).write(to: reply)
        if let renewed { try authData(plan: renewed).write(to: renewal) }
        let found = Shell.Found(codex: binary.path, env: ["PLAN_LOG": log.path, "PLAN_REPLY": reply.path, "PLAN_RENEWED": renewal.path])
        return (found, log)
    }

    private func methods(in log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String
        }
    }

    @Test func aPlanIsReadAsCodexsServerNamesIt() {
        #expect(PlanAccounts.planName("plus") == "plus")
        #expect(PlanAccounts.planName("Plus") == "plus")
        #expect(PlanAccounts.planName("prolite") == "prolite")
        #expect(PlanAccounts.planName("unknown") == nil)
        #expect(PlanAccounts.planName("") == nil)
        #expect(PlanAccounts.planName(nil) == nil)
        #expect(PlanAccounts.planName(NSNull()) == nil)
        #expect(PlanAccounts.planName(3) == nil)
        #expect(PlanAccounts.tier("codex", "plus") == "Plus")
    }

    @Test func theTokensPlanIsReadFromItsAuthFile() throws {
        let world = try world(plan: "free")
        defer { world.close() }
        #expect(PlanAccounts.codexAuth(home: world.home.path).plan == "free")
        try signIn(world.home, plan: "plus")
        let auth = PlanAccounts.codexAuth(home: world.home.path)
        #expect(auth.signedIn && auth.email == "me@example.com" && auth.plan == "plus")
        #expect(!PlanAccounts.codexAuth(home: world.root.appendingPathComponent("none").path).signedIn)
    }

    @Test func theServersPlanStandsUntilTheTokenChanges() async throws {
        let world = try world(plan: "free")
        defer { world.close() }
        let accounts = PlanAccounts(settings: world.settings, consent: world.consent)
        #expect(accounts.account(Self.id)?.plan == "free")

        // The usage read says Plus; the token still says Free.
        accounts.heard(codexAsked: usage(plan: "plus"), on: Self.id)
        #expect(accounts.account(Self.id)?.plan == "plus")
        #expect(accounts.heardPlans[Self.id] == HeardPlan(plan: "plus", token: "free"))

        // Kept across a relaunch, and a passive look at the stale token
        // doesn't take it back to Free.
        let relaunched = PlanAccounts(settings: world.settings, consent: world.consent)
        #expect(relaunched.account(Self.id)?.plan == "plus")
        let never = world.root.appendingPathComponent("never-run")
        let found = Shell.Found(codex: never.path, env: [:])
        await relaunched.look(found)
        #expect(relaunched.account(Self.id)?.plan == "plus")

        // Codex renewed its token: the token's word is newer, and stands.
        try signIn(world.home, plan: "plus")
        await relaunched.look(found)
        #expect(relaunched.account(Self.id)?.plan == "plus")
        #expect(relaunched.heardPlans[Self.id] == nil)
        try signIn(world.home, plan: "pro")
        await relaunched.look(found)
        #expect(relaunched.account(Self.id)?.plan == "pro")
        #expect(PlanAccounts(settings: world.settings, consent: world.consent).heardPlans.isEmpty)
    }

    @Test func aServerThatAgreesWithTheTokenLeavesNothingAhead() throws {
        let world = try world(plan: "plus")
        defer { world.close() }
        let accounts = PlanAccounts(settings: world.settings, consent: world.consent)
        accounts.heard(codexAsked: usage(plan: "plus"), on: Self.id)
        accounts.heard(codexAsked: usage(plan: "unknown"), on: Self.id)
        accounts.heard(codexAsked: usage(plan: nil), on: Self.id)
        #expect(accounts.account(Self.id)?.plan == "plus")
        #expect(accounts.heardPlans.isEmpty)
        // Limits as a task's conversation file keeps them, snake_case.
        accounts.heard(codex: ["primary": ["used_percent": 5, "window_minutes": 300], "plan_type": "pro"], on: Self.id)
        #expect(accounts.account(Self.id)?.plan == "pro")
        #expect(accounts.heardPlans[Self.id] == HeardPlan(plan: "pro", token: "plus"))
    }

    @Test func aPlanAheadOfTheTokenHasCodexRenewIt() async throws {
        let world = try world(plan: "free")
        defer { world.close() }
        let accounts = PlanAccounts(settings: world.settings, consent: world.consent)
        let probe = try codex(in: world, answer: usage(plan: "plus"), renewed: "plus")

        await accounts.ask("codex", found: probe.found)

        #expect(methods(in: probe.log) == ["initialize", "initialized", "account/rateLimits/read",
                                           "initialize", "initialized", "account/read"])
        let asked = try String(contentsOf: probe.log, encoding: .utf8).split(separator: "\n").last.map(String.init) ?? ""
        #expect(asked.contains(#""refreshToken":true"#))
        #expect(PlanAccounts.codexAuth(home: world.home.path).plan == "plus")
        #expect(accounts.account(Self.id)?.plan == "plus")
        #expect(accounts.heardPlans[Self.id] == nil)
    }

    @Test func aRenewalThatChangesNothingKeepsTheServersPlanAndWaits() async throws {
        let world = try world(plan: "free")
        defer { world.close() }
        let accounts = PlanAccounts(settings: world.settings, consent: world.consent)
        let probe = try codex(in: world, answer: usage(plan: "plus"), renewed: nil)

        await accounts.ask("codex", found: probe.found)
        #expect(methods(in: probe.log).last == "account/read")
        #expect(accounts.account(Self.id)?.plan == "plus")
        #expect(accounts.heardPlans[Self.id] == HeardPlan(plan: "plus", token: "free"))

        // A blocked plan is asked again at once; its token isn't renewed
        // again within the hour.
        accounts.ranOut(Self.id)
        await accounts.ask("codex", found: probe.found, refreshBlocked: true)
        #expect(methods(in: probe.log).filter { $0 == "account/read" }.count == 1)
        #expect(methods(in: probe.log).filter { $0 == "account/rateLimits/read" }.count == 2)
    }

    @Test func aPlanTheTokenAgreesWithRunsNoRenewal() async throws {
        let world = try world(plan: "plus")
        defer { world.close() }
        let accounts = PlanAccounts(settings: world.settings, consent: world.consent)
        let probe = try codex(in: world, answer: usage(plan: "plus"), renewed: "pro")

        await accounts.ask("codex", found: probe.found)

        #expect(methods(in: probe.log) == ["initialize", "initialized", "account/rateLimits/read"])
        #expect(PlanAccounts.codexAuth(home: world.home.path).plan == "plus")
    }

    @Test func aNewSignInDropsThePlanHeardAheadOfTheOldToken() throws {
        let world = try world(plan: "free")
        defer { world.close() }
        let accounts = PlanAccounts(settings: world.settings, consent: world.consent)
        accounts.heard(codexAsked: usage(plan: "plus"), on: Self.id)
        #expect(accounts.heardPlans[Self.id] != nil)
        let renewed = PlanAccount(id: "codex.upgr02", cli: "codex", home: world.home.path, email: "me@example.com", plan: "go")
        let kept = accounts.acceptSignIn(renewed, replacing: Self.id)
        #expect(kept.id == Self.id && kept.plan == "go")
        #expect(accounts.heardPlans.isEmpty)
    }
}
