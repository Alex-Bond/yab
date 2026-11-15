import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct DeafTests {
    private func fixture(_ check: (Browser, Tab) async throws -> Void) async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let tab = browser.open(URL(string: "about:blank#busy-preview")!, foreground: true)
        let previous = Store.settings.object(forKey: "stuck.deafAsk")
        Store.settings.removeObject(forKey: "stuck.deafAsk")
        defer {
            if let previous { Store.settings.set(previous, forKey: "stuck.deafAsk") }
            else { Store.settings.removeObject(forKey: "stuck.deafAsk") }
            browser.dropAsks(tab)
            browser.close(tab)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let view = tab.page
        for _ in 0..<300 where view.contentProcess == nil || tab.loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try #require(view.contentProcess)
        try await check(browser, tab)
    }

    @Test func aBusyPreviewCanRecoverWithoutACardDespiteRepeatedInput() async throws {
        try await fixture { browser, tab in
            let view = tab.page
            browser.page(view, responsive: false)
            // Six seconds after WebKit's signal is about nine after input.
            // A second click must not turn ordinary busy work into a hang.
            tab.deaf = Date(timeIntervalSinceNow: -6)
            browser.reachedDeaf(tab)
            browser.reachedDeaf(tab)
            #expect(tab.deaf != nil)
            #expect(!tab.deafAsked && tab.asks.isEmpty)
            browser.page(view, responsive: true)
            #expect(tab.deaf == nil && !tab.deafAsked && tab.asks.isEmpty)
        }
    }

    @Test func aSustainedHangStillAsksAndRecoveryDismissesIt() async throws {
        try await fixture { browser, tab in
            let view = tab.page
            browser.page(view, responsive: false)
            tab.deaf = Date(timeIntervalSinceNow: -13)
            browser.reachedDeaf(tab)
            #expect(tab.deafAsked && tab.asks.first?.kind == .stuck)
            browser.page(view, responsive: true)
            #expect(tab.deaf == nil && !tab.deafAsked && tab.asks.isEmpty)
        }
    }

    @Test func recoveryBeforeTheDeadlineCancelsTheScheduledCard() async throws {
        try await fixture { browser, tab in
            Store.settings.set(0.08, forKey: "stuck.deafAsk")
            let view = tab.page
            browser.page(view, responsive: false)
            browser.page(view, responsive: true)
            try await Task.sleep(for: .milliseconds(160))
            #expect(tab.deaf == nil && !tab.deafAsked && tab.asks.isEmpty)
        }
    }
}
