import Foundation
import Testing
@testable import Fast

@MainActor
struct PlanKeychainRefreshTests {
    private final class Gate: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        private var count = 0
        private var ended = false
        var calls: Int { lock.withLock { count } }
        var completed: Bool { lock.withLock { ended } }

        func read(started: AsyncStream<Void>.Continuation, result: Bool) -> Bool {
            lock.withLock { count += 1 }
            started.yield(())
            _ = release.wait(timeout: .now() + 5)
            lock.withLock { ended = true }
            return result
        }
    }

    private func folder() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("yab-keychain-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func repeatedRefreshesShareOneBlockedKeychainCall() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let gate = Gate()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        var readers = 0
        let pending = (0..<12).map { _ in
            Task { @MainActor in
                readers += 1
                if readers == 12 { didEnter.yield(()) }
                return await PlanAccounts.read("claude", env: ["CLAUDE_CONFIG_DIR": home.path]) { _ in
                    gate.read(started: didStart, result: true)
                }
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        var entries = entered.makeAsyncIterator()
        _ = await entries.next()
        #expect(gate.calls == 1)
        gate.release.signal()
        for task in pending { #expect(await task.value.signedIn) }
        #expect(gate.calls == 1)
        didStart.finish()
        didEnter.finish()
    }

    @Test func pendingRefreshKeepsCachedIdentityAndCannotUndoSignIn() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "keychain-refresh-" + UUID().uuidString
        let settings = UserDefaults(suiteName: name)!
        defer { settings.removePersistentDomain(forName: name) }
        let account = PlanAccount(id: "claude", cli: "claude", home: home.path, email: "known@example.test")
        settings.set(try JSONEncoder().encode(["claude": account]), forKey: "plans.usual")
        settings.set(["claude"], forKey: "plans.signedOut")
        let plans = PlanAccounts(settings: settings)
        let gate = Gate()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let refresh = Task {
            await plans.look(Shell.Found(claude: "/fixture/claude", env: [:])) { _ in
                gate.read(started: didStart, result: false)
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        #expect(plans.account("claude") == account)
        #expect(plans.signedOut.contains("claude"))
        plans.acceptSignIn(account, replacing: account.id)
        #expect(!plans.signedOut.contains("claude"))
        gate.release.signal()
        await refresh.value
        #expect(plans.account("claude") == account)
        #expect(!plans.signedOut.contains("claude"), "An older negative read must not undo a completed login")
        didStart.finish()
    }

    @Test func passiveIdentityKeepsTokensInTheUsualAccountOnly() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["CLAUDE_CONFIG_DIR": home.path, "ANTHROPIC_API_KEY": "fixture-key", "CLAUDE_CODE_OAUTH_TOKEN": "fixture-token"]
        let usual = PlanAccount(id: "claude", cli: "claude", home: home.path)
        let extra = PlanAccount(id: "claude.other", cli: "claude", home: home.path)
        #expect((await PlanAccounts.read(usual, env: env, keychain: { _ in false })).signedIn)
        #expect(!(await PlanAccounts.read(extra, env: env, keychain: { _ in false })).signedIn)
    }

    @Test func aRefreshAfterSignInDoesNotReuseAnOlderNegativeRead() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "keychain-signed-in-" + UUID().uuidString
        let settings = UserDefaults(suiteName: name)!
        defer { settings.removePersistentDomain(forName: name) }
        let account = PlanAccount(id: "claude", cli: "claude", home: home.path, email: "known@example.test")
        settings.set(try JSONEncoder().encode(["claude": account]), forKey: "plans.usual")
        let plans = PlanAccounts(settings: settings)
        let gate = Gate()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let found = Shell.Found(claude: "/fixture/claude", env: [:])
        let old = Task {
            await plans.look(found) { _ in gate.read(started: didStart, result: false) }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        plans.acceptSignIn(account, replacing: account.id)
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        let fresh = Task {
            didEnter.yield(())
            await plans.look(found, keychain: { _ in true })
        }
        var entries = entered.makeAsyncIterator()
        _ = await entries.next()
        gate.release.signal()
        await old.value
        await fresh.value
        #expect(!plans.signedOut.contains("claude"), "A new refresh must query the post-login state")
        didStart.finish()
        didEnter.finish()
    }

    @Test func anAccountRemovedDuringRefreshStaysRemoved() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "keychain-removed-" + UUID().uuidString
        let settings = UserDefaults(suiteName: name)!
        defer { settings.removePersistentDomain(forName: name) }
        // No managed folder means Remove cannot launch a logout or remove
        // any files after the in-memory row goes away.
        let extra = PlanAccount(id: "claude.other", cli: "claude")
        settings.set(try JSONEncoder().encode([extra]), forKey: "plans.accounts")
        let plans = PlanAccounts(settings: settings)
        let gate = Gate()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let refresh = Task {
            await plans.look(Shell.Found(claude: "/fixture/claude", env: ["CLAUDE_CONFIG_DIR": home.path, "ANTHROPIC_API_KEY": "fixture-key"])) { _ in
                gate.read(started: didStart, result: false)
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        plans.remove(extra.id)
        gate.release.signal()
        await refresh.value
        #expect(plans.account(extra.id) == nil)
        #expect(!plans.signedOut.contains(extra.id))
        #expect(!PlanAccounts(settings: settings).extras.contains { $0.id == extra.id })
        didStart.finish()
    }

    @Test func fileOnlyCodexReadDoesNotWaitBehindClaudeKeychain() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let gate = Gate()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let refresh = Task {
            await PlanAccounts.read("claude", env: ["CLAUDE_CONFIG_DIR": home.path]) { _ in
                gate.read(started: didStart, result: true)
            }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        let codex = await PlanAccounts.read("codex", env: ["CODEX_HOME": home.path]) { _ in
            Issue.record("Codex's file-only read must not ask the keychain")
            return false
        }
        #expect(!codex.signedIn)
        #expect(!gate.completed, "Codex must return while Claude's keychain call is still blocked")
        gate.release.signal()
        #expect(await refresh.value.signedIn)
        didStart.finish()
    }

    @Test func passiveKeyPresenceUsesTheActorOwnedCache() async {
        let id = "claude.presence-" + UUID().uuidString
        AgentKey.keep(id, key: "fixture-key")
        #expect(await AgentKey.hasSecret(id))
        AgentKey.keep(id, key: nil)
        #expect(!(await AgentKey.hasSecret(id)))
    }
}
