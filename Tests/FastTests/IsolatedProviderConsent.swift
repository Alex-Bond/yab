import Foundation
@testable import Fast

/// Explicit provider authority confined to one synthetic test profile.
@MainActor
struct IsolatedProviderConsent {
    let name: String
    let settings: UserDefaults
    let consent: ProviderConsent

    init(_ cli: String) {
        name = "isolated-provider-" + UUID().uuidString
        settings = UserDefaults(suiteName: name)!
        consent = ProviderConsent(settings: settings, history: [])
        consent.grant(cli)
    }

    func close() {
        consent.cancelConnections()
        for cli in AgentPlan.clis where consent.allows(cli) { consent.revoke(cli) }
        settings.removePersistentDomain(forName: name)
    }
}
