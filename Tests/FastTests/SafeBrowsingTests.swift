import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// The opt-in local phishing check (SafeBrowsing.swift): how a host is
/// asked about, what the list's shape must be, and that the answer fails
/// open, off, no list or a broken one, nothing is stopped.
@Suite(.serialized)
struct SafeBrowsingTests {
    /// The list beside the rest of what the app keeps: one of the test's
    /// own, never the test world's, and pointed at, or the test reads
    /// whatever the last one left behind.
    @MainActor static func ownFile() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-browsing-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("phishing-hashes.json")
        SafeBrowsing.file = file
        return file
    }

    static func list(hashes: [String], updated: Double = Date().timeIntervalSince1970) -> Data {
        let json: [String: Any] = ["updated": updated, "hashes": hashes]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @MainActor @Test func hostIsAskedUnderItsOwnNames() {
        #expect(SafeBrowsing.asking(host: "evil.example.com") == ["evil.example.com", "example.com"])
        #expect(SafeBrowsing.asking(host: "WWW.Example.COM") == ["www.example.com", "example.com"])
        // Two labels already: no third shape.
        #expect(SafeBrowsing.asking(host: "example.com") == ["example.com"])
        // An address asks as itself.
        #expect(SafeBrowsing.asking(host: "192.168.1.10") == ["192.168.1.10"])
    }

    static let exampleHash = "a379a6f6eeafb9a55e378c118034e2751e682fab9f2d30ab13d2125586ce1947"

    @MainActor @Test func hashIsTheWholeSha256() {
        let hash = SafeBrowsing.hash("Example.COM")
        #expect(hash.count == 64)
        // The host is folded to lower case first: the digest of
        // "example.com", as `shasum -a 256` gives it.
        #expect(hash == Self.exampleHash)
    }

    @MainActor @Test func listIsReadWholeOrRefused() {
        let other = String(repeating: "0", count: 64)
        // What the list holds: whole hashes, and when.
        let read = SafeBrowsing.decode(Self.list(hashes: [Self.exampleHash, other]))
        #expect(read?.hashes == [Self.exampleHash, other])
        // Upper case is folded in, so a list may be written either way.
        #expect(SafeBrowsing.decode(Self.list(hashes: [Self.exampleHash.uppercased()]))?.hashes == [Self.exampleHash])
        // Not 64 hex characters, a bare prefix among them: left out.
        let mixed = SafeBrowsing.decode(Self.list(hashes: ["a379a6f6", String(repeating: "z", count: 64), Self.exampleHash]))
        #expect(mixed?.hashes == [Self.exampleHash])
        // The old list of prefixes alone holds nothing that can be
        // confirmed: refused, and the check fails open.
        let prefixes = try! JSONSerialization.data(withJSONObject: ["updated": 1.0, "prefixes": ["a379a6f6"]])
        #expect(SafeBrowsing.decode(prefixes) == nil)
        // Empty or broken: no list, and nothing is stopped by a blank.
        #expect(SafeBrowsing.decode(Self.list(hashes: [])) == nil)
        #expect(SafeBrowsing.decode(Data("not json".utf8)) == nil)
        #expect(SafeBrowsing.decode(#"{"hashes": 5}"#.data(using: .utf8)!) == nil)
    }

    @MainActor @Test func nothingIsStoppedWithoutAListOrTheSetting() throws {
        let file = Self.ownFile()
        SafeBrowsing.file = file
        defer {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            Store.settings.removeObject(forKey: SafeBrowsing.key)
            SafeBrowsing.reload()
        }
        let bad = URL(string: "https://phish.example.com/login")!

        // Off by default: the page loads as it always did.
        Store.settings.set(false, forKey: SafeBrowsing.key)
        #expect(SafeBrowsing.flag(bad) == nil)

        // On, but no list on disk yet: fails open.
        Store.settings.set(true, forKey: SafeBrowsing.key)
        SafeBrowsing.reload()
        #expect(SafeBrowsing.flag(bad) == nil)

        // A list that holds the host's hash: stopped, with the host and
        // the address it was going to.
        let hash = SafeBrowsing.hash("phish.example.com")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.list(hashes: [hash, String(repeating: "0", count: 64)]).write(to: file)
        SafeBrowsing.reload()
        let flagged = try #require(SafeBrowsing.flag(bad))
        #expect(flagged.host == "phish.example.com")
        #expect(flagged.url == bad)

        // A subdomain asks as the listed site too.
        #expect(SafeBrowsing.flag(URL(string: "https://login.phish.example.com/")!) != nil)

        // Going on keeps the site, this session only, with what is under it.
        SafeBrowsing.admit("phish.example.com")
        #expect(SafeBrowsing.flag(bad) == nil)
        #expect(SafeBrowsing.flag(URL(string: "https://login.phish.example.com/")!) == nil)

        // A site the list holds a different shape of is not stopped by it.
        #expect(SafeBrowsing.flag(URL(string: "https://example.org/")!) == nil)
    }

    /// A warning needs the whole hash: a host whose hash only begins as a
    /// listed one does (one in ten thousand hosts shares four bytes with a
    /// list of a few hundred thousand) loads as it always did.
    @MainActor @Test func aSharedPrefixAloneStopsNothing() throws {
        let file = Self.ownFile()
        defer {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            Store.settings.removeObject(forKey: SafeBrowsing.key)
            SafeBrowsing.reload()
        }
        Store.settings.set(true, forKey: SafeBrowsing.key)
        let innocent = URL(string: "https://bakery.example.net/")!
        let whole = SafeBrowsing.hash("bakery.example.net")
        // Its first four bytes, then another host's rest.
        let lookalike = String(whole.prefix(8)) + String(repeating: whole.hasSuffix("0") ? "1" : "0", count: 56)
        #expect(lookalike != whole)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.list(hashes: [lookalike]).write(to: file)
        SafeBrowsing.reload()
        #expect(SafeBrowsing.holding == 1)
        #expect(!SafeBrowsing.bad(innocent))
        #expect(SafeBrowsing.flag(innocent) == nil)

        // The whole hash, and it is stopped.
        try Self.list(hashes: [lookalike, whole]).write(to: file)
        SafeBrowsing.reload()
        #expect(SafeBrowsing.flag(innocent) != nil)
    }

    /// Going on excuses the host it was for and what is under it, not the
    /// listed domain over it or that domain's other hosts.
    @MainActor @Test func goingOnExcusesTheHostNotItsDomain() throws {
        let file = Self.ownFile()
        defer {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            Store.settings.removeObject(forKey: SafeBrowsing.key)
            SafeBrowsing.reload()
        }
        Store.settings.set(true, forKey: SafeBrowsing.key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.list(hashes: [SafeBrowsing.hash("phish.example.com")]).write(to: file)
        SafeBrowsing.reload()
        let login = URL(string: "https://login.phish.example.com/")!
        SafeBrowsing.admit(try #require(SafeBrowsing.flag(login)).host)
        #expect(SafeBrowsing.flag(login) == nil)
        #expect(SafeBrowsing.flag(URL(string: "https://a.login.phish.example.com/")!) == nil)
        #expect(SafeBrowsing.flag(URL(string: "https://phish.example.com/")!) != nil)
        #expect(SafeBrowsing.flag(URL(string: "https://pay.phish.example.com/")!) != nil)
    }

    // MARK: - the gate itself, with a real WebKit page

    /// A browser with one real tab, its list pointed at a folder of the
    /// test's own, the check on, cleaned up after as the other fixtures
    /// are (ModifiedLinkFocusTests). A high port nobody listens on for
    /// the site: the gate answers before any connection, and anything
    /// that ever got past it is refused at once, so a wrong result can't
    /// quietly pass. (Not port 9: WebKit itself refuses the old service
    /// ports before the gate ever sees the load.)
    @MainActor private func withBrowser(_ check: (Browser, Tab, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        let file = try Self.ownFile()
        let blocked = URL(string: "http://127.0.0.1:47119/pay")!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.list(hashes: [SafeBrowsing.hash("127.0.0.1")]).write(to: file)
        SafeBrowsing.reload()
        Store.settings.set(true, forKey: SafeBrowsing.key)
        defer {
            Store.settings.removeObject(forKey: SafeBrowsing.key)
            SafeBrowsing.reload()
        }
        let browser = Browser(windowID: UUID())
        defer {
            for tab in browser.tabs + browser.outside { tab.built?.stopLoading() }
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        // This fixture invokes WebKit delegate/SPI contracts directly.
        let tab = Tab(shy: true, factory: .webKitOnly)
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        tab.go(to: URL(string: "about:blank")!)
        browser.activeID = tab.id
        // The page is the browser's own and the list is live: if either
        // stops being so, the test says which leg gave way, not just that
        // nothing was stopped.
        #expect(tab.page.events === browser)
        #expect(SafeBrowsing.on)
        #expect(SafeBrowsing.holding != nil)
        #expect(SafeBrowsing.asking(host: blocked.host() ?? "") == ["127.0.0.1"])
        #expect(SafeBrowsing.bad(blocked))
        #expect(SafeBrowsing.flag(blocked) != nil)
        try await check(browser, tab, blocked)
    }

    /// A listed page never loads: the policy gate cancels the navigation
    /// before any connection is made to it, and the tab says why.
    @MainActor @Test func aListedPageIsStoppedBeforeItLoads() async throws {
        try await withBrowser { _, tab, blocked in
            #expect(tab.flagged == nil)
            requireNativeWebKitFixture(tab, "SafeBrowsingTests").load(URLRequest(url: blocked))

            // WebKit's own decision point, answered without a network.
            for _ in 0..<100 where tab.flagged == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let flagged = try #require(tab.flagged)
            #expect(flagged.host == "127.0.0.1")
            #expect(flagged.url == blocked)
            // Nothing of the page came up: no commit, no address.
            #expect(requireNativeWebKitFixture(tab, "SafeBrowsingTests").url?.host() != blocked.host())
        }
    }

    /// Going on loads it again, with the site excused for the session;
    /// the stop this time is the socket's, not the list's.
    @MainActor @Test func goingOnLoadsTheSiteAgainForTheSession() async throws {
        try await withBrowser { _, tab, blocked in
            requireNativeWebKitFixture(tab, "SafeBrowsingTests").load(URLRequest(url: blocked))
            for _ in 0..<100 where tab.flagged == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try #require(tab.flagged != nil)
            tab.continuePastFlagged()
            #expect(tab.flagged == nil)
            #expect(SafeBrowsing.flag(blocked) == nil)
            #expect(SafeBrowsing.flag(URL(string: "http://127.0.0.1:9/again")!) == nil)

            for _ in 0..<100 where tab.flagged == nil && requireNativeWebKitFixture(tab, "SafeBrowsingTests").isLoading {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(tab.flagged == nil)
        }
    }

    /// The flagged address typed over a page: Go Back keeps that page, its
    /// address and title again, without a step back in its history (the
    /// flagged page never loaded, so there was nothing to step back over).
    @MainActor @Test func goBackStaysOnThePageYouWereOn() async throws {
        try await withBrowser { browser, tab, blocked in
            let here = URL(string: "http://127.0.0.2:47119/here")!
            requireNativeWebKitFixture(tab, "SafeBrowsingTests").loadHTMLString("<title>Where you were</title><p>here</p>", baseURL: here)
            for _ in 0..<100 where requireNativeWebKitFixture(tab, "SafeBrowsingTests").url != here || requireNativeWebKitFixture(tab, "SafeBrowsingTests").isLoading || tab.title.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try #require(requireNativeWebKitFixture(tab, "SafeBrowsingTests").url == here)
            let before = requireNativeWebKitFixture(tab, "SafeBrowsingTests").backForwardList.backList.count

            tab.go(to: blocked)
            for _ in 0..<100 where tab.flagged == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try #require(tab.flagged != nil)

            tab.backFromFlagged()
            #expect(tab.flagged == nil)
            #expect(tab.address == here)
            #expect(tab.title == "Where you were")
            #expect(!tab.gone)
            #expect(browser.tabs.contains { $0 === tab })
            // Still there a beat later: no back step under way.
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(requireNativeWebKitFixture(tab, "SafeBrowsingTests").url == here)
            #expect(requireNativeWebKitFixture(tab, "SafeBrowsingTests").backForwardList.backList.count == before)
        }
    }

    /// A tab that never showed a page, opened for the flagged address:
    /// Go Back closes it rather than leaving it blank.
    @MainActor @Test func goBackClosesATabThatNeverShowedAPage() async throws {
        try await withBrowser { browser, tab, blocked in
            tab.go(to: blocked)
            for _ in 0..<100 where tab.flagged == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try #require(tab.flagged != nil)
            tab.backFromFlagged()
            #expect(tab.flagged == nil)
            #expect(tab.gone)
            #expect(!browser.tabs.contains { $0 === tab })
        }
    }

    /// A frame's own loads are not the page: the list stops the page you
    /// ask for, not a subresource (its broken certificate the browser
    /// already refuses quietly).
    @MainActor @Test func aFrameLoadIsNotStopped() async throws {
        final class FrameAction: WKNavigationAction {
            let destination: URL
            init(_ destination: URL) {
                self.destination = destination
                super.init()
            }
            override var request: URLRequest { URLRequest(url: destination) }
            override var navigationType: WKNavigationType { .other }
            override var targetFrame: WKFrameInfo? { nil }
            override var shouldPerformDownload: Bool { false }
            override var modifierFlags: NSEvent.ModifierFlags { [] }
            override var buttonNumber: Int { 0 }
            @objc(_isUserInitiated) func userInitiated() -> Bool { true }
            override func value(forKey key: String) -> Any? {
                if key == "sourceFrame" { return nil }
                return super.value(forKey: key)
            }
        }
        try await withBrowser { browser, tab, blocked in
            var decision: WKNavigationActionPolicy?
            browser.webView(requireNativeWebKitFixture(tab, "SafeBrowsingTests"), decidePolicyFor: FrameAction(blocked)) { decision = $0 }
            #expect(decision == .allow)
            #expect(tab.flagged == nil)
        }
    }

    /// The one address the check ever goes to: the list, whole, from the
    /// feed's own site, the same for every page ever visited. Nothing of
    /// a visit, no page, host or query, is ever sent to it, and no
    /// site, no list: the check stays home entirely.
    @MainActor @Test func theListIsTheOnlyAddressEverAsked() throws {
        let site = URL(string: "https://yetanotherbrowser.com/")!
        let asked = try #require(SafeBrowsing.listURL(site: site))
        #expect(asked == URL(string: "https://yetanotherbrowser.com/lists/phishing.json")!)
        #expect(SafeBrowsing.listURL(site: site) == asked)
        #expect(asked.query == nil && asked.fragment == nil)
        // No host of its own: no list, and the check stays home entirely.
        #expect(SafeBrowsing.listURL(site: URL(fileURLWithPath: "/tmp/")) == nil)
    }
}
