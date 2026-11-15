import Foundation
import Testing
@testable import Fast

@MainActor
struct OriginalConnectPermitTests {
    @Test func aReplacementAccountAttemptCannotBecomeAnOlderQueuedConnect() async throws {
        let domain = "original-connect-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        defer { consent.cancelConnections() }
        consent.beginConnection("claude")
        consent.beginConnection("codex")
        let original = try #require(consent.connectionPermits(["claude", "codex"]))
        let claude = try #require(original["claude"])
        var release: AsyncStream<Void>.Continuation!
        let paused = AsyncStream<Void> { release = $0 }
        let queued = Task { @MainActor in
            for await _ in paused { break }
            // This is the actual login admission with the original permit,
            // resumed after another account action replaces the same CLI.
            return await Agents().connect("claude", binary: "/fixture/no-account-cli", env: [:], in: nil, permit: claude)
        }
        consent.beginConnection("claude")
        let replacement = try #require(consent.connectionPermit("claude"))
        #expect(replacement.epoch != claude.epoch && replacement.valid)
        #expect(!original.values.allSatisfy { $0.valid })
        #expect(original["codex"]?.valid == true)
        #expect(!consent.allows("claude"))
        release.yield(()); release.finish()
        #expect(await queued.value == .canceled)
        #expect(replacement.valid && !consent.allows("claude"), "The older continuation cannot consume or grant the replacement")
    }

    @Test func theCapturedConnectionMapRequiresEveryRequestedOriginal() throws {
        let domain = "complete-connect-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        defer { consent.cancelConnections() }
        consent.beginConnection("claude")
        #expect(consent.connectionPermits(["claude", "codex"]) == nil)
        let captured = try #require(consent.connectionPermits(["claude"]))
        consent.cancelConnections()
        consent.beginConnection("claude")
        #expect(captured["claude"]?.valid == false)
        #expect(consent.connectionPermits(["claude"])?.values.allSatisfy { $0.valid } == true)
    }

    @Test func replacedSignInCannotLaunchLogoutOrDeleteItsCandidateHome() async throws {
        let domain = "old-signin-cleanup-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        defer { consent.cancelConnections() }
        consent.beginConnection("claude")
        let original = try #require(consent.connectionPermit("claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("preserved.txt")
        try "synthetic candidate".write(to: marker, atomically: true, encoding: .utf8)
        let account = PlanAccount(id: "claude.synthetic", cli: "claude", home: root.path)
        consent.beginConnection("claude")
        let plans = PlanAccounts(settings: settings, consent: consent)
        // An invalid permit must return before environment/credential lookup
        // or any worker launch. A nonexistent binary is never invoked.
        await plans.discardSignIn(account, binary: "/fixture/no-account-cli", base: [:], permit: original)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "synthetic candidate")
        #expect(consent.connectionPermit("claude")?.valid == true)
    }

    @Test func geminiMetadataWaitRetainsTheSuppliedAttemptAcrossDiscovery() async throws {
        let domain = "gemini-original-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        defer { consent.cancelConnections() }
        consent.beginConnection("gemini")
        let original = try #require(consent.connectionPermit("gemini"))
        let account = GeminiAccount(binary: "/fixture/original-metadata")
        await account.look(fresh: true, permit: original, find: { _ in
            consent.beginConnection("gemini")
            return Shell.Found(claude: nil, codex: nil, gemini: nil, env: [:])
        })
        #expect(account.binary == "/fixture/original-metadata")
        account.signIn(permit: original)
        #expect(account.waiting == nil, "A stale sign-in cannot create a Terminal/poll or use the replacement attempt")
    }
}
