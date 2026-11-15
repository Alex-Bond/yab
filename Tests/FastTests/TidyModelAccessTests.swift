import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct TidyModelAccessTests {
    @Test func appleTidyWorksWithEveryOtherAISwitchOff() async {
        let keys = ["ai.use", "models.mac.disabled", "tidy.tabs"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        let stand = TidyTabs.benchAnswer
        defer {
            for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) }
            TidyTabs.benchAnswer = stand
        }
        TidyTabs.benchAnswer = nil
        Store.settings.set(true, forKey: "models.mac.disabled")
        Store.settings.set(true, forKey: "tidy.tabs")
        for level in ["off", "asked", "on"] {
            Store.settings.set(level, forKey: "ai.use")
            #expect(!FormModel.ready)
            let ready = FormModel.permitsTidy { true }
            #expect(ready)
            #expect(TidyTabs.available(stand: false, agents: [], apple: ready))
            var requests = 0
            let groups = await TidyTabs.groups(["Trip", "Hotel"], writer: { _ in ("", nil) }, localModel: { _ in
                requests += 1
                guard FormModel.permitsTidy(availability: { true }) else { return nil }
                return #"{"groups":[{"name":"Travel","tabs":[1,2]}]}"#
            })
            #expect(requests == 1)
            #expect(groups == [TidyTabs.Group(name: "Travel", tabs: [0, 1])])
        }
        Store.settings.set(false, forKey: "tidy.tabs")
        let groups = await TidyTabs.groups(["Trip", "Hotel"], writer: { _ in
            Issue.record("Tidy off must not call a provider"); return ("", nil)
        }, localModel: { _ in
            Issue.record("Tidy off must not call Apple Intelligence"); return nil
        })
        #expect(groups == nil)
        Store.settings.set(true, forKey: "tidy.tabs")
        let stopped = await TidyTabs.groups(["Trip", "Hotel"], writer: { _ in
            Store.settings.set(false, forKey: "tidy.tabs")
            return ("", nil)
        }, localModel: { _ in
            Issue.record("Turning Tidy off while waiting must stop the local fallback"); return nil
        })
        #expect(stopped == nil)
    }

    @Test func missingModelsStayUnavailable() {
        #expect(!FormModel.permitsTidy { false })
        #expect(!TidyTabs.available(stand: false, agents: [], apple: false))
        for cli in ["claude", "codex"] {
            #expect(TidyTabs.available(stand: false, agents: [cli], apple: false))
        }
    }

    @Test func carriedConnectionDoesNotNeedOtherFeaturesConsent() {
        let domain = "tidy-migration-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        settings.set(true, forKey: "agents.consent-migrated.v1")
        settings.set(["claude", "codex"], forKey: "agents.revoked-connections.v1")
        settings.set("off", forKey: "ai.use")
        let consent = ProviderConsent(settings: settings, history: [])
        for cli in ["claude", "codex"] {
            var status = AgentSetup.Status()
            if cli == "claude" { status.claude = true } else { status.codex = true }
            let setup = AgentSetupModel(status: status, consent: consent)
            #expect(TidyTabs.connectedProviders(in: setup) == [cli])
            #expect(!consent.allows(cli))
        }
        let noConnection = AgentSetupModel(status: AgentSetup.Status(), consent: consent)
        #expect(TidyTabs.connectedProviders(in: noConnection).isEmpty)
        #expect(settings.object(forKey: "tidy.tabs") == nil)
    }

    @Test func tidyAuthorityDoesNotGrantOtherFeaturesConsent() {
        let domain = "tidy-authority-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        settings.set("off", forKey: "ai.use")
        let consent = ProviderConsent(settings: settings, history: [])
        consent.revoke("claude")
        // A migrated profile without tidy.tabs retains the old default: on.
        let permit = ProviderLaunchPermit(authority: "tidy", cli: "claude", epoch: UUID().uuidString,
                                          settings: settings, tidy: true)
        #expect(permit.valid)
        #expect(!consent.allows("claude"))
        #expect(consent.permit("claude") == nil)
        settings.set(false, forKey: "tidy.tabs")
        #expect(!permit.valid)
        settings.set(true, forKey: "tidy.tabs")
        #expect(permit.valid)
        #expect(!consent.allows("claude"))
        #expect(settings.string(forKey: "ai.use") == "off")
    }
}
