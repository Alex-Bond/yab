import Foundation
import Testing
@testable import Fast

@MainActor
struct AssistantSiteRulesTests {
    @Test func anExplicitSiteExceptionDoesNotUnblockEveryGovernmentSite() {
        var grant = AssistantGrant(id: "test-assistant", name: "dots", client: "dots", made: Date())
        grant.never = ["gov"]
        let irs = URL(string: "https://www.irs.gov/payments")!
        let other = URL(string: "https://www.ssa.gov/")!
        #expect(Assistants.shared.refusal(grant, url: irs) != nil)
        grant.allowedSites = ["irs.gov"]
        #expect(Assistants.shared.refusal(grant, url: irs) == nil)
        #expect(Assistants.shared.refusal(grant, url: other) != nil)
    }
}
