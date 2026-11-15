import Foundation
import Testing
@testable import Fast

@MainActor
struct PlanReadinessRaceTests {
    @Test func rememberedLogoutStillInvalidatesAnOlderPositiveRead() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("yab-remember-logout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "remember-logout-" + UUID().uuidString
        let settings = UserDefaults(suiteName: name)!
        defer { settings.removePersistentDomain(forName: name) }
        let account = PlanAccount(id: "claude", cli: "claude", home: home.path, email: "known@example.test", plan: "pro")
        settings.set(try JSONEncoder().encode(["claude": account]), forKey: "plans.usual")
        let consent = ProviderConsent(settings: settings, history: [])
        consent.grant("claude")
        let plans = PlanAccounts(settings: settings, consent: consent)
        let release = DispatchSemaphore(value: 0)
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let refresh = Task {
            await plans.look(Shell.Found(claude: "/fixture/claude", env: [:])) { _ in
                didStart.yield(())
                _ = release.wait(timeout: .now() + 5)
                return true
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        let binary = home.appendingPathComponent("claude-fixture")
        try """
        #!/bin/sh
        printf '%s\\n' '{"loggedIn":false,"email":"known@example.test","subscriptionType":"pro"}'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        await plans.remember(account, binary: binary.path, base: ["PATH": "/usr/bin:/bin"])
        #expect(plans.account("claude") == account)
        #expect(plans.signedOut.contains("claude"))
        release.signal()
        await refresh.value
        #expect(plans.signedOut.contains("claude"), "Real remembered logout must still reject an older positive keychain read")
        didStart.finish()
    }

    /// Both actual production layers await one keychain lookup. Force the
    /// passive account refresh to apply first, then let the real setup
    /// projection resume its original revision guard and readiness write.
    @Test(arguments: ["no-metadata", "retained-metadata", "empty-oauth-config"])
    func overlappingLogoutRefreshClearsTaskReadiness(variant: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("yab-readiness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "readiness-" + UUID().uuidString
        let settings = UserDefaults(suiteName: name)!
        defer { settings.removePersistentDomain(forName: name) }
        let retainedMetadata = variant == "retained-metadata"
        if variant == "empty-oauth-config" {
            try #"{"oauthAccount":{"emailAddress":"","accountUuid":""}}"#.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        }
        let account = PlanAccount(id: "claude", cli: "claude", home: home.path,
                                  email: retainedMetadata ? "known@example.test" : nil,
                                  plan: retainedMetadata ? "pro" : nil)
        settings.set(try JSONEncoder().encode(["claude": account]), forKey: "plans.usual")
        let plans = PlanAccounts(settings: settings)
        let status = AgentSetup.Status(claude: true)
        let consent = ProviderConsent(settings: settings, history: [])
        consent.grant("claude")
        let setup = AgentSetupModel(status: status, consent: consent)
        let found = Shell.Found(claude: "/fixture/claude", env: ["CLAUDE_CONFIG_DIR": home.path])
        var signedIn = found
        signedIn.env["ANTHROPIC_API_KEY"] = "fixture-key"
        await setup.look(find: { _ in signedIn }, readStatus: { status }, plans: plans)
        #expect(setup.signedIn["claude"] == true)
        #expect(setup.canRunTasks())

        let release = DispatchSemaphore(value: 0)
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let accountRefresh = Task {
            await plans.look(found) { _ in
                didStart.yield(())
                _ = release.wait(timeout: .now() + 5)
                return false
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        let (joined, didJoin) = AsyncStream<Void>.makeStream()
        let readinessRefresh = Task {
            await setup.look(find: { _ in found }, readStatus: { status }, plans: plans,
                             readIdentity: { account, env, revision in
                didJoin.yield(())
                let who = await PlanAccounts.read(account, env: env, revision: revision, keychain: { _ in
                    Issue.record("setup must join the pending query")
                    return false
                })
                await accountRefresh.value
                return who
            })
        }
        var joins = joined.makeAsyncIterator()
        _ = await joins.next()
        release.signal()
        await accountRefresh.value
        await readinessRefresh.value
        #expect(plans.signedOut.contains("claude"))
        #expect(plans.account("claude") == account, "Logout keeps the remembered account metadata")
        #expect(setup.signedIn["claude"] == false, "The real setup projection must apply the shared negative read")
        #expect(!setup.canRunTasks(), "A completed logout must clear previously true task readiness")
        didStart.finish()
        didJoin.finish()
    }
}
