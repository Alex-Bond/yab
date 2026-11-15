import Foundation
import Testing
import WebKit
@testable import Fast

/// Uses the pre-existing install and injection APIs so the same cases run
/// against main and demonstrate the original cross-profile execution.
@MainActor @Suite(.serialized)
struct AddonProfileRegressionTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("addon-profiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func tab(_ store: WKWebsiteDataStore) -> Tab {
        let tab = Tab(bench: true, configuration: Web.configuration(store: store))
        tab.restore(url: URL(string: "https://example.com/")!, title: "Example")
        return tab
    }
    private func hasBoost(_ boosts: Boosts, tab: Tab) -> Bool {
        let controller = WKUserContentController()
        boosts.attach(to: controller, tab: tab)
        return !controller.userScripts.isEmpty
    }
    private func hasScript(_ scripts: Userscripts, tab: Tab) -> Bool {
        let controller = WKUserContentController()
        scripts.attach(to: controller, tab: tab, host: "example.com")
        return !controller.userScripts.isEmpty
    }
    @Test func newlyKeptBoostOnlyRunsInSharedSignIns() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try BoostPackage.read(id: "profile-calm", files: BoostTests.files(), sites: ["example.com"])
        _ = try BoostLibrary(root: root).keep(package, author: "You", session: "")
        let boosts = Boosts(root: root, safeMode: false)
        let shared = tab(Store.websites), own = tab(Spaces.store(for: UUID()))
        #expect(hasBoost(boosts, tab: shared))
        #expect(!hasBoost(boosts, tab: own))
    }
    @Test func newlyKeptUserscriptDoesNotRunInAnotherProfile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = Userscripts(root: root)
        let script = try Userscript.read(UserscriptTests.script(["@name Profile script", "@namespace profiles", "@match https://example.com/*"], body: "document.body.dataset.profile = 'yes';"))
        try scripts.store(script, source: nil, enabled: true)
        let shared = tab(Store.websites), own = tab(Spaces.store(for: UUID()))
        #expect(hasScript(scripts, tab: shared))
        #expect(!hasScript(scripts, tab: own))
    }
    @Test func keepInOwnProfileDoesNotInstallInSharedProfile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("profile.user.js")
        try UserscriptTests.script(["@name Own profile script", "@namespace profiles", "@match https://example.com/*"], body: "document.body.dataset.profile = 'own';")
            .write(to: file, atomically: true, encoding: .utf8)
        let scripts = Userscripts(root: root.appendingPathComponent("kept"))
        let own = tab(Spaces.store(for: UUID())), shared = tab(Store.websites)
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        browser.lay([own]); browser.activeID = own.id
        scripts.offer(file, in: own, browser: browser)
        for _ in 0..<200 where scripts.offers[own.id]?.ready != true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(scripts.offers[own.id]?.ready == true)
        await scripts.keep(own)
        #expect(scripts.records.count == 1)
        #expect(hasScript(scripts, tab: own))
        #expect(!hasScript(scripts, tab: shared))
    }
}
