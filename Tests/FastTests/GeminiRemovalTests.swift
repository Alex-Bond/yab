import Foundation
import Testing
@testable import Fast

@Suite(.serialized) @MainActor
struct GeminiRemovalTests {
    private func world(_ body: (AgentSetupModel, ProviderConsent, UserDefaults) async throws -> Void) async throws {
        let fixture = IsolatedProviderConsent("gemini")
        let account = GeminiAccount.shared
        let old = (account.binary, account.signedIn, account.enabled, account.models.map(\.model).joined(separator: "\n"))
        defer {
            fixture.close()
            account.enabled = old.2
            account.pretend(binary: old.0, signedIn: old.1, models: old.3)
        }
        // Discover without launching a provider or touching its profile.
        fixture.consent.revoke("gemini")
        let setup = AgentSetupModel(status: AgentSetup.Status(), consent: fixture.consent)
        await setup.look(find: { _ in Shell.Found(claude: nil, gemini: "/fixture/agy", env: [:]) },
                         readStatus: { AgentSetup.Status() })
        fixture.consent.grant("gemini")
        account.enabled = true
        account.pretend(binary: "/fixture/agy", signedIn: true, models: "gemini-3-flash")
        defer { setup.cancel() }
        try await body(setup, fixture.consent, fixture.settings)
    }

    @Test func removeRevokesRunningAndQueuedWorkAndSurvivesReload() async throws {
        try await world { setup, consent, settings in
            let account = GeminiAccount.shared
            let permit = try #require(consent.permit("gemini"))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/cat")
            child.standardInput = Pipe()
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            defer { if child.isRunning { child.terminate() } }
            #expect(try permit.start(child))
            #expect(setup.showsGemini && account.ready)
            setup.disconnect(["gemini"], Browser(windowID: UUID()))
            child.waitUntilExit()
            #expect(!child.isRunning && !permit.valid)
            #expect(!setup.showsGemini && !account.ready && !setup.connected("gemini"))
            #expect(!AgentModels.here("gemini") && ModelDefaults.shared.automatic(.chats) != "gemini")
            #expect(!GeminiAccount(binary: "/fixture/agy").enabled)
            #expect(!ProviderConsent(settings: settings, history: []).allows("gemini"))
            var looked = false
            await account.look(fresh: true, permit: permit, find: { _ in
                looked = true
                return Shell.Found(claude: nil, gemini: "/fixture/agy", env: [:])
            })
            #expect(!looked && !account.enabled, "A late refresh cannot restore removal")
            let queued = Process()
            queued.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            #expect(try !permit.start(queued))
            consent.beginConnection("gemini")
            #expect(consent.connectionPermit("gemini")?.valid == true)
            #expect(!permit.valid, "Re-add cannot revive a queued turn from before removal")
            setup.cancel()
        }
    }

    @Test func removeCancelsEveryStageOfAnExistingConnection() async throws {
        try await world { setup, consent, _ in
            let stages: [AgentSetupModel.Flow] = [.preparing(["gemini"]), .installing("gemini"),
                .signingIn("gemini"), .finishing(["gemini"]), .landed(["gemini"]), .asking(["gemini"])]
            for stage in stages {
                consent.beginConnection("gemini")
                let pending = try #require(consent.connectionPermit("gemini"))
                GeminiAccount.shared.enabled = true
                setup.flow = stage
                setup.disconnect(["gemini"], Browser(windowID: UUID()))
                #expect(setup.flow == nil && GeminiAccount.shared.waiting == nil)
                #expect(!pending.valid && !GeminiAccount.shared.enabled)
            }
        }
    }

    @Test func addAnInstalledGeminiChoosesAnAccountWithoutCreatingAProfile() async throws {
        try await world { setup, consent, _ in
            let before = PlanAccounts.shared.all("gemini")
            for connected in [true, false] {
                if connected { consent.grant("gemini") } else { consent.revoke("gemini") }
                GeminiAccount.shared.enabled = connected
                setup.addAccount("gemini", Browser(windowID: UUID()))
                #expect(setup.flow == nil && GeminiChoices.shared.showing)
                #expect(consent.connectionPermit("gemini")?.valid == true)
                #expect(PlanAccounts.shared.all("gemini") == before)
                setup.cancel()
            }
        }
    }

    @Test func missingCLIHasNoPermanentRowAndAddStartsSetup() async throws {
        try await world { setup, consent, _ in
            consent.revoke("gemini")
            await setup.look(find: { _ in Shell.Found(claude: nil, env: [:]) }, readStatus: { AgentSetup.Status() })
            #expect(!setup.showsGemini)
            setup.addAccount("gemini", Browser(windowID: UUID()))
            #expect(setup.flow == .installing("gemini"))
            #expect(PlanAccounts.shared.adding == nil)
            setup.cancel()
        }
    }
}
