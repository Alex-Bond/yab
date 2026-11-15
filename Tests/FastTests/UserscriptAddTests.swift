import Foundation
import Testing
@testable import Fast

/// Add Userscript… in the Boosts list and a `.user.js` dropped on it: the
/// chosen file reaches the same Keep card a `.user.js` opened in a tab
/// gets, its header read (docs/userscripts.md, "Install").
@MainActor @Suite(.serialized)
struct UserscriptAddTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yab-userscript-add-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func window(_ address: String) -> (Browser, Tab) {
        let browser = Browser(windowID: UUID())
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: address)!, title: "Example")
        browser.lay([tab])
        browser.activeID = tab.id
        return (browser, tab)
    }

    /// Until the card has its pinned files (none here), as Keep waits.
    private func ready(_ scripts: Userscripts, _ tab: Tab) async {
        for _ in 0..<200 where scripts.offers[tab.id]?.ready != true { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func chosenFileReachesTheKeepCard() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wide-hn.user.js")
        try UserscriptTests.script([
            "@name         Wide Hacker News", "@namespace    https://example.test/", "@version      1.2.0",
            "@description  Uses the whole window.", "@match        https://news.ycombinator.com/*", "@grant        GM_addStyle",
        ], body: "GM_addStyle('#hnmain { width: 100% }');").write(to: file, atomically: true, encoding: .utf8)
        let scripts = Userscripts(root: dir.appendingPathComponent("kept", isDirectory: true))
        let (browser, tab) = window("https://example.test/")
        defer { browser.letGo() }

        // No tab named: the page in front, as Settings' row sends it.
        scripts.add(file, browser: browser)
        await ready(scripts, tab)
        let offer = try #require(scripts.offers[tab.id])
        #expect(offer.ready)
        #expect(offer.problem == nil)
        #expect(!offer.tried)
        #expect(offer.url == file)
        #expect(offer.script.name == "Wide Hacker News")
        #expect(offer.script.version == "1.2.0")
        #expect(offer.script.matches == ["https://news.ycombinator.com/*"])
        #expect(offer.script.permission == "Run code on news.ycombinator.com.")
        #expect(offer.facts == "Userscript 1.2.0")
        // Nothing is kept before Keep, and the page stays where it was.
        #expect(scripts.records.isEmpty)
        #expect(tab.address?.absoluteString == "https://example.test/")
    }

    @Test func droppedFileIsTheJavaScriptOne() {
        let script = URL(fileURLWithPath: "/tmp/a.user.js"), plain = URL(fileURLWithPath: "/tmp/b.js")
        let picture = URL(fileURLWithPath: "/tmp/c.png"), web = URL(string: "https://example.test/d.user.js")!
        #expect(Userscripts.dropped([picture, script]) == script)
        #expect(Userscripts.dropped([plain]) == plain)
        #expect(Userscripts.dropped([picture, web]) == nil)
    }

    @Test func droppedFileReachesTheCardOfTheTabItWasDroppedFor() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dark.user.js")
        try UserscriptTests.script(["@name Dark Example", "@version 0.3", "@match *://*.example.test/*", "@grant GM_setValue"], body: "GM_setValue('on', 1);")
            .write(to: file, atomically: true, encoding: .utf8)
        let scripts = Userscripts(root: dir.appendingPathComponent("kept", isDirectory: true))
        let (browser, front) = window("https://front.example.test/")
        defer { browser.letGo() }
        let other = Tab(bench: true)
        other.restore(url: URL(string: "https://other.example.test/")!, title: "Other")

        // Site Controls' block names its own tab.
        scripts.add(try #require(Userscripts.dropped([file])), browser: browser, tab: other)
        await ready(scripts, other)
        #expect(scripts.offers[front.id] == nil)
        let offer = try #require(scripts.offers[other.id])
        #expect(offer.script.name == "Dark Example")
        #expect(offer.script.version == "0.3")
        #expect(offer.script.permission == "Run code on example.test. Keeps its own settings.")
    }

    @Test func chosenFileThatIsNotAUserscriptSaysSo() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plain.js")
        try "function f() { return 1 }".write(to: file, atomically: true, encoding: .utf8)
        let scripts = Userscripts(root: dir.appendingPathComponent("kept", isDirectory: true))
        let (browser, tab) = window("https://example.test/")
        defer { browser.letGo() }

        scripts.add(file, browser: browser)
        for _ in 0..<200 where !browser.toaster.shown { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(scripts.offers[tab.id] == nil)
        #expect(browser.toaster.words == "plain.js isn’t a userscript: it has no ==UserScript== block.")
        #expect(tab.address?.absoluteString == "https://example.test/")
    }
}
