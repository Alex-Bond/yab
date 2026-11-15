import AppKit
import Testing
@testable import Fast

/// The existing files eval must address the selected engine's real document.
@MainActor @Suite(.serialized)
struct FilesBenchTests {
    private func ask(_ bench: Bench, _ browser: Browser, _ request: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { reply in
            bench.filesCommand(request, browser: browser) { reply.resume(returning: $0) }
        }
    }

    @Test func scriptsUseTheOwnedMainWorldAndPreserveJavaScriptErrors() async throws {
        let id = UUID(), browser = Browser(windowID: id), bench = Bench()
        let html = "<title>Files fixture</title><input type=file>"
        let url = URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!
        let tab = browser.open(url, foreground: true)
        defer {
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let loaded = try await Loaded.until(20) {
            guard !tab.loading, let page = tab.builtPage, page.contentProcess != nil else { return false }
            return try await page.run("document.readyState === 'complete' && document.title === 'Files fixture' && !!document.querySelector('input[type=file]')") as? Bool == true
        }
        let page = try #require(tab.builtPage)
        let observed = try await page.run("JSON.stringify({title:document.title,url:location.href,ready:document.readyState,file:!!document.querySelector('input[type=file]')})")
        try #require(loaded, Comment(rawValue: "the real selected-engine upload document must be ready: \(String(describing: observed))"))
        let value = await ask(bench, browser, ["id": tab.id.uuidString, "js": "window.__filesMain=41; document.title"])
        #expect(value["error"] == nil && value["value"] as? String == "Files fixture", Comment(rawValue: "actual endpoint reply: \(value)"))
        #expect(try await page.run("window.__filesMain") as? Int == 41)
        #expect(try await page.run("typeof window.__filesMain", in: .yab) as? String == "undefined")
        let failed = await ask(bench, browser, ["id": tab.id.uuidString, "js": "throw new Error('owned files fixture')"])
        #expect((failed["error"] as? String)?.isEmpty == false)
        #expect(failed["value"] == nil)
        #expect(tab.builtPage === page && page.engine == tab.engineKind)
    }

    @Test func anUnknownTabCannotEvaluateOrMaterializeAPage() async {
        let id = UUID(), browser = Browser(windowID: id), bench = Bench()
        defer {
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let before = browser.tabs.map(\.id)
        let result = await ask(bench, browser, ["id": UUID().uuidString, "js": "1"])
        #expect(result["error"] as? String == "no such tab")
        #expect(browser.tabs.map(\.id) == before)
    }
}
