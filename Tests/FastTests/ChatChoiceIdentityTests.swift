import AppKit
import Testing
import WebKit
@testable import Fast

/// The real handoff/choice lifecycle on bench tabs. Labels that happen to
/// say Send/Keep draft are ordinary choices here; no mail is composed or
/// sent, no provider/session is launched and no approval is bypassed.
@MainActor
@Suite(.serialized)
struct ChatChoiceIdentityTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private let answers = ["Send", "Keep draft"]

    private func makeTab() -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return Tab(bench: true, configuration: configuration)
    }

    private func close(_ tab: Tab) {
        Agents.shared.handBack(tab)
        if !tab.gone { tab.close() }
    }

    private func ask(_ tab: Tab, reason: String = "What next?") throws -> String {
        Agents.shared.handoff(tab, reason: reason, choices: answers)
        return try #require(tab.handoffNotice?.id)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func aSecondIdenticalQuestionInTheSameTabCanBeAnswered() async throws {
        let tab = makeTab(), choosing = ChatChoosing()
        defer { close(tab) }
        let first = try ask(tab)
        choosing.pick(tab, 0)
        try await settle()
        #expect(tab.chosen == "Send")
        #expect(tab.handoff == nil && tab.choices.isEmpty)

        let second = try ask(tab)
        #expect(second != first)
        choosing.take(tab) // A new card's onAppear, without a choices onChange.
        #expect(choosing.picked == nil && choosing.lit == nil)
        choosing.pick(tab, 1)
        try await settle()
        #expect(tab.chosen == "Keep draft")
        #expect(tab.handoff == nil)
    }

    @Test func oneQuestionAcceptsOnlyOneClick() async throws {
        let tab = makeTab(), choosing = ChatChoosing()
        defer { close(tab) }
        _ = try ask(tab)
        choosing.pick(tab, 0)
        choosing.pick(tab, 1)
        #expect(choosing.picked == 0)
        try await settle()
        #expect(tab.chosen == "Send")
        #expect(tab.handoff == nil)
    }

    @Test func delayedClickCannotAnswerAReplacementWithTheSameLabels() async throws {
        let tab = makeTab(), choosing = ChatChoosing()
        defer { close(tab) }
        let first = try ask(tab, reason: "First decision?")
        choosing.pick(tab, 0)
        let replacement = try ask(tab, reason: "Different decision?")
        #expect(replacement != first)
        try await settle()
        #expect(tab.chosen == nil)
        #expect(tab.handoffNotice?.id == replacement)
        #expect(tab.choices == answers)
        // A click also detects the new identity before any view update.
        choosing.pick(tab, 1)
        try await settle()
        #expect(tab.chosen == "Keep draft")
    }

    @Test func withdrawnAndReissuedIdenticalQuestionCannotReceiveTheOldClick() async throws {
        let tab = makeTab(), choosing = ChatChoosing()
        defer { close(tab) }
        let first = try ask(tab)
        choosing.pick(tab, 0)
        Agents.shared.handBack(tab)
        let replacement = try ask(tab)
        #expect(replacement != first)
        try await settle()
        #expect(tab.chosen == nil)
        #expect(tab.handoffNotice?.id == replacement)
    }

    @Test func newQuestionResetsEscAndKeyboardSelectionEvenWithIdenticalChoices() async throws {
        let tab = makeTab(), choosing = ChatChoosing()
        defer { close(tab) }
        _ = try ask(tab)
        choosing.take(tab)
        choosing.move(tab, by: 1)
        #expect(choosing.lit == 0)
        #expect(choosing.putAway(tab))
        Agents.shared.handBack(tab)
        _ = try ask(tab)
        choosing.take(tab)
        #expect(choosing.away == nil && choosing.lit == nil && choosing.picked == nil)
        choosing.move(tab, by: -1)
        #expect(choosing.pickLit(tab))
        try await settle()
        #expect(tab.chosen == "Keep draft")
    }

    @Test func lookingAtAnotherQuestionDoesNotRedirectOrLoseAValidClick() async throws {
        let first = makeTab(), second = makeTab(), choosing = ChatChoosing()
        defer { close(first); close(second) }
        _ = try ask(first)
        let other = try ask(second)
        choosing.pick(first, 0)
        choosing.take(second)
        try await settle()
        #expect(first.chosen == "Send")
        #expect(second.chosen == nil && second.handoffNotice?.id == other)
        choosing.pick(second, 1)
        try await settle()
        #expect(second.chosen == "Keep draft")
    }

    @Test func aClosedTabCannotReceiveItsPendingClick() async throws {
        let tab = makeTab(), choosing = ChatChoosing()
        defer { close(tab) }
        _ = try ask(tab)
        choosing.pick(tab, 0)
        tab.close()
        try await settle()
        #expect(tab.gone && tab.chosen == nil)
    }
}
