import Foundation
import Testing
@testable import Fast

@MainActor
struct AssistantConnectionRegressionTests {
    @Test func grokConnectOpensTheSignedInProductInsteadOfMarketing() {
        let url = URL(string: AssistantBot.grok.url)!
        #expect(url.host() == "grok.com")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(URLQueryItem(name: "product", value: "grok-bot")) == true)
    }

    @Test func cursorMailConsentDoesNotClaimAnthropicReceivesIt() {
        #expect(MailConsent.company("Cursor") == "Cursor")
        #expect(!MailConsent.terms("Cursor").contains("Anthropic"))
    }
}
