import AppKit
import Testing
@testable import Fast

/// Actual private-world replies through Tab.unsaved and Browser.sleep, with
/// a disposable browser and document for every case. No OS pressure is forced.
@Suite(.serialized)
struct SleepFormProbeSafetyTests {
    @MainActor private func evaluate(_ js: String, in web: any PageHandle) async throws -> Any? {
        try await web.run(js, in: .yab, gesture: false)
    }

    @MainActor private func fixture(probe: String, cached: Bool) async throws
        -> (Browser, Tab, any PageHandle, String, () -> Void) {
        let id = UUID(), nonce = UUID().uuidString
        let browser = Browser(windowID: id)
        let html = "<html><body><textarea id='draft'>known draft</textarea></body></html>"
        let encoded = try #require(html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let tab = browser.open(URL(string: "data:text/html,\(encoded)")!, foreground: true)
        _ = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        let cleanup = {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        do {
            for _ in 0..<200 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
            try #require(!tab.loading, "fixture loaded")
            let web = try #require(tab.builtPage)
            let ready = try await evaluate("""
                window.__formProbeNonce = '\(nonce)';
                \(probe)
                window.webkit.messageHandlers.yabForms.postMessage({kind:'draft',on:\(cached)});
                document.getElementById('draft').value === 'known draft'
                """, in: web)
            try #require(ready as? Bool == true, "fixture draft exists")
            for _ in 0..<100 where tab.draft != cached { try await Task.sleep(nanoseconds: 20_000_000) }
            try #require(tab.draft == cached, "actual FormRelay cached report")
            return (browser, tab, web, nonce, cleanup)
        } catch { cleanup(); throw error }
    }

    @MainActor private func sleep(_ browser: Browser, _ tab: Tab, urgent: Bool = false) async -> String {
        await withCheckedContinuation { continuation in
            browser.sleep(tab, urgent: urgent) { continuation.resume(returning: $0) }
        }
    }

    @MainActor private func held(_ tab: Tab, web: any PageHandle, nonce: String) async throws {
        #expect(tab.builtPage === web && !tab.asleep, "same live page")
        // Do not wake a discarded tab while checking the preserved document.
        guard tab.builtPage === web else { return }
        let state = try await evaluate("""
            window.__formProbeNonce === '\(nonce)' &&
            document.getElementById('draft').value === 'known draft'
            """, in: web)
        #expect(state as? Bool == true, "same document nonce and draft")
    }

    @MainActor @Test(arguments: [false, true])
    func cachedDraftSurvivesJavaScriptError(urgent: Bool) async throws {
        let (browser, tab, web, nonce, cleanup) = try await fixture(
            probe: "window.__yabForms = {unsaved(){throw new Error('owned form-probe failure')}};", cached: true)
        defer { cleanup() }
        var actualError = false
        do { _ = try await evaluate("window.__yabForms.unsaved()", in: web) }
        catch { actualError = true }
        try #require(actualError, "actual engine JavaScript exception")
        let reason = await sleep(browser, tab, urgent: urgent)
        print("FORM_PROBE_STATE urgent=\(urgent) reason=\(reason) sameView=\(tab.builtPage === web) asleep=\(tab.asleep)")
        #expect(reason == "holding something typed or picked", "FORM_PROBE_CACHED_ERROR_GUARD")
        try await held(tab, web: web, nonce: nonce)
    }

    @MainActor @Test func freshFalseOverridesCachedDraft() async throws {
        let (browser, tab, _, _, cleanup) = try await fixture(
            probe: "window.__yabForms = {unsaved(){return false}};", cached: true)
        defer { cleanup() }
        #expect(await sleep(browser, tab, urgent: true) == "asleep")
        #expect(tab.asleep && tab.builtPage == nil)
    }

    @MainActor @Test func freshTrueProtectsWithoutCachedDraft() async throws {
        let (browser, tab, web, nonce, cleanup) = try await fixture(
            probe: "window.__yabForms = {unsaved(){return true}};", cached: false)
        defer { cleanup() }
        #expect(await sleep(browser, tab, urgent: true) == "holding something typed or picked")
        try await held(tab, web: web, nonce: nonce)
    }

    @MainActor @Test func errorWithoutCachedDraftKeepsExistingBehavior() async throws {
        let (browser, tab, _, _, cleanup) = try await fixture(
            probe: "window.__yabForms = {unsaved(){throw new Error('owned no-cache failure')}};", cached: false)
        defer { cleanup() }
        #expect(await sleep(browser, tab, urgent: true) == "asleep")
        #expect(tab.asleep && tab.builtPage == nil)
    }

    @MainActor @Test func absentHelperIsAnActualFalseAnswer() async throws {
        let (browser, tab, _, _, cleanup) = try await fixture(
            probe: "window.__yabForms = undefined;", cached: true)
        defer { cleanup() }
        #expect(await sleep(browser, tab, urgent: true) == "asleep")
        #expect(tab.asleep && tab.builtPage == nil)
    }

    @MainActor @Test func untimedErrorKeepsLegacyFalse() async throws {
        let (_, tab, _, _, cleanup) = try await fixture(
            probe: "window.__yabForms = {unsaved(){throw new Error('owned legacy failure')}};", cached: true)
        defer { cleanup() }
        let answer: Bool = await withCheckedContinuation { continuation in
            tab.unsaved { continuation.resume(returning: $0) }
        }
        #expect(answer == false)
    }

    @MainActor @Test func activeAndMediaVetoBeforeProbe() async throws {
        let (browser, tab, web, nonce, cleanup) = try await fixture(
            probe: "window.__yabForms = {unsaved(){return false}};", cached: false)
        defer { cleanup() }
        tab.noisy = true
        #expect(await sleep(browser, tab, urgent: true) == "playing sound")
        try await held(tab, web: web, nonce: nonce)
        tab.noisy = false
        browser.select(tab)
        #expect(await sleep(browser, tab, urgent: true) == "on screen")
        try await held(tab, web: web, nonce: nonce)
    }
}
