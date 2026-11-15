import AppKit
import Foundation
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
        #expect(plan(names: site, changed: true) == .wear)
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
        #expect(plan(source: "", fresh: false, names: nil) == .wear)
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
}
