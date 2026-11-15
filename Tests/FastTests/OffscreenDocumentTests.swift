import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct OffscreenDocumentTests {
    /// Keep only a weak page and process scalars across the action under test.
    /// A census or a local WKWebView would itself prevent the release.
    @MainActor private final class Observation {
        weak var page: WKWebView?
        let pid: Int32?
        let born: UInt64?

        init(_ page: WKWebView) {
            self.page = page
            let key = "_webProcessIdentifier"
            pid = page.responds(to: NSSelectorFromString(key))
                ? (page.value(forKey: key) as? NSNumber)?.int32Value : nil
            born = pid.flatMap(WKWebView.started)
        }
    }

    @MainActor private final class Fixture {
        let owner: Extensions
        let browser: Browser
        let source: URL
        let id: String

        init(owner: Extensions, browser: Browser, source: URL, id: String) {
            self.owner = owner
            self.browser = browser
            self.source = source
            self.id = id
        }

        func close() {
            Self.clean(owner: owner, browser: browser, source: source, id: id)
        }

        static func clean(owner: Extensions, browser: Browser, source: URL, id: String?, staged: URL? = nil) {
            if let id { owner.remove(id) }
            owner.shutDown()
            // Parent builds deliberately fail before their missing cleanup:
            // release only this fixture's leftover after the assertions.
            if let id, ExtensionShims.offscreen[id]?.configuration.webExtensionController === owner.controller {
                ExtensionShims.offscreen[id] = nil
            }
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            if let windowID = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
            }
            // This owner has a fresh UUID, never a real or shared sign-in.
            if owner.signIn != nil { try? FileManager.default.removeItem(at: Extensions.list(of: owner.signIn)) }
            if let staged { try? FileManager.default.removeItem(at: staged) }
            try? FileManager.default.removeItem(at: source)
        }

        func create(_ path: String = "offscreen.html") async throws -> Observation {
            let context = try #require(owner.contexts[id])
            let reply = try await ExtensionShims.answer(["api": "offscreen.createDocument", "args": [["url": path]]], from: context, owner: owner) as? [String: Any]
            #expect(reply?["error"] == nil, "\(String(describing: reply))")
            return try #require(observation())
        }

        func observation() -> Observation? {
            autoreleasepool { ExtensionShims.offscreen[id].map(Observation.init) }
        }
    }

    /// Install through the production list and load path, so unload sees this
    /// context. Each owner has its own sign-in and each test owns its files.
    private func installed(capture: Bool = false, sameID: String? = nil) async throws -> Fixture {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("yab-offscreen-owned-\(UUID())")
        let owner = Extensions(signIn: UUID())
        let browser = Browser(windowID: UUID())
        owner.browser = browser
        var staged: URL?
        var id: String?
        var complete = false
        defer { if !complete { Fixture.clean(owner: owner, browser: browser, source: source, id: id, staged: staged) } }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let permissions = capture ? #"["offscreen","tabCapture"]"# : #"["offscreen"]"#
        try #"{"manifest_version":3,"name":"Owned offscreen test","version":"1.0","permissions":\#(permissions)}"#
            .write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "window.readyForMessages=true".write(to: source.appendingPathComponent("offscreen.js"), atomically: true, encoding: .utf8)
        try "<html><body><script src=offscreen.js></script></body></html>".write(to: source.appendingPathComponent("offscreen.html"), atomically: true, encoding: .utf8)
        // The parser has finished before document.open, so this new document
        // stays loading until somebody closes it; no remote or timed server.
        try "document.addEventListener('DOMContentLoaded',()=>{document.open();document.write('<title>Still opening</title>');});"
            .write(to: source.appendingPathComponent("pending.js"), atomically: true, encoding: .utf8)
        try "<html><body><script src=pending.js></script></body></html>".write(to: source.appendingPathComponent("pending.html"), atomically: true, encoding: .utf8)
        let prepared = try await owner.prepare(folder: source)
        staged = prepared.staged
        id = sameID ?? prepared.id
        let candidate = Extensions.Candidate(id: sameID ?? prepared.id, fromStore: prepared.fromStore,
                                            staged: prepared.staged, source: prepared.source,
                                            name: prepared.name, version: prepared.version, about: prepared.about,
                                            icon: prepared.icon, wants: prepared.wants, extras: prepared.extras,
                                            shortcuts: prepared.shortcuts)
        try #require(await owner.add(candidate))
        _ = try #require(owner.contexts[candidate.id])
        complete = true
        return Fixture(owner: owner, browser: browser, source: source, id: candidate.id)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func acceptsRuntimeURLWithoutAppendingTheOriginAsAPath() {
        let base = URL(string: "chrome-extension://test-extension/")!
        let expected = base.appendingPathComponent("offscreen.html")
        #expect(ExtensionShims.offscreenURL("offscreen.html", base: base) == expected)
        #expect(ExtensionShims.offscreenURL(expected.absoluteString, base: base) == expected)
        #expect(ExtensionShims.offscreenURL("/offscreen.html", base: base) == expected)
        #expect(ExtensionShims.offscreenURL("https://example.test/offscreen.html", base: base) == nil)
        #expect(ExtensionShims.offscreenURL("chrome-extension://another/offscreen.html", base: base) == nil)
        #expect(ExtensionShims.offscreenURL("//another/offscreen.html", base: base) == nil)
    }

    @Test func loadsNordPassStyleAbsoluteURLBeforeAnswering() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-offscreen-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Offscreen test","version":"1.0","permissions":["offscreen"]}"#.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "window.readyForMessages=true".write(to: folder.appendingPathComponent("offscreen.js"), atomically: true, encoding: .utf8)
        try "<html><body><script src=offscreen.js></script></body></html>".write(to: folder.appendingPathComponent("offscreen.html"), atomically: true, encoding: .utf8)
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        context.baseURL = URL(string: "chrome-extension://offscreen-test/")!
        let config = WKWebExtensionController.Configuration.nonPersistent()
        config.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: config)
        try controller.load(context)
        let owner = Extensions.shared, previous = Extensions.shared.browser
        let browser = Browser(windowID: UUID())
        owner.browser = browser
        defer {
            owner.browser = previous
            ExtensionShims.offscreen[context.uniqueIdentifier] = nil
            try? controller.unload(context)
        }
        let url = context.baseURL.appendingPathComponent("offscreen.html")
        let result = try await ExtensionShims.answer(["api": "offscreen.createDocument", "args": [["url": url.absoluteString]]], from: context, owner: owner) as? [String: Any]
        #expect(result?["error"] == nil)
        let page = try #require(ExtensionShims.offscreen[context.uniqueIdentifier])
        #expect(page.url == url)
        #expect(try await page.evaluateJavaScript("window.readyForMessages === true") as? Bool == true)
        // The window the shim asks of, again: other suites running beside
        // this one set Extensions' browser while the page loaded ("No
        // browser window" on m4). Read at once on the call.
        owner.browser = browser
        let contexts = try await ExtensionShims.answer(["api": "runtime.getContexts", "args": [["contextTypes": ["OFFSCREEN_DOCUMENT"], "documentUrls": [url.absoluteString]]]], from: context, owner: owner) as? [String: Any]
        #expect((contexts?["value"] as? [[String: Any]])?.count == 1, "\(String(describing: contexts))")
    }

    @Test func disablingReleasesItsSeatedPageAndLeavesAnotherExtensionAlone() async throws {
        let fixture = try await installed(capture: true)
        let other = try await installed()
        defer { fixture.close(); other.close() }
        let old = try await fixture.create()
        let kept = try await other.create()
        #expect(old.page?.window != nil)
        #expect(old.page?.configuration.webExtensionController === fixture.owner.controller)
        fixture.owner.setEnabled(fixture.id, false)
        #expect(fixture.owner.contexts[fixture.id] == nil)
        #expect(ExtensionShims.offscreen[fixture.id] == nil)
        #expect(await wait { old.page == nil }, "Offscreen page retained after disable; pid=\(String(describing: old.pid)), born=\(String(describing: old.born))")
        #expect(kept.page != nil)
        #expect(other.observation()?.page === kept.page)
        fixture.owner.setEnabled(fixture.id, true)
        #expect(await wait { fixture.owner.contexts[fixture.id] != nil })
        let recreated = try await fixture.create()
        #expect(recreated.page != nil)
    }

    @Test func reloadingReleasesTheOldPageAndCanCreateAnother() async throws {
        let fixture = try await installed(capture: true)
        defer { fixture.close() }
        let old = try await fixture.create()
        weak var oldContext = fixture.owner.contexts[fixture.id]
        fixture.owner.reload(fixture.id)
        #expect(await wait { fixture.owner.contexts[fixture.id] != nil && fixture.owner.contexts[fixture.id] !== oldContext })
        #expect(ExtensionShims.offscreen[fixture.id] == nil)
        #expect(await wait { old.page == nil })
        let recreated = try await fixture.create()
        #expect(recreated.page != nil)
        fixture.owner.remove(fixture.id)
        #expect(ExtensionShims.offscreen[fixture.id] == nil)
        #expect(await wait { recreated.page == nil })
    }

    @Test func unloadingOneControllerPreservesTheSameIDInAnother() async throws {
        let first = try await installed()
        let second = try await installed(capture: true, sameID: first.id)
        defer { first.close(); second.close() }
        // admit reuses the package saved by the first sign-in. Both owners
        // have a real loaded context; only the second creates this page.
        #expect(first.owner.contexts[first.id] != nil)
        #expect(second.owner.contexts[second.id] != nil)
        let kept = try await second.create()
        #expect(kept.page?.configuration.webExtensionController === second.owner.controller)
        first.owner.setEnabled(first.id, false)
        #expect(first.owner.contexts[first.id] == nil)
        #expect(second.owner.contexts[second.id] != nil)
        #expect(second.observation()?.page === kept.page)
        second.owner.setEnabled(second.id, false)
        #expect(ExtensionShims.offscreen[second.id] == nil)
        #expect(await wait { kept.page == nil })
    }

    @Test func unloadStopsAnInFlightCreateWithoutRetainingItsPage() async throws {
        let fixture = try await installed(capture: true)
        defer { fixture.close() }
        var finished = false
        var reply: [String: Any]?
        let opening = Task { @MainActor in
            let context = try #require(fixture.owner.contexts[fixture.id])
            reply = try await ExtensionShims.answer(["api": "offscreen.createDocument", "args": [["url": "pending.html"]]], from: context, owner: fixture.owner) as? [String: Any]
            finished = true
        }
        #expect(await wait { fixture.observation() != nil })
        let old = try #require(fixture.observation())
        // Also establish that this fixture is still in the create wait.
        #expect(!finished)
        fixture.owner.setEnabled(fixture.id, false)
        let stopped = await wait { finished }
        #expect(stopped, "A removed offscreen page still holds its create call")
        #expect(reply?["error"] != nil)
        if !stopped { opening.cancel() }
        _ = try await opening.value
        #expect(ExtensionShims.offscreen[fixture.id] == nil)
        #expect(await wait { old.page == nil })
    }
}
