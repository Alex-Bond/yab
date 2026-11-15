import AppKit
import Foundation
import JavaScriptCore
import Testing
@testable import Fast

// Which icon a site wears: what a page declares, ranked; what a front page
// asked with no tab open may speak for; Google's G kept for its products.
struct IconsTests {
    private func link(_ href: String, rel: String = "icon", sizes: String = "", media: String = "") -> [String: String] {
        ["href": href, "rel": rel, "sizes": sizes, "type": "", "media": media]
    }

    @Test func rankPutsTheCrispOneFirstAndTheRootLast() {
        let page = URL(string: "https://example.com/inbox")!
        let ranked = Favicons.rank([
            link("https://example.com/tiny.png", sizes: "16x16"),
            link("https://example.com/touch.png", rel: "apple-touch-icon"),
            link("https://example.com/crisp.png", sizes: "64x64"),
            link("https://example.com/crisp.png", sizes: "64x64"),
        ], page: page, dark: false).map(\.absoluteString)
        #expect(ranked == ["https://example.com/crisp.png", "https://example.com/touch.png",
                           "https://example.com/tiny.png", "https://example.com/favicon.ico"])
    }

    @Test func rankTakesTheVariantForTheLook() {
        let page = URL(string: "https://example.com/")!
        let declared = [
            link("https://example.com/light.png", media: "(prefers-color-scheme: light)"),
            link("https://example.com/dark.png", media: "(prefers-color-scheme: dark)"),
        ]
        #expect(Favicons.rank(declared, page: page, dark: true).first?.absoluteString == "https://example.com/dark.png")
        #expect(Favicons.rank(declared, page: page, dark: false).first?.absoluteString == "https://example.com/light.png")
    }

    @Test func aFrontPageOnItsOwnSiteOffersWhatItDeclares() {
        let page = URL(string: "https://figma.com/")!
        let offered = Favicons.offered([link("https://static.figma.com/app/icon/2/icon-128.png", sizes: "128x128")],
                                       page: page, landed: URL(string: "https://www.figma.com/"))
        #expect(offered.map(\.absoluteString) == ["https://static.figma.com/app/icon/2/icon-128.png", "https://figma.com/favicon.ico"])
    }

    @Test func aSignInElsewhereLeavesTheHostsOwnFile() {
        // Drive without its cookies: Google's sign-in, or the page about
        // Drive on workspace.google.com with only Google's G on it.
        let page = URL(string: "https://drive.google.com/")!
        let signIn = Favicons.offered([], page: page,
                                      landed: URL(string: "https://accounts.google.com/v3/signin/identifier?continue=https://drive.google.com/"))
        #expect(signIn.map(\.absoluteString) == ["https://drive.google.com/favicon.ico"])
        let about = Favicons.offered([link("https://www.gstatic.com/images/branding/googleg/1x/googleg_gradient_standard_20dp.png")],
                                     page: page, landed: URL(string: "https://workspace.google.com/products/drive/"))
        #expect(about.map(\.absoluteString) == ["https://drive.google.com/favicon.ico"])
    }

    @Test func elsewhereAnIconNamedForTheSiteStillCounts() {
        let maps = Favicons.offered([link("https://www.google.com/images/branding/product/ico/web_maps_icon_32dp.ico", sizes: "32x32")],
                                    page: URL(string: "https://maps.google.com/")!, landed: URL(string: "https://www.google.com/maps"))
        #expect(maps.first?.absoluteString == "https://www.google.com/images/branding/product/ico/web_maps_icon_32dp.ico")
        let notion = Favicons.offered([link("https://www.notion.com/front-static/favicon.ico")],
                                      page: URL(string: "https://notion.so/")!, landed: URL(string: "https://www.notion.com/"))
        #expect(notion.first?.absoluteString == "https://www.notion.com/front-static/favicon.ico")
        // A name too short to tell anything apart names nothing.
        let x = Favicons.offered([link("https://elsewhere.example/x.png")],
                                 page: URL(string: "https://x.com/")!, landed: URL(string: "https://elsewhere.example/"))
        #expect(x.map(\.absoluteString) == ["https://x.com/favicon.ico"])
    }

    @Test func aNameIsAWordNotPartOfOne() {
        // app.example.com sent to someone else's sign-in: its touch icon
        // is the sign-in's, apple-touch-icon.png has no app in it.
        let sso = Favicons.offered([link("https://login.example-sso.com/apple-touch-icon.png", rel: "apple-touch-icon")],
                                   page: URL(string: "https://app.example.com/")!, landed: URL(string: "https://login.example-sso.com/"))
        #expect(sso.map(\.absoluteString) == ["https://app.example.com/favicon.ico"])
        #expect(Favicons.words("maps15_bnuw3a_32dp.ico").contains("maps"))
        #expect(!Favicons.words("apple-touch-icon.png").contains("app"))
    }

    // What a page's tab wears (Favicons.plan), with the site's icon kept
    // for the address its first page named.
    private let site = "https://github.githubassets.com/favicons/favicon.svg"
    private func plan(kept: Bool = true, source: String? = nil, fresh: Bool = true, names: String?,
                      changed: Bool = false, shy: Bool = false, rechecked: Bool = false) -> Favicons.Plan {
        Favicons.plan(kept: kept, source: source ?? site, fresh: fresh, names: names, changed: changed, shy: shy, rechecked: rechecked)
    }

    @Test func aPageNamingTheKeptIconWearsIt() {
        #expect(plan(names: site) == .wear)
        #expect(plan(names: site, changed: true) == .own)
        #expect(plan(names: site, shy: true) == .wear)
    }

    @Test func aPagesOtherIconIsItsTabsAlone() {
        // A pull request's state, set by its script; a Sheet on
        // docs.google.com beside a Doc; Calendar's next day.
        #expect(plan(names: "https://github.githubassets.com/favicons/favicon-failure.svg", changed: true) == .own)
        #expect(plan(names: "https://ssl.gstatic.com/docs/spreadsheets/favicon3.ico") == .own)
        #expect(plan(source: "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_6.ico",
                     names: "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_7.ico") == .own)
    }

    @Test func aPageNamingNoneWearsTheSites() {
        // A PDF, a JSON file, an error: not the 16 pixel file at the root.
        #expect(plan(names: nil) == .wear)
        #expect(plan(source: "", fresh: false, names: nil) == .keep)
        #expect(plan(kept: false, source: "", names: nil) == .keep)
    }

    @Test func thePagesIconIsTheSitesWhereNoPageNamedTheKeptOne() {
        // Nothing kept; Drive's G a front page offered; an icon kept
        // before Yab wrote its address down; a week old.
        #expect(plan(kept: false, source: "", names: site) == .keep)
        #expect(plan(source: "", names: "https://ssl.gstatic.com/docs/doclist/images/drive_2022q3_32dp.png") == .keep)
        #expect(plan(fresh: false, names: site) == .keep)
        // Once a session: asked and not had, offline say, the page's is
        // its tab's alone after.
        #expect(plan(source: "", names: site, rechecked: true) == .own)
        // Nor from a script's change after load: an unread count, a state.
        #expect(plan(source: "", names: site, changed: true) == .own)
        #expect(plan(fresh: false, names: "https://github.githubassets.com/favicons/favicon-pending.svg", changed: true) == .own)
        // Calendar has none until its script draws the day: that is kept.
        #expect(plan(kept: false, source: "", names: "https://calendar.google.com/x/calendar_7.ico", changed: true) == .keep)
    }

    @Test func anOldRootIconIsRefreshedOnceOnANormalVisit() {
        #expect(plan(source: "", fresh: false, names: nil) == .keep)
        #expect(plan(source: "", fresh: false, names: nil, rechecked: true) == .wear)
        #expect(plan(source: "", fresh: false, names: nil, shy: true) == .wear)
        #expect(plan(source: "", fresh: false, names: nil, changed: true) == .wear)
        #expect(plan(names: nil) == .wear)
        #expect(plan(fresh: false, names: nil) == .wear)
    }

    @Test func aPageNamingAnIconIsAskedAfterABotChecksPageNamedNone() {
        // Dribbble: AWS WAF's check page names no icon and the root
        // /favicon.ico is a 404; the page it reloads into names
        // /images/favicon-64x64.png. Feedback #90.
        let named = "https://dribbble.com/images/favicon-64x64.png"
        #expect(Favicons.asks(missed: nil, names: nil, changed: false))
        #expect(Favicons.asks(missed: [""], names: named, changed: false))
        // Each miss once a session: not the root again, not the named one.
        #expect(!Favicons.asks(missed: [""], names: nil, changed: false))
        #expect(!Favicons.asks(missed: [named, ""], names: named, changed: false))
        #expect(!Favicons.asks(missed: [named, ""], names: nil, changed: false))
        // Another page naming another icon, and a script's change, are asked.
        #expect(Favicons.asks(missed: [named, ""], names: "https://dribbble.com/other.png", changed: false))
        #expect(Favicons.asks(missed: [named, ""], names: named, changed: true))
    }

    @Test func aPrivatePagesIconIsKeptNowhere() {
        #expect(plan(kept: false, source: "", names: site, shy: true) == .own)
        #expect(plan(source: "", names: site, shy: true) == .own)
        #expect(plan(fresh: false, names: "https://example.com/unread-3.png", shy: true) == .own)
    }

    @Test func theSharedGIsFoundButNotWhereItIsTheHostsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let g = Data("the G".utf8), drive = Data("Drive".utf8), mail = Data("Gmail".utf8)
        for (key, data) in [
            "drive.google.com": g, "calendar.google.com": g, "calendar.google.com@dark": g, "myaccount.google.com": g,
            "google.com": g, "mail.google.com": mail, "docs.google.com": drive, "sheets.new": g, "example.com": g,
        ] {
            try data.write(to: folder.appendingPathComponent(key + ".png"))
        }
        #expect(Favicons.sharedG(in: folder) == ["calendar.google.com", "calendar.google.com@dark", "drive.google.com"])
    }

    @Test func aGOnlyOneHostKeepsIsNotTakenForTheShared() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("Drive".utf8).write(to: folder.appendingPathComponent("drive.google.com.png"))
        try Data("Calendar".utf8).write(to: folder.appendingPathComponent("calendar.google.com.png"))
        #expect(Favicons.sharedG(in: folder).isEmpty)
    }

    @Test func aKeptIconRemembersWhereItCameFrom() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png")
        try Data("picture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Favicons.source(of: file) == nil)
        Favicons.mark(file, source: "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_6.ico")
        #expect(Favicons.source(of: file) == "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_6.ico")
    }

    @Test func bareHosts() {
        #expect(Favicons.bare("www.notion.com") == "notion.com")
        #expect(Favicons.bare("drive.google.com") == "drive.google.com")
    }

    @Test func staleIconsAreLongUnseenSitesWithNothingOfTheirsKept() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        let files: [(key: String, date: Date)] = [
            ("old.example", ago(200)), ("old.example@dark", ago(200)),
            ("fresh.example", ago(10)),
            ("www.visited.example", ago(200)),
            ("tab.example", ago(300)), ("tab.example@dark", ago(300)),
            ("www.bookmark.example", ago(300)),
            ("visited-long-ago.example", ago(200)),
        ]
        let gone = Favicons.stale(files, keep: ["tab.example", "bookmark.example"],
                                  visited: ["visited.example": ago(5), "visited-long-ago.example": ago(120)], now: now)
        #expect(Set(gone) == ["old.example", "old.example@dark", "visited-long-ago.example"])
    }

    @MainActor @Test func heldLetsTheLeastLatelyAskedGo() {
        var held = Favicons.Held(limit: 10)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        for i in 0..<10 { held["\(i)"] = image }
        _ = held["0"]
        held["new"] = image
        #expect(held.count == 9)
        #expect(held["0"] != nil)
        #expect(held["new"] != nil)
        #expect(held["1"] == nil)
        #expect(held["2"] == nil)
        #expect(held["3"] != nil)
    }

    /// ChatGPT's favicon.svg colors its knot only from a <style>, which the
    /// Mac's SVG drawing ignores: an empty square, kept and worn by its pin
    /// (feedback #368). Not a picture; the same drawing with a fill is.
    @MainActor @Test func anIconThatDrawsNothingIsNoPicture() async {
        let styled = """
        <svg xmlns="http://www.w3.org/2000/svg" width="180" height="180" viewBox="0 0 180 180" fill="none">
        <style>:root { fill: #000; } @media (prefers-color-scheme: dark) { :root { fill: #fff; } }</style>
        <path d="M30 30h120v120H30z"/></svg>
        """
        let filled = """
        <svg xmlns="http://www.w3.org/2000/svg" width="180" height="180" viewBox="0 0 180 180" fill="#000">
        <path d="M30 30h120v120H30z"/></svg>
        """
        #expect(await Favicons.square(Data(styled.utf8)) == nil)
        #expect(await Favicons.square(Data(filled.utf8)) != nil)
        #expect(Favicons.blank(NSImage(size: NSSize(width: 16, height: 16))) == false)
        let clear = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }
        #expect(Favicons.blank(clear))
        let white = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill(); return true
        }
        #expect(!Favicons.blank(white))
    }

    // Notion's page icons: an emoji written into the page as an SVG, an
    // uploaded picture at an address of its own, each put in by its script
    // as it goes from page to page without loading one.
    private let emoji = #"data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="90">%F0%9F%9A%80</text></svg>"#

    @Test func anIconWrittenIntoThePageIsThePagesFirst() {
        let page = URL(string: "https://www.notion.so/team/Roadmap-0123456789abcdef0123456789abcdef")!
        let ranked = Favicons.rank([
            link("https://www.notion.so/images/logo-ios.png", rel: "apple-touch-icon"),
            link(emoji, rel: "shortcut icon"),
        ], page: page, dark: false)
        #expect(ranked.count == 3)
        #expect(ranked.first.map(Favicons.inline) == true)
        #expect(ranked.first.flatMap { Favicons.inlineType($0.absoluteString) } == "image/svg+xml")
        #expect(ranked.dropFirst().map(\.absoluteString) == ["https://www.notion.so/images/logo-ios.png", "https://www.notion.so/favicon.ico"])
    }

    @Test func onlyAPictureWrittenIntoThePageAndNotTooBigOne() {
        let page = URL(string: "https://example.com/")!
        let png = "data:image/png;base64," + Data(repeating: 7, count: 100).base64EncodedString()
        let huge = "data:image/png;base64," + Data(repeating: 7, count: Favicons.inlineLimit).base64EncodedString()
        let ranked = Favicons.rank([
            link("data:text/html,<script>alert(1)</script>"),
            link("data:application/octet-stream;base64,AAAA"),
            link("javascript:alert(1)"),
            link(huge),
            link(png),
        ], page: page, dark: false).map(\.absoluteString)
        #expect(ranked == [png, "https://example.com/favicon.ico"])
        #expect(Favicons.inlineType("data:IMAGE/X-ICON;base64,AAAA") == "image/x-icon")
        #expect(Favicons.inlineType("data:image/svg+xml;charset=utf-8,<svg/>") == "image/svg+xml")
        #expect(Favicons.inlineType("data:text/plain,hi") == nil)
        #expect(Favicons.inlineType("https://example.com/data:image/png,") == nil)
    }

    @Test func anIconTheScriptPutInGoesBeforeTheSitesFiles() {
        // Notion's uploaded icon in place of its favicon.ico, which a
        // touch icon outranked.
        let page = URL(string: "https://www.notion.so/team/Roadmap")!
        var mine = link("https://www.notion.so/image/https%3A%2F%2Fprod-files.example%2Fowl.png?table=block&id=1&width=64", rel: "shortcut icon")
        mine["set"] = "1"
        var touch = link("https://www.notion.so/images/logo-ios.png", rel: "apple-touch-icon")
        touch["set"] = "1"
        let ranked = Favicons.rank([touch, mine], page: page, dark: false).map(\.absoluteString)
        #expect(ranked.first == mine["href"])
        #expect(Favicons.rank([touch, link(mine["href"]!, rel: "shortcut icon")], page: page, dark: false).first?.absoluteString == touch["href"])
    }

    @Test func anIconWrittenIntoThePageIsNeverKept() {
        let uri = Favicons.address(emoji)!.absoluteString
        #expect(plan(names: uri) == .own)
        #expect(plan(names: uri, changed: true) == .own)
        #expect(plan(kept: false, source: "", names: uri) == .own)
        #expect(plan(kept: false, source: "", names: uri, changed: true) == .own)
        #expect(plan(source: "", names: uri) == .own)
        #expect(plan(fresh: false, names: uri) == .own)
        #expect(plan(source: "", fresh: false, names: uri, rechecked: true) == .own)
        #expect(plan(kept: false, source: "", names: uri, shy: true) == .own)
        // A page naming the site's icon again wears the kept one.
        #expect(plan(source: "https://www.notion.so/images/favicon.ico", names: "https://www.notion.so/images/favicon.ico") == .wear)
    }

    @Test func anIconWrittenIntoThePageIsReadHere() throws {
        let svg = try #require(Favicons.inlineBytes(Favicons.address(emoji)!.absoluteString))
        #expect(String(decoding: svg, as: UTF8.self).contains(">🚀</text>"))
        #expect(Favicons.glyph(inSVG: svg) == "🚀")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        #expect(Favicons.inlineBytes("data:image/png;base64," + bytes.base64EncodedString()) == bytes)
        #expect(Favicons.inlineBytes("data:image/svg+xml,%3Csvg%2F%3E#frag") == Data("<svg/>".utf8))
        #expect(Favicons.inlineBytes("data:text/html,<b>hi</b>") == nil)
        #expect(Favicons.inlineBytes("data:image/png;base64,") == nil)
        // Shapes are drawn as the Mac draws an SVG; only a lone character
        // is drawn as text.
        #expect(Favicons.glyph(inSVG: Data(#"<svg xmlns="http://www.w3.org/2000/svg"><rect width="9" height="9"/><text>A</text></svg>"#.utf8)) == nil)
        #expect(Favicons.glyph(inSVG: Data(#"<svg xmlns="http://www.w3.org/2000/svg"><text>Roadmap</text></svg>"#.utf8)) == nil)
        #expect(Favicons.glyph(inSVG: Data("not an svg".utf8)) == nil)
    }

    @MainActor @Test func anEmojiIconIsAPicture() async throws {
        let svg = try #require(Favicons.inlineBytes(Favicons.address(emoji)!.absoluteString))
        #expect(await Favicons.square(svg) != nil)
    }

    /// Every change is told once it settles, as Chromium's tab follows each
    /// one its page makes: a timer's or a count's icon each second, not
    /// once in half a minute (register R2573).
    @MainActor @Test func everyIconChangeIsTold() {
        #expect(IconRelay.settle <= 250)
        #expect(IconRelay.script.contains("timer = setTimeout(tell, \(IconRelay.settle));"))
        #expect(!IconRelay.script.contains("30000"))
    }

    /// A canvas's icon handed over as a blob: (Chrome and Arc wear it) is
    /// the page's own, first, and never fetched for the site or kept.
    @Test func aBlobIconIsThePagesOwn() {
        let page = URL(string: "https://app.example.com/inbox")!
        let blob = "blob:https://app.example.com/6f1c2d3e-0a1b-4c5d-8e9f-0123456789ab"
        #expect(Favicons.written(blob))
        #expect(Favicons.written("data:image/png;base64,AAAA"))
        #expect(!Favicons.written("https://app.example.com/favicon.ico"))
        var mine = link(blob, rel: "icon")
        mine["set"] = "1"
        let ranked = Favicons.rank([link("https://app.example.com/icon-192.png", rel: "icon", sizes: "192x192"), mine],
                                   page: page, dark: false).map(\.absoluteString)
        #expect(ranked.first == blob)
        #expect(plan(names: blob) == .own)
        #expect(plan(kept: false, source: "", names: blob, changed: true) == .own)
        #expect(plan(source: "", fresh: false, names: blob) == .own)
    }
}
