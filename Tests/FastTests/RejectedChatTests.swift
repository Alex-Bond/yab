import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct RejectedChatTests {
    @Test func aRefusedGeminiTurnKeepsThePersonsWordsAndTheReason() {
        let settings = Store.settings
        let keys = [AIUse.key, "agents.explicit-connections.v1", "agents.revoked-connections.v1",
                    "agents.connection-generation.gemini"]
        let saved = keys.map { settings.object(forKey: $0) }
        let agents = Agents.shared
        let previousBrowser = agents.browser
        let previousReady = Agents.assumedInTests
        let browser = Browser(windowID: UUID())
        defer {
            agents.browser = previousBrowser
            Agents.assumedInTests = previousReady
            for (key, value) in zip(keys, saved) { settings.set(value, forKey: key) }
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.letGo()
        }
        settings.set(AIUse.Level.on.rawValue, forKey: AIUse.key)
        ProviderConsent.shared.revoke("gemini")
        // Another connected provider can enable the shared composer. That
        // must not grant the selected Gemini plan permission to launch.
        Agents.assumedInTests = true
        agents.browser = browser
        browser.chatNext = ModelChoice(cli: "gemini", model: "gemini-fixture", effort: "medium")
        let words = "Keep this message when Gemini cannot start"
        agents.withSessionFixture([]) {
            guard let turn = ChatComposer.begin(words, with: [], in: browser) else {
                Issue.record("The manual chat did not return its failed turn")
                return
            }
            defer { Chats.shared.remove(turn.id) }
            #expect(turn.state == .failed && turn.result == ProviderConsent.refusal)
            #expect(agents.session(turn.id) == nil, "Saving a failed chat must not admit the refused provider task")
            #expect(turn.process == nil && turn.server == nil && turn.input == nil)
            #expect(!ProviderConsent.shared.allows("gemini"))
            let kept = Chats.shared.chat(turn.id)
            #expect(kept?.state == "failed" && kept?.answer == ProviderConsent.refusal)
            #expect(kept?.items.filter { $0.kind == .asked }.map(\.text) == [words])
            #expect(kept?.turns.count == 1)
            #expect(kept?.model == "gemini-fixture" && kept?.effort == "medium")
            #expect(browser.chatID == turn.id)
        }
    }
}
