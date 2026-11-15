import Foundation
import Testing
@testable import Fast

/// Which browsers count as on this Mac, and the tabs that can't come said,
/// not dropped (feedback #288, register 371).
struct BrowserDiscoveryTests {
    /// A Brave whose app Launch Services doesn't know.
    static func absent(_ root: URL) -> Chromium.Source {
        Chromium.Source(name: "Brave Test", folder: "BraveSoftware/Brave-Browser-Test", service: "Brave Safe Storage",
                        account: "Brave", bundle: "dev.yab.tests.absent-browser", dataRoot: root)
    }

    @Test func aBrowserIsFoundByItsDataWithoutItsApp() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("Default/Preferences", Data("{}".utf8))
        let source = Self.absent(fixture.root)
        #expect(source.app == nil)
        #expect(source.present)
        #expect(Chromium.installed(among: [source]).map(\.name) == ["Brave Test"])
        // No folder at all: not on this Mac.
        let gone = Self.absent(fixture.root.appendingPathComponent("missing"))
        #expect(!gone.present)
        #expect(gone.scan.trouble == nil)
        #expect(Chromium.installed(among: [gone]).isEmpty)
    }

    @Test func anUnreadableDataFolderIsListedAndSaysWhy() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("Default/Sessions/Session_1", ChromiumSessionTests.session)
        let files = FileManager.default
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.root.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path) }
        let source = Self.absent(fixture.root)
        #expect(source.profiles.isEmpty)
        #expect(source.scan.trouble != nil)
        #expect(Chromium.installed(among: [source]).count == 1)
        #expect(throws: TabImport.Trouble.folderUnreadable) { try TabImport.places(in: source.authorizingImport()) }
    }

    @MainActor
    @Test func theFolderTroubleHasItsWordsAndCode() {
        let brave = Chromium.known.first { $0.name == "Brave Nightly" }!
        #expect(TabImport.Trouble.folderUnreadable.code == 4)
        #expect(TabImport.explain(TabImport.Trouble.folderUnreadable, from: brave)
                == "Couldn't read Brave Nightly's tabs: its data folder is there but can't be opened")
        #expect(Bringing.notice(brave, tabs: .folderUnreadable) == "Brave Nightly's folder can't be opened")
        let beta = Chromium.known.first { $0.name == "Brave Beta" }!
        #expect(Notice.headWidth(TabImport.Trouble.folderUnreadable.briefly(beta.name)) < Notice.longest)
    }

    @Test func extensionPagesThatCantComeAreCounted() throws {
        #expect(Snss.tabs(in: SuspendedTabImportTests.suspendedSession).left == 1)
        #expect(Snss.tabs(in: ChromiumSessionTests.session).left == 0)
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("Default/Sessions/Session_1", SuspendedTabImportTests.suspendedSession)
        let chrome = fixture.source(Chromium.known[1])
        let place = try #require(try TabImport.places(in: chrome).first)
        #expect(place.left == 1)
        #expect(TabBringer.detail(place, withOpen: true) == "1 pin, 2 open, 1 extension page can't come")
        #expect(TabBringer.leftWords(1, from: chrome) == "1 Chrome tab is an extension page and couldn't be imported")
        #expect(TabBringer.leftWords(3, from: chrome) == "3 Chrome tabs are extension pages and couldn't be imported")
        #expect(TabImport.extensionPage("chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html"))
        #expect(!TabImport.extensionPage(SuspendedTabImportTests.greatSuspender + "#uri=https://docs.test/"))
    }
}
