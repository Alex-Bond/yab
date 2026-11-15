import AppKit
import Testing
import WebKit
@testable import Fast

/// Recently Closed and Undo are production routes back to extension pages.
/// Session.writes deliberately excludes their URLs, so no session is seeded.
@MainActor
@Suite(.serialized)
struct ExtensionOptionsRestoreTests {
    @MainActor private final class Fixture {
        let space: UUID
        let browser: Browser
        let folder: URL
        let owner: Extensions
        let context: WKWebExtensionContext
        let url: URL

        init(legacy: Bool = false) async throws {
            try #require(Store.testing)
            _ = NSApplication.shared
            let space = UUID()
            let browser = Browser(windowID: UUID())
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("options-reopen-\(UUID())")
            let owner = Extensions.of(space: space)
            var loaded: WKWebExtensionContext?
            var complete = false
            defer {
                if !complete {
                    if let loaded { try? owner.controller.unload(loaded) }
                    browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
                    Spaces.erase(space)
                    Session.erase(space: space)
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("preferences"), withIntermediateDirectories: true)
            // Zotero 5.0.217 declares this nested page with open_in_tab=true.
            // The old options_page spelling exercises the same WebKit route.
            let options = legacy ? #""options_page":"preferences/preferences.html""#
                : #""options_ui":{"page":"preferences/preferences.html","open_in_tab":true}"#
            try "{\"manifest_version\":3,\"name\":\"Options reopen fixture\",\"version\":\"5.0.217\",\(options)}"
                .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try "<!doctype html><html><head><title>Options resource fixture</title><link rel=stylesheet href=preferences.css><script src=preferences.js></script></head><body><p id=ready>Waiting</p></body></html>"
                .write(to: folder.appendingPathComponent("preferences/preferences.html"), atomically: true, encoding: .utf8)
            try "#ready { color: rgb(12, 34, 56); }"
                .write(to: folder.appendingPathComponent("preferences/preferences.css"), atomically: true, encoding: .utf8)
            try "document.addEventListener('DOMContentLoaded',()=>{document.querySelector('#ready').textContent='External script loaded';globalThis.optionsReady={id:chrome.runtime.id,path:location.pathname};});"
                .write(to: folder.appendingPathComponent("preferences/preferences.js"), atomically: true, encoding: .utf8)
            try "<!doctype html><title>Ordinary page</title><p id=ordinary>Ordinary restored page</p>"
                .write(to: folder.appendingPathComponent("ordinary.html"), atomically: true, encoding: .utf8)
            let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
            context.uniqueIdentifier = "options" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            context.baseURL = URL(string: "\(Extensions.scheme)://\(context.uniqueIdentifier)/")!
            try owner.controller.load(context)
            loaded = context
            self.space = space
            self.browser = browser
            self.folder = folder
            self.owner = owner
            self.context = context
            url = try #require(context.optionsPageURL)
            browser.spaceID = space
            owner.follow(browser)
            complete = true
        }

        func close() {
            for tab in browser.tabs { tab.close() }
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            try? owner.controller.unload(context)
            Spaces.erase(space)
            Session.erase(space: space)
            try? FileManager.default.removeItem(at: folder)
        }

        @discardableResult func openOptions() async throws -> Tab {
            let tab = browser.open(url, foreground: false, rowNow: true)
            try await expectResources(tab, label: "fresh options positive control")
            return tab
        }

        func expectResources(_ tab: Tab, label: String) async throws {
            let ready = try await Loaded.until(8) {
                guard let web = tab.builtPage else { return false }
                return (try? await web.run("""
                    document.readyState === 'complete' &&
                    globalThis.optionsReady?.id === '\(context.uniqueIdentifier)' &&
                    optionsReady.path === '/preferences/preferences.html' &&
                    document.querySelector('#ready')?.textContent === 'External script loaded' &&
                    getComputedStyle(document.querySelector('#ready')).color === 'rgb(12, 34, 56)'
                    """)) as? Bool == true
            }
            #expect(ready, "\(label): HTML, external JS/CSS and runtime.id must complete; failure=\(tab.failure ?? "none")")
        }
    }

    @Test(arguments: [false, true])
    func freshOptionsAndSameExtensionNavigation(legacy: Bool) async throws {
        let fixture = try await Fixture(legacy: legacy)
        defer { fixture.close() }
        let tab = try await fixture.openOptions()
        let original = try #require(tab.builtPage)
        tab.go(to: fixture.url.appending(queryItems: [URLQueryItem(name: "same", value: "1")]))
        try await fixture.expectResources(tab, label: "same extension navigation")
        #expect(tab.builtPage === original)
        #expect(fixture.browser.tabs.contains { $0 === tab })
        tab.rest()
        #expect(tab.wake())
        try await fixture.expectResources(tab, label: "existing options rest/wake control")
    }

    @Test func reopenedOptionsLoadsExternalResources() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let original = try await fixture.openOptions()
        fixture.browser.close(original)
        let ghost = try #require(fixture.browser.ghosts.last)
        #expect(ghost.url == fixture.url)
        _ = try #require(ghost.history)
        fixture.browser.reopen()
        let reopened = try #require(fixture.browser.active)
        #expect(reopened !== original)
        try await fixture.expectResources(reopened, label: "Recently Closed options")
    }

    @Test(arguments: [false, true])
    func batchReopenAndUndoLoadOptions(undo: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let options = try await fixture.openOptions()
        _ = fixture.browser.open(URL(string: "about:blank")!, foreground: true)
        let batch = try #require(fixture.browser.putAway([options]))
        if undo {
            let tab = try #require(fixture.browser.bringBack(batch).first)
            #expect(tab.asleep)
            #expect(tab.wake())
            try await fixture.expectResources(tab, label: "Undo closed options")
        } else {
            let ghost = try #require(fixture.browser.ghosts.last)
            fixture.browser.reopen(from: ghost)
            try await fixture.expectResources(try #require(fixture.browser.active), label: "batch reopened options")
        }
    }

    @Test func ordinaryClosedPageStaysOrdinary() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let url = fixture.folder.appendingPathComponent("ordinary.html")
        let original = fixture.browser.open(url, foreground: false, rowNow: true)
        #expect(try await Loaded.until(8) { (try? await original.page.run("document.querySelector('#ordinary')?.textContent")) as? String == "Ordinary restored page" })
        fixture.browser.close(original)
        fixture.browser.reopen()
        let reopened = try #require(fixture.browser.active)
        #expect(try await Loaded.until(8) { (try? await reopened.page.run("document.querySelector('#ordinary')?.textContent")) as? String == "Ordinary restored page" })
        #expect(try await reopened.page.run("typeof globalThis.chrome?.runtime?.id === 'undefined'") as? Bool == true)
        #expect(reopened.pageStore === Spaces.store(for: fixture.space))
    }

    @Test func unknownAndUnloadedOwnersCannotLoadOptions() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        _ = try await fixture.openOptions()
        let unknown = URL(string: "\(Extensions.scheme)://missing-owner/preferences/preferences.html")!
        #expect(Browser.extensionConfiguration(for: unknown, space: fixture.space) == nil)
        try fixture.owner.controller.unload(fixture.context)
        #expect(Browser.extensionConfiguration(for: fixture.url, space: fixture.space) == nil)
        for url in [unknown, fixture.url] {
            let tab = fixture.browser.open(url, foreground: false, rowNow: true)
            #expect(try await Loaded.until(8) { tab.failure != nil })
            #expect((try? await tab.page.run("!!globalThis.optionsReady")) as? Bool != true)
        }
    }
}
