import AppKit
import Testing
@testable import Fast

/// Memory relief that never waits on a page and never stops looking while
/// memory stays short (evals/lowram found both: four minutes of memory out
/// with nothing put down, and an 8 GB Mac at "warning" for an hour with
/// nothing put down either).
struct SleepReliefTests {
    /// A page stuck in a loop can't say whether it holds a draft. Memory
    /// short or a timer leaves it for next time; memory out puts it down,
    /// its process ended, in a couple of seconds rather than never.
    @MainActor @Test func stuckPageDoesNotHoldRelief() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let stuck = browser.open(URL(string: "data:text/html,<p>stuck</p><script>setTimeout(function(){for(;;){}},200)</script>")!,
                                 foreground: true)
        _ = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        defer {
            stuck.builtPage?.killContent()
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for _ in 0..<150 where stuck.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!stuck.loading)
        try await Task.sleep(nanoseconds: 600_000_000)
        let pid = try #require(stuck.builtPage?.contentProcess)

        var said: String?
        browser.sleep(stuck) { said = $0 }
        for _ in 0..<200 where said == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(said == "not answering")
        #expect(!stuck.asleep)

        stuck.draft = true
        said = nil
        browser.sleep(stuck, urgent: true) { said = $0 }
        for _ in 0..<200 where said == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(said == "holding something typed or picked")
        #expect(!stuck.asleep)

        stuck.draft = false
        said = nil
        browser.sleep(stuck, urgent: true) { said = $0 }
        for _ in 0..<200 where said == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(said == "asleep")
        #expect(stuck.asleep)
        // Ended by its pid a second after WebKit was asked.
        for _ in 0..<150 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(kill(pid, 0) != 0)
    }

    /// Memory short with nothing to put down yet: another look is booked,
    /// and none once memory is fine again.
    @MainActor @Test func reliefLooksAgainWhileMemoryIsShort() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        _ = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        defer {
            Pressure.forced = nil
            browser.nextLook?.cancel()
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        Pressure.forced = 2
        browser.relieve()
        #expect(browser.nextLook != nil)
        Pressure.forced = 1
        browser.relieve()
        #expect(browser.nextLook == nil)
    }
}
