import Foundation
import Testing
@testable import Fast

@MainActor
struct AssistantConnectionTests {
    @Test func grokConnectStartsAtTheProductEntry() {
        let url = URL(string: AssistantBot.grok.url)!
        #expect(url.host() == "grok.com")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(URLQueryItem(name: "product", value: "grok-bot")) == true)
    }

    @Test func recognizesBotChatsWithoutInvitingOrdinaryGrokChats() {
        for address in ["https://grok.com/bot", "https://grok.com/bot/a-bot", "https://grok.com/?product=grok-bot", "https://x.ai/bot"] {
            #expect(AssistantBot.at(URL(string: address)!) == .grok, "\(address)")
        }
        for address in ["https://grok.com/", "https://grok.com/c/a-chat", "https://grok.com/?product=other", "https://grok.com/botany", "https://grok.com.evil.example/bot/a-bot", "http://grok.com/bot/a-bot"] {
            #expect(AssistantBot.at(URL(string: address)!) == nil, "\(address)")
        }
    }

    @Test func automaticHandoffChecksTheClientEvenWhenTheNonceMatches() {
        let link = AssistantHost.Link(link: "link", client: "Cursor", kind: "device", nonce: "same-nonce", clientID: "cursor")
        #expect(!link.matches(client: "grok-bot", nonce: "same-nonce"))
        #expect(link.matches(client: "cursor", nonce: "same-nonce"))
        #expect(!link.matches(client: "cursor", nonce: "stale-nonce"))
    }

    @Test func aClientDisplayNameCannotStandInForItsIdentity() {
        let renamed = AssistantHost.Link(link: "link", client: "Cursor", kind: "device", nonce: "same-nonce", clientID: "grok-bot")
        #expect(renamed.matches(client: "grok-bot", nonce: "same-nonce"))
        let missing = AssistantHost.Link(link: "link", client: "grok-bot", kind: "device", nonce: "same-nonce")
        #expect(!missing.matches(client: "grok-bot", nonce: "same-nonce"))
        #expect(missing.matches(client: nil, nonce: nil))
    }

    @Test func mailConsentNamesTheConnectedProviderAndKeepsExternalNames() {
        #expect(MailConsent.company("Cursor") == "Cursor")
        #expect(MailConsent.company("Gemini") == "Google")
        #expect(MailConsent.company("Claude") == "Anthropic")
        #expect(MailConsent.company("ChatGPT") == "OpenAI")
        #expect(MailConsent.company("Grok Bot") == "Grok Bot")
        #expect(MailConsent.company("My external assistant") == "My external assistant")
        #expect(!MailConsent.terms("Cursor").contains("Anthropic"))
    }
    @Test func manualInputInvalidatesAnAlreadyQueuedAutomaticReply() {
        let connect = AssistantConnect()
        let attempt = connect.begin(.grok)
        connect.editCode("k7q")
        #expect(connect.bot == nil)
        #expect(connect.stopped == .grok)
        #expect(connect.code == "K7Q")
        #expect(!connect.receive("ABCD-EFGH", nonce: "old", bot: .grok, attempt: attempt))
        #expect(connect.found == nil)
        #expect(connect.code == "K7Q")
    }

    @Test func cancelAndRestartOnlyAcceptsTheCurrentAttempt() {
        let connect = AssistantConnect()
        let old = connect.begin(.dots)
        connect.cancel()
        #expect(!connect.receive("ABCD-EFGH", nonce: "old", bot: .dots, attempt: old))
        let current = connect.begin(.dots)
        #expect(!connect.receive("ABCD-EFGH", nonce: "old", bot: .dots, attempt: old))
        #expect(connect.receive("K7QM-2XPA", nonce: "new", bot: .dots, attempt: current))
        #expect(connect.found?.code == "K7QM-2XPA")
        #expect(connect.found?.nonce == "new")
    }

    @Test func connectorHandoffClearsAnAutomaticResultAndManualDraft() {
        let connect = AssistantConnect()
        let old = connect.begin(.muse)
        connect.editCode("K")
        connect.clear()
        #expect(connect.code.isEmpty)
        #expect(connect.stopped == nil)
        #expect(!connect.receive("K7QM-2XPA", nonce: "old", bot: .muse, attempt: old))
    }

    @Test func pastedWholeCodeChecksImmediatelyButTheLastTypedLetterWaits() {
        #expect(CodeGroupsField.isCompletePaste(previous: "", proposed: "k7qm-2xpa"))
        #expect(CodeGroupsField.isCompletePaste(previous: "K7", proposed: "K7QM2XPA"))
        #expect(!CodeGroupsField.isCompletePaste(previous: "K7QM2XP", proposed: "K7QM2XPA"))
        #expect(!CodeGroupsField.isCompletePaste(previous: "", proposed: "K"))
        #expect(CodeGroupsField.clean(" k7qm-2xpa ") == "K7QM2XPA")
    }

    @Test func manualHandoffKeepsDynamicConnectorNamesButRecognizesStableBots() {
        let dynamic = AssistantHost.Link(link: "link", client: "Claude.ai", kind: "oauth", nonce: nil, clientID: "generated-opaque-client-id")
        #expect(dynamic.presentationClient == "Claude.ai")
        let grok = AssistantHost.Link(link: "link", client: "Cursor", kind: "device", nonce: nil, clientID: "grok-bot")
        #expect(grok.presentationClient == "grok-bot")
    }

    @Test func keepAskingStartsFreshAfterAnAccidentalKeystroke() {
        let connect = AssistantConnect()
        let old = connect.begin(.grok)
        connect.editCode("K")
        let current = connect.begin(.grok)
        #expect(connect.code.isEmpty)
        #expect(connect.stopped == nil)
        #expect(!connect.receive("ABCD-EFGH", nonce: "old", bot: .grok, attempt: old))
        #expect(connect.receive("K7QM-2XPA", nonce: "current", bot: .grok, attempt: current))
    }

}
