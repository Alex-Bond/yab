import Foundation
import Testing
@testable import Fast

/// Feedback #280: a Mac whose ChatGPT or Codex app signed in a Codex has
/// an agent Yab can run, though nothing was connected in Yab. Its Ask and
/// Task rows show, but words lead to the search, where Return goes; once a
/// plan is connected here, a question leads to Ask and a verb to the task.
struct FieldLeadWithoutPlanTests {
    @MainActor private func world(connected: Bool) -> (Browser, UUID) {
        Agents.assumedInTests = true
        Agents.connectedInTests = connected
        let id = UUID()
        let browser = Browser(windowID: id)
        return (browser, id)
    }

    @MainActor private func forget(_ id: UUID) {
        Agents.assumedInTests = nil
        Agents.connectedInTests = nil
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    @MainActor @Test func signedInElsewhereWordsLeadToTheSearch() {
        let (browser, id) = world(connected: false)
        defer { forget(id) }
        #expect(browser.wordsLead("how do I cook rice") == .search)
        #expect(browser.wordsLead("find cheap flights to tokyo") == .search)
        #expect(browser.wordsLead("is it going to rain?") == .search)
        browser.newTab()
        browser.typed = "how do I cook rice"
        let kinds = browser.offers.map(\.kind)
        #expect(kinds.first == .search)
        #expect(browser.query.lead == 0)
        // The rows are still there, one and two ↓ away.
        #expect(Array(kinds.prefix(3)) == [.search, .ask, .task])
        browser.dismiss()
    }

    @MainActor @Test func connectedHereAQuestionStillLeadsToAsk() {
        let (browser, id) = world(connected: true)
        defer { forget(id) }
        #expect(browser.wordsLead("how do I cook rice") == .ask)
        #expect(browser.wordsLead("find cheap flights to tokyo") == .task)
        #expect(browser.wordsLead("rice cooker") == .search)
        browser.newTab()
        browser.typed = "how do I cook rice"
        #expect(browser.offers.first?.kind == .ask)
        browser.dismiss()
    }

    @MainActor @Test func noAgentAtAllNoRows() {
        let (browser, id) = world(connected: false)
        defer { forget(id) }
        Agents.assumedInTests = false
        browser.newTab()
        browser.typed = "how do I cook rice"
        #expect(browser.offers.first?.kind == .search)
        #expect(!browser.offers.contains { $0.kind == .ask || $0.kind == .task })
        browser.dismiss()
    }
}
