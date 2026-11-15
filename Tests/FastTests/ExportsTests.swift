import Foundation
import Testing
@testable import Fast

// Files other browsers write out: a CSV of passwords, a bookmarks file, a
// history export.
struct ExportsTests {
    // MARK: CSV

    @Test func aByteOrderMarkIsNotPartOfTheFirstColumn() {
        let text = "\u{FEFF}url,username,password\nhttps://www.example.com/login,ann,secret\n"
        let found = Vault.logins(csv: text)
        #expect(found.skipped == 0)
        #expect(found.logins.count == 1)
        #expect(found.logins.first?.host == "example.com")
        #expect(found.logins.first?.user == "ann")
    }

    @Test func quotesCommasAndNewlinesInsideAField() {
        let rows = Csv.rows("name,note\r\n\"Bank, the\",\"line one\nline \"\"two\"\"\"\r\n")
        #expect(rows == [["name", "note"], ["Bank, the", "line one\nline \"two\""]])
    }

    @Test func googlePasswordManagerExport() {
        let text = """
        name,url,username,password,note
        example.com,https://example.com/,ann@example.com,p1,
        router,http://192.168.1.1/,admin,p2,
        nothing,https://empty.example/,bob,,
        """
        let found = Vault.logins(csv: text)
        #expect(found.logins.map(\.host) == ["example.com", "192.168.1.1"])
        #expect(found.logins.map(\.clear) == [false, true])
        #expect(found.skipped == 1)
    }

    /// The file Zen and Firefox write from about:logins: every field quoted,
    /// their own account among the rows.
    @Test func firefoxAndZenExport() {
        let text = #"""
        "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
        "https://www.example.com","ann@example.com","p1",,"https://www.example.com","{0b1c2d3e-0000-4000-8000-000000000001}","1700000000000","1710000000000","1700000000000"
        "http://192.168.1.1","admin","p, with ""quotes""","Router",,"{0b1c2d3e-0000-4000-8000-000000000002}","1700000000000","1700000000000","1700000000000"
        "chrome://FirefoxAccounts","3f2a","{""version"":1}","Firefox Accounts credentials",,"{0b1c2d3e-0000-4000-8000-000000000003}","1700000000000","1700000000000","1700000000000"
        "https://empty.example","bob","",,"https://empty.example","{0b1c2d3e-0000-4000-8000-000000000004}","1700000000000","1700000000000","1700000000000"
        """#
        let found = Vault.logins(csv: text)
        #expect(found.logins.map(\.host) == ["example.com", "192.168.1.1"])
        #expect(found.logins.map(\.user) == ["ann@example.com", "admin"])
        #expect(found.logins.map(\.password) == ["p1", "p, with \"quotes\""])
        #expect(found.logins.map(\.clear) == [false, true])
        #expect(found.skipped == 2)
    }

    /// Safari and 1Password write a login's two-factor key as an otpauth://
    /// link, Bitwarden and LastPass as the key alone: both come with it, a
    /// row without one or with something else there comes without.
    @Test func twoFactorKeysComeWithTheirLogins() {
        let safari = """
        Title,URL,Username,Password,Notes,OTPAuth
        Example,https://example.com/,ann@example.com,p1,,otpauth://totp/Example:ann?secret=JBSWY3DPEHPK3PXP&issuer=Example
        Router,http://192.168.1.1/,admin,p2,,
        """
        let found = Vault.logins(csv: safari)
        #expect(found.codes == ["example.com\u{1}ann@example.com": "otpauth://totp/Example:ann?secret=JBSWY3DPEHPK3PXP&issuer=Example"])

        let bitwarden = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        ,,login,GitHub,,,0,https://github.com/login,ann,p3,JBSW Y3DP EHPK 3PXP
        ,,login,Shop,,,0,https://shop.example/,bob,p4,not a key
        """
        let bits = Vault.logins(csv: bitwarden)
        #expect(bits.logins.map(\.host) == ["github.com", "shop.example"])
        #expect(bits.codes == ["github.com\u{1}ann": "JBSW Y3DP EHPK 3PXP"])
    }

    /// Proton Pass writes an email and a username, often one of them empty.
    @Test func protonPassNameFromWhicheverIsFilled() {
        let proton = """
        type,name,url,email,username,password,note,totp,createTime,modifyTime,vault
        login,Shop,https://shop.example/,ann@example.com,,p1,,,1700000000,1700000000,Personal
        login,Forum,https://forum.example/,,annie,p2,,,1700000000,1700000000,Personal
        """
        #expect(Vault.logins(csv: proton).logins.map(\.user) == ["ann@example.com", "annie"])
    }

    // MARK: bookmarks

    /// The file Chrome and Firefox write: the bar marked, folders nested, the
    /// P and DT never closed.
    static let marked = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1" LAST_MODIFIED="2" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://github.com/" ADD_DATE="1">GitHub</A>
            <DT><H3>Work &amp; Play</H3>
            <DL><p>
                <DT><A HREF="https://linear.app/" ICON="data:image/png;base64,AAA">Linear</A>
                <DT><H3>Deep</H3>
                <DL><p>
                    <DT><A HREF="https://example.com/a?b=1&amp;c=2">A &lt;b&gt; &#8211; &#x263A;</A>
                </DL><p>
            </DL><p>
            <DT><A HREF="javascript:alert(1)">A bookmarklet</A>
        </DL><p>
        <DT><H3>Other bookmarks</H3>
        <DL><p>
            <DT><A HREF="https://news.ycombinator.com/">HN</A>
        </DL><p>
        <DT><A HREF="https://loose.example/">Loose</A>
    </DL><p>
    """

    @Test func readsFoldersAndLiftsTheBar() throws {
        let tree = try #require(BookmarkFile.parse(Self.marked))
        // The bar's contents at the top, first; then the rest in order.
        #expect(tree.map(\.title) == ["GitHub", "Work & Play", "Other bookmarks", "Loose"])
        let work = tree[1]
        #expect(work.isFolder)
        #expect(work.children?.map(\.title) == ["Linear", "Deep"])
        let deep = try #require(work.children?[1].children?.first)
        #expect(deep.url == "https://example.com/a?b=1&c=2")
        #expect(deep.title == "A <b> – ☺")
        // A bookmarklet isn't a page.
        #expect(Bookmarks.count(tree) == 5)
    }

    /// The file Safari writes: no mark on the bar, only its name.
    @Test func safariBarIsKnownByName() throws {
        let safari = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <HTML><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <Title>Bookmarks</Title><H1>Bookmarks</H1>
        <DT><H3 FOLDED>Favorites</H3>
        <DL><p>
        <DT><A HREF="https://www.apple.com/">Apple</A>
        </DL><p>
        <DT><H3 FOLDED>Bookmarks Menu</H3>
        <DL><p>
        <DT><H3 FOLDED>Favorites</H3>
        <DL><p><DT><A HREF="https://nested.example/">Nested</A></DL><p>
        </DL><p>
        <DT><H3 FOLDED id="com.apple.ReadingList">Reading List</H3>
        <DL><p><DT><A HREF="https://read.example/">Later</A></DL><p>
        </HTML>
        """
        let tree = try #require(BookmarkFile.parse(safari))
        #expect(tree.map(\.title) == ["Apple", "Bookmarks Menu", "Reading List"])
        // Only the top one is the bar: one called that inside a folder is a folder.
        #expect(tree[1].children?.first?.title == "Favorites")
        #expect(tree[1].children?.first?.isFolder == true)
    }

    @Test func somethingElseIsNotABookmarksFile() {
        #expect(BookmarkFile.parse("url,title\nhttps://a.example,A") == nil)
        #expect(BookmarkFile.parse("<html><body>hello</body></html>") == nil)
    }

    @Test func aFileCutShortKeepsWhatItHas() throws {
        let cut = "<DL><p><DT><H3>Half</H3><DL><p><DT><A HREF=\"https://a.example/\">A</A>"
        let tree = try #require(BookmarkFile.parse(cut))
        #expect(tree.first?.title == "Half")
        #expect(tree.first?.children?.first?.url == "https://a.example/")
    }

    @Test func eachFileHasAFolderOfItsOwn() {
        let file = { (name: String) in URL(fileURLWithPath: "/tmp/" + name) }
        #expect(BookmarkFile.name(for: file("bookmarks_9_24_26.html"), text: Self.marked) == "Bookmarks from bookmarks_9_24_26.html")
        #expect(BookmarkFile.name(for: file("work_links.html"), text: Self.marked) == "Work links")
        #expect(BookmarkFile.name(for: file("Bookmarks.html"), text: "<DT><H3 FOLDED>Favorites</H3><DL></DL>") == "Safari Bookmarks")
        #expect(BookmarkFile.name(for: file("bookmarks.html"), text: "<H1>Bookmarks Menu</H1><DL></DL>") == "Firefox Bookmarks")
    }

    @Test func textInWhateverEncodingItCame() {
        let utf16 = Data([0xFF, 0xFE]) + "url,title\n".data(using: .utf16LittleEndian)!
        #expect(HistoryFile.text(utf16) == "url,title\n")
        #expect(HistoryFile.text(Data([0x63, 0x61, 0x66, 0xE9])) == "café")
        #expect(HistoryFile.text(Data("naïve".utf8)) == "naïve")
    }

    @Test func aTimeNeverLandsInTheFuture() throws {
        let text = "url,time\nhttps://a.example/,4102444800\nhttps://b.example/,inf\n"
        let places = try #require(HistoryFile.places(in: text, fallback: Self.fallback))
        #expect(places[0].last <= Date())
        #expect(places[1].last == Self.fallback)
        #expect(HistoryFile.date(.nan) == nil)
        #expect(HistoryFile.date(.infinity) == nil)
    }

    // MARK: history

    static let fallback = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func historyCsvWithItsTimes() throws {
        let text = """
        \u{FEFF}URL,Title,Visit Time,Visit Count
        https://example.com/,Example,2026-09-01T10:00:00Z,4
        https://example.com/,Example,2026-09-02 10:00:00,
        https://swift.org/,"Swift, the language",1756720800,
        ftp://files.example/,Not a page,2026-09-01,
        https://no-time.example/,No time,,
        """
        let places = try #require(HistoryFile.places(in: text, fallback: Self.fallback))
        #expect(places.map(\.url.host) == ["example.com", "example.com", "swift.org", "no-time.example"])
        #expect(places[0].count == 4)
        #expect(places[0].last == Date(timeIntervalSince1970: 1_788_256_800))
        #expect(places[2].title == "Swift, the language")
        #expect(places[2].last == Date(timeIntervalSince1970: 1_756_720_800))
        #expect(places[3].last == Self.fallback)
    }

    @Test func safariHistoryJson() throws {
        let text = """
        {"metadata":{"browser_name":"Safari","data_type":"history"},
         "history":[{"url":"https://www.apple.com/","title":"Apple","time_usec":1756720800000000,"visit_count":3},
                    {"url":"about:blank","title":"","time_usec":1756720800000000}]}
        """
        let places = try #require(HistoryFile.places(in: text, fallback: Self.fallback))
        #expect(places.count == 1)
        #expect(places[0].count == 3)
        #expect(places[0].last == Date(timeIntervalSince1970: 1_756_720_800))
    }

    @Test func timesInEveryUnitExportersUse() {
        let when = Date(timeIntervalSince1970: 1_756_720_800)
        #expect(HistoryFile.date(1_756_720_800) == when)
        #expect(HistoryFile.date(1_756_720_800_000) == when)
        #expect(HistoryFile.date(1_756_720_800_000_000) == when)
        // Chromium: microseconds since 1601.
        #expect(HistoryFile.date((1_756_720_800 + 11_644_473_600) * 1_000_000) == when)
        // Safari's own: seconds since 2001.
        #expect(HistoryFile.date(when.timeIntervalSinceReferenceDate) == when)
    }

    @Test func writtenBookmarksComeBackAsTheyWere() throws {
        let kept = Date(timeIntervalSince1970: 1_756_720_800)
        let roots = [
            Bookmark(title: "Harbor <map>", url: "https://example.org/harbor?a=1&b=2", children: nil, added: kept),
            Bookmark.folder("Trips & \"plans\"", [
                Bookmark(title: "Ferry deck", url: "https://example.org/ferry", children: nil, added: kept),
                Bookmark.folder("Deeper", [Bookmark(title: "Pier", url: "https://example.org/pier", children: nil, added: kept)], added: kept),
            ], added: kept),
        ]
        let text = BookmarkFile.write(roots)
        // The file Chrome writes: its bar marked, its pages and folders dated.
        #expect(text.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(text.contains("PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks bar</H3>"))
        #expect(text.contains("HREF=\"https://example.org/harbor?a=1&amp;b=2\" ADD_DATE=\"1756720800\">Harbor &lt;map&gt;</A>"))
        let back = try #require(BookmarkFile.parse(text))
        func shape(_ nodes: [Bookmark]) -> [String] {
            nodes.flatMap { node -> [String] in
                node.url.map { ["\(node.title) \($0)"] } ?? ["[\(node.title)"] + shape(node.children ?? []) + ["]"]
            }
        }
        #expect(shape(back) == shape(roots))
        #expect(back.first?.added == kept)
    }

    @Test func aCsvWithNoAddressesIsNotHistory() {
        #expect(HistoryFile.places(in: "name,password\na,b", fallback: Self.fallback) == nil)
    }
}
