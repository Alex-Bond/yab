import Foundation
import Testing
@testable import Fast

/// #653: another app's CLI login is an offer, never permission to run it.
@MainActor
struct ProviderConsentRegressionTests {
    @Test func signedInCLIWithoutYabConnectCannotTakeTasks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("yab-consent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let domain = "provider-consent-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let account = PlanAccount(id: "claude", cli: "claude", home: home.path)
        settings.set(try JSONEncoder().encode(["claude": account]), forKey: "plans.usual")
        let plans = PlanAccounts(settings: settings)
        let status = AgentSetup.Status()
        let setup = AgentSetupModel(status: status, consent: ProviderConsent(settings: settings, history: []))
        let found = Shell.Found(claude: home.appendingPathComponent("claude-fixture").path,
                                env: ["HOME": home.path, "CLAUDE_CONFIG_DIR": home.path,
                                      "ANTHROPIC_API_KEY": "fixture-key"])
        await setup.look(find: { _ in found }, readStatus: { status }, plans: plans)
        #expect(setup.signedIn["claude"] == true, "The real passive reader must see the synthetic login")
        #expect(!setup.connected("claude"), "No Connect was pressed in this profile")
        #expect(!setup.canRunTasks(), "A CLI signed in outside Yab must not make task dispatch ready")
    }
}
