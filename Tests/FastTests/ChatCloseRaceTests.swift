import Foundation
import Testing
@testable import Fast

/// Uses only the existing public transition calls and model state, so the
/// same tests can run on the baseline. No window, page or actual sleep.
@MainActor
@Suite(.serialized)
struct ChatCloseRaceTests {
    private func browser() -> Browser { Browser(windowID: UUID()) }

    @Test func closeBeforeTheNextFrameMustCancelAQueuedOpen() async throws {
        let browser = browser()
        defer { browser.tabs.forEach { $0.close() } }
        browser.moveChat(open: true)
        browser.hideChat()
        #expect(!browser.chatMoving, "the close must cancel the pending opening hold")
        try await Task.sleep(for: .milliseconds(60))
        #expect(!browser.chatOpen, "the older opening callback must not undo the close")
    }

    @Test func reopenBeforeTheNextFrameMustCancelAQueuedClose() async throws {
        let browser = browser()
        defer { browser.tabs.forEach { $0.close() } }
        browser.chatOpen = true
        browser.moveChat(open: false)
        browser.moveChat(open: true)
        #expect(!browser.chatMoving, "reopening must cancel the pending closing hold")
        try await Task.sleep(for: .milliseconds(60))
        #expect(browser.chatOpen, "the older closing callback must not undo the reopen")
    }
}
