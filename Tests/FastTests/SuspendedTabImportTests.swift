import Foundation
import Testing
@testable import Fast

/// Tabs a suspender extension put to sleep in Chrome, and Brave's other
/// channels (feedback #288, register 371): what another browser has open
/// comes as the pages it is, and a browser on this Mac is found.
struct SuspendedTabImportTests {
    typealias S = ChromiumSessionTests

    static let greatSuspender = "chrome-extension://klbibkeccnjlkjkiokjodocebajanakg/suspended.html"
    static let marvellous = "chrome-extension://noogafoofpebimajpfpamcfhoaifemoa/suspended.html"
    static let tabSuspender = "chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/park.html"

    @Test(arguments: [
        // The Great Suspender: the address last and as it was, its own ? & and # in it.
        (SuspendedTabImportTests.greatSuspender + "#ttl=Docs%3A%20Plan&pos=0&uri=https://docs.test/d/1?tab=t.0&x=2#heading=h.1",
         "https://docs.test/d/1?tab=t.0&x=2#heading=h.1", "Docs: Plan"),
        // Marvellous Suspender: the same, a page's own &t= kept.
        (SuspendedTabImportTests.marvellous + "#ttl=Video&pos=120&uri=https://www.youtube.test/watch?v=abc&t=30s",
         "https://www.youtube.test/watch?v=abc&t=30s", "Video"),
        // Tab Suspender: encoded, in the query, with an icon address beside it.
        (SuspendedTabImportTests.tabSuspender + "?title=Mail%20%C2%B7%20Inbox&url=https%3A%2F%2Fmail.test%2Fu%2F0%2F%23inbox&tabId=12&sessionId=99&icon=https%3A%2F%2Fmail.test%2Ffavicon.ico",
         "https://mail.test/u/0/#inbox", "Mail \u{00B7} Inbox"),
        // Written as it was, with the wrapper's own name after it.
        ("chrome-extension://abcdefghijklmnopabcdefghijklmnop/suspend.html?url=https://news.test/a&title=News+Today",
         "https://news.test/a", "News Today"),
        // Encoded twice, after the #.
        ("chrome-extension://abcdefghijklmnopabcdefghijklmnop/sleep.html#url=https%253A%252F%252Fdeep.test%252Fx%253Fq%253D1",
         "https://deep.test/x?q=1", "Session title"),
    ])
    func aSuspendedTabComesAsItsPage(_ address: String, _ page: String, _ title: String) throws {
        let entry = try #require(TabImport.entry(address, "Session title"))
        #expect(entry.url.absoluteString == page)
        #expect(entry.title == title)
    }

    @Test(arguments: [
        "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html",
        "chrome-extension://abcdefghijklmnopabcdefghijklmnop/onetab.html#",
        SuspendedTabImportTests.greatSuspender + "#ttl=Script&uri=javascript:alert(1)",
        SuspendedTabImportTests.greatSuspender + "#ttl=Settings&uri=chrome://settings",
        SuspendedTabImportTests.tabSuspender + "?url=file%3A%2F%2F%2Fetc%2Fhosts",
        SuspendedTabImportTests.tabSuspender + "?title=Icon&icon=https%3A%2F%2Fmail.test%2Ffavicon.ico",
        "chrome://newtab/",
        "about:blank",
    ])
    func otherPagesStayOut(_ address: String) {
        #expect(TabImport.entry(address, "") == nil)
    }

    @Test func webPagesAreTakenAsBefore() {
        #expect(TabImport.entry("https://plain.test/a?uri=https://other.test/", "Plain")?.url.absoluteString == "https://plain.test/a?uri=https://other.test/")
        #expect(TabImport.entry("http://plain.test/", "Plain")?.title == "Plain")
    }

    /// One normal tab, one pinned and suspended, one suspended in a group,
    /// one extension page of no web page: three come, in order.
    static var suspendedSession: Data {
        var data = Data("SNSS".utf8) + S.int(3)
        data += S.command(0, S.int(10) + S.int(1)) + S.command(2, S.int(1) + S.int(0))
        data += S.navigation(1, 0, "https://one.test/", "One")
        data += S.command(0, S.int(10) + S.int(2)) + S.command(2, S.int(2) + S.int(1))
        data += S.navigation(2, 0, "https://older.test/", "Older")
        data += S.navigation(2, 1, greatSuspender + "#ttl=Docs&pos=0&uri=https://docs.test/", "Docs")
        data += S.command(7, S.int(2) + S.int(1)) + S.command(12, S.int(2) + Data([1, 0, 0, 0]))
        data += S.command(0, S.int(10) + S.int(3)) + S.command(2, S.int(3) + S.int(2))
        data += S.navigation(3, 0, tabSuspender + "?title=Plan&url=https%3A%2F%2Fplan.test%2Fq", "Plan")
        let token = Data((1...16).map(UInt8.init))
        data += S.command(25, S.int(3) + S.int(0) + token + Data([1, 0, 0, 0, 0, 0, 0, 0]))
        let metadata = token + S.string("Research", utf16: true) + S.int(1) + S.int(0)
        data += S.command(27, S.int(Int32(metadata.count)) + metadata)
        data += S.command(0, S.int(10) + S.int(4)) + S.command(2, S.int(4) + S.int(3))
        data += S.navigation(4, 0, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html", "Options")
        return data
    }

    @Test func suspendedTabsInAChromeSessionComeWithTheirPinsAndGroups() {
        let tabs = Snss.tabs(in: Self.suspendedSession)
        #expect(tabs.pinned.map(\.url.absoluteString) == ["https://docs.test/"])
        #expect(tabs.open.map(\.url.absoluteString) == ["https://one.test/", "https://plan.test/q"])
        #expect(tabs.open.last?.title == "Plan")
        #expect(tabs.open.last?.folder == "Research")
    }

    /// The page shown is the suspended one, not the older page before it.
    @Test func theSelectedSuspendedPageIsUnwrappedNotAnOlderOne() {
        var data = Data("SNSS".utf8) + S.int(3)
        data += S.command(0, S.int(1) + S.int(1))
        data += S.navigation(1, 0, "https://older.test/", "Older")
        data += S.navigation(1, 1, Self.marvellous + "#ttl=Now&pos=0&uri=https://now.test/", "Now")
        data += S.command(7, S.int(1) + S.int(1))
        #expect(Snss.tabs(in: data).open.map(\.url.host) == ["now.test"])
    }

    @Test func aChromeProfileBringsItsSuspendedTabs() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("Default/Sessions/Session_1", Self.suspendedSession)
        let places = try TabImport.places(in: fixture.source(Chromium.known[1]))
        #expect(places.count == 1)
        #expect(places.first?.pinned.count == 1)
        #expect(places.first?.open.count == 2)
    }

    @Test func braveBetaAndNightlyAreKnown() throws {
        for (name, folder, bundle) in [("Brave", "BraveSoftware/Brave-Browser", "com.brave.Browser"),
                                       ("Brave Beta", "BraveSoftware/Brave-Browser-Beta", "com.brave.Browser.beta"),
                                       ("Brave Nightly", "BraveSoftware/Brave-Browser-Nightly", "com.brave.Browser.nightly")] {
            let source = try #require(Chromium.known.first { $0.name == name })
            #expect(source.folder == folder)
            #expect(source.bundle == bundle)
            #expect(source.service == "Brave Safe Storage")
        }
        #expect(Set(Chromium.known.map(\.name)).count == Chromium.known.count)
        #expect(Set(Chromium.known.map(\.folder)).count == Chromium.known.count)
    }

    @Test func aBraveBetaProfileReadsItsTabs() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("Default/Sessions/Session_1", S.session)
        let beta = try #require(Chromium.known.first { $0.name == "Brave Beta" })
        let places = try TabImport.places(in: fixture.source(beta))
        #expect(places.map(\.id) == ["Brave Beta:Default"])
        #expect(places.first?.pinned.count == 1)
    }

    /// A data folder macOS keeps from Yab is said, not taken for nothing.
    @Test func anUnreadableDataFolderIsAnErrorNotNothing() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("Default/Sessions/Session_1", S.session)
        let files = FileManager.default
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.root.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path) }
        let brave = try #require(Chromium.known.first { $0.name == "Brave" })
        #expect(throws: TabImport.Trouble.self) { try TabImport.places(in: fixture.source(brave)) }
    }
}
