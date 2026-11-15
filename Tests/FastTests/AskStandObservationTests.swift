import AppKit
import Observation
import Testing
@testable import Fast

/// The corner must keep following real questions after removing its
/// per-render Combine subscription graph. No send/approval is executed.
@MainActor
@Suite(.serialized)
struct AskStandObservationTests {
    private final class Changed: @unchecked Sendable { var value = false }

    private func world(_ check: (Browser, Tab, Tab) throws -> Void) rethrows {
        let permission = AgentNotices.shared.testPermission
        AgentNotices.shared.testPermission = .denied
        let browser = Browser(windowID: UUID())
        let front = Tab(bench: true, factory: .webKitOnly)
        let parked = Tab(bench: true, factory: .webKitOnly)
        browser.lay([front])
        browser.activeID = front.id
        browser.parked[UUID()] = Parked(tabs: [parked], active: parked.id)
        defer {
            for tab in [front, parked] { tab.permit = nil; tab.sending = nil; tab.handoff = nil }
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
            AgentNotices.shared.testPermission = permission
        }
        try check(browser, front, parked)
    }

    private func observes(_ browser: Browser, _ mutate: () -> Void) -> Bool {
        let changed = Changed()
        _ = withObservationTracking {
            Agents.shared.corneredAll(in: browser)
        } onChange: { changed.value = true }
        mutate()
        return changed.value
    }

    @Test(arguments: [false, true], ["permit", "handoff", "choices", "sending"])
    func questionsAreObservedInVisibleAndParkedRows(behind: Bool, field: String) {
        world { browser, front, parked in
            let tab = behind ? parked : front
            let permit = AgentPermit(kind: .sendMessage(to: "Test"), session: "observation-test", detail: "Test")
            #expect(observes(browser) {
                switch field {
                case "permit": tab.permit = permit
                case "handoff": tab.handoff = "Needs your answer"
                case "choices": tab.choices = ["One", "Two"]
                default: tab.sending = AgentSending(permit)
                }
            })
        }
    }

    @Test func newParkedRowsAreObservedButUnrelatedNamesAreNot() {
        world { browser, front, _ in
            #expect(!observes(browser) { front.name = "A tab was renamed" })
            #expect(observes(browser) { browser.parked[UUID()] = Parked(tabs: [], active: nil) })
        }
    }
}
