import AppKit
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Fast

/// Dark pages (DarkPages.swift, docs/dark-pages.md): Dark Reader's lists as
/// Yab reads them, the decision for a site, what is kept and synced, the
/// bridge's limits, and the page script with the real engine in WebKit.
struct DarkPagesTests {
    // MARK: the fixes config

    static let config = """
    *

    INVERT
    .common-logo

    CSS
    .common { color: ${black} !important; }

    ================================

    example.com
    example.*.*

    INVERT
    .logo
    img.mark

    CSS
    .header {
        background: ${white} !important;
    }

    IGNORE INLINE STYLE
    .picker *

    ================================

    docs.example.com

    IGNORE IMAGE ANALYSIS
    .hero

    IGNORE CSS URL
    ^https://cdn.example.com/skip

    ================================

    ^exact.org$

    INVERT
    .only-home
    """

    @Test func parsesBlocksCommandsAndURLs() throws {
        let fixes = DarkFix.parse(Self.config)
        #expect(fixes.count == 4)
        #expect(fixes[0].urls.map(\.raw) == ["*"])
        #expect(fixes[0].invert == [".common-logo"])
        #expect(fixes[1].urls.map(\.raw) == ["example.com", "example.*.*"])
        #expect(fixes[1].invert == [".logo", "img.mark"])
        #expect(fixes[1].css.contains(".header {\n    background: ${white} !important;\n}"))
        #expect(fixes[1].ignoreInlineStyle == [".picker *"])
        #expect(fixes[2].ignoreImageAnalysis == [".hero"])
        #expect(fixes[2].ignoreCSSUrl == ["^https://cdn.example.com/skip"])
    }

    @Test func mergesTheCommonBlockWithTheMostSpecificSite() throws {
        let lists = DarkLists()
        lists.use(fixes: Self.config, dark: "")
        let plain = lists.fixes(for: URL(string: "https://www.example.com/a")!)
        #expect(plain.invert == [".common-logo", ".logo", "img.mark"])
        #expect(plain.css.hasPrefix(".common"))
        #expect(plain.css.contains(".header"))
        // docs.example.com's block is longer than example.com's: it wins.
        let docs = lists.fixes(for: URL(string: "https://docs.example.com/guide")!)
        #expect(docs.invert == [".common-logo"])
        #expect(docs.ignoreImageAnalysis == [".hero"])
        // A wildcard label: example.co.uk is example.*.*.
        #expect(lists.fixes(for: URL(string: "https://example.co.uk/")!).invert.contains(".logo"))
        // Nothing for another site but the common block.
        let other = lists.fixes(for: URL(string: "https://northwind.news/")!)
        #expect(other.invert == [".common-logo"])
        #expect(other.json["css"] as? String == ".common { color: ${black} !important; }")
    }

    @Test func yabsOwnFixesAddToDarkReaders() throws {
        let lists = DarkLists()
        let own = "*\n\nIGNORE IMAGE ANALYSIS\n.own-everywhere\n\n====\n\nexample.com\n\nCSS\n.own-sheet { color: #fff !important; }\n\n====\n\nnorthwind.news\n\nINVERT\n.own-logo\n"
        lists.use(fixes: Self.config, dark: "", own: own)
        // Dark Reader's pick for the site stays, Yab's own block adds to it.
        let plain = lists.fixes(for: URL(string: "https://www.example.com/a")!)
        #expect(plain.invert == [".common-logo", ".logo", "img.mark"])
        #expect(plain.css.contains(".header"))
        #expect(plain.css.hasSuffix(".own-sheet { color: #fff !important; }"))
        #expect(plain.ignoreImageAnalysis == [".own-everywhere"])
        // docs.example.com: Dark Reader's longer block, and Yab's example.com.
        let docs = lists.fixes(for: URL(string: "https://docs.example.com/guide")!)
        #expect(docs.ignoreImageAnalysis == [".own-everywhere", ".hero"])
        #expect(docs.css.contains(".own-sheet"))
        let other = lists.fixes(for: URL(string: "https://northwind.news/")!)
        #expect(other.invert == [".common-logo", ".own-logo"])
        #expect(!other.css.contains(".own-sheet"))
    }

    @MainActor @Test func excelsSheetKeepsItsWhiteUnderTheInvert() throws {
        // Excel for the web: the grid canvas has a white ground of its own
        // and Dark Reader inverts it. Darkened first, then inverted, the
        // ground came out light under light words (#307).
        let excel = DarkLists.shared.fixes(for: URL(string: "https://us1-excel.officeapps.live.com/x/_layouts/xlviewerinternal.aspx")!)
        #expect(excel.invert.contains(".ewr-sheettable"))
        #expect(excel.css.contains(".ewr-sheettable {\n    background-color: #fff !important;"))
        let cloud = DarkLists.shared.fixes(for: URL(string: "https://excel.cloud.microsoft/")!)
        #expect(cloud.invert.contains(".ewr-sheettable"))
    }

    @Test func patternsMatchAsDarkReadersDo() throws {
        let plain = try #require(DarkPattern("github.com"))
        #expect(plain.matches(host: "github.com", path: "/"))
        #expect(plain.matches(host: "gist.github.com", path: "/x"))
        #expect(!plain.matches(host: "notgithub.com", path: "/"))
        #expect(!plain.matches(host: "github.com.evil.net", path: "/"))
        let wild = try #require(DarkPattern("github.*.*"))
        #expect(wild.matches(host: "github.co.uk", path: "/"))
        #expect(!wild.matches(host: "github.com", path: "/"))
        let sub = try #require(DarkPattern("*.abc.net.au"))
        #expect(sub.matches(host: "www.abc.net.au", path: "/news"))
        #expect(!sub.matches(host: "abc.net.au", path: "/"))
        let path = try #require(DarkPattern("discord.com/app"))
        #expect(path.matches(host: "discord.com", path: "/app/channels/1"))
        #expect(!path.matches(host: "discord.com", path: "/"))
        let exact = try #require(DarkPattern("^exact.org$"))
        #expect(exact.matches(host: "exact.org", path: "/"))
        #expect(!exact.matches(host: "www.exact.org", path: "/"))
        #expect(!exact.matches(host: "exact.org", path: "/page"))
        #expect(DarkPattern("") == nil)
        #expect(DarkPattern("https://scheme.dev/path/")?.labels == ["scheme", "dev"])
    }

    @MainActor @Test func theVendoredListsAreRead() throws {
        let lists = DarkLists.shared
        let counts = lists.counts
        #expect(counts.fixes > 2000)
        #expect(counts.dark > 1000)
        #expect(lists.isDark(URL(string: "https://discord.com/app")))
        #expect(!lists.isDark(URL(string: "https://discord.com/")))
        #expect(!lists.isDark(URL(string: "https://en.wikipedia.org/wiki/Moon")))
        let github = lists.fixes(for: URL(string: "https://github.com/darkreader/darkreader")!)
        #expect(github.invert.count > 5)
        #expect(github.css.contains("--darkreader") || !github.css.isEmpty)
        #expect(DarkPages.version.split(separator: ".").count == 3)
    }

    // MARK: the decision

    @Test func theDecisionGoesInOrder() {
        let now = Date()
        let fresh = DarkLearned(value: .engine, at: now.addingTimeInterval(-3600))
        let stale = DarkLearned(value: .engine, at: now.addingTimeInterval(-15 * 24 * 3600))
        let own = DarkLearned(value: .own, at: now)
        func decide(_ mode: DarkMode = .withTheme, dark: Bool = true, eligible: Bool = true, choice: String? = nil,
                    list: Bool = false, learned: DarkLearned? = nil) -> DarkDecision {
            DarkPages.decide(mode: mode, windowDark: dark, eligible: eligible, choice: choice, darkSite: list, learned: learned, now: now)
        }
        // 1. Mode and window.
        #expect(decide(.off) == .none)
        // Off is not a word over one site turned on from ⌘E in a dark window.
        #expect(decide(.off, choice: "yes") == .check)
        #expect(decide(.off, dark: false, choice: "yes") == .none)
        #expect(decide(.off, choice: "yes", list: true) == .own)
        #expect(decide(.off, choice: "off") == .none)
        #expect(decide(.withTheme, dark: false) == .none)
        #expect(decide(.always, dark: false) == .check)
        // 2. Not a page for it.
        #expect(decide(eligible: false, choice: "on") == .none)
        // 3. The person's word, never learned over.
        #expect(decide(choice: "off", list: true, learned: fresh) == .off)
        // "on", kept from before #336, never forces the engine over a
        // site's own dark theme.
        #expect(decide(choice: "on", list: true, learned: own) == .own)
        #expect(decide(choice: "on", learned: own) == .check)
        // 4. Dark Reader's list of dark sites.
        #expect(decide(list: true, learned: fresh) == .own)
        // 5. What was learned, while fresh.
        #expect(decide(learned: fresh) == .engine)
        // Dark is looked at again each time: a host's other page may be light.
        #expect(decide(learned: own) == .check)
        #expect(decide(learned: stale) == .check)
        // 6. Nothing known.
        #expect(decide() == .check)
    }

    /// #336: turned off is the engine off, never the light appearance, so
    /// a site with a dark theme of its own follows the window.
    @Test func turnedOffFollowsTheWindow() {
        #expect(DarkPages.appearance(.off, windowDark: true) == nil)
        #expect(DarkPages.appearance(.off, windowDark: false) == nil)
        #expect(DarkPages.appearance(.none, windowDark: true) == nil)
        #expect(DarkPages.appearance(.own, windowDark: true) == nil)
        #expect(DarkPages.appearance(.check, windowDark: true) == nil)
        // Always in a light window: drawn dark, so an own dark theme is used.
        #expect(DarkPages.appearance(.own, windowDark: false) == .darkAqua)
        #expect(DarkPages.appearance(.engine, windowDark: false) == .darkAqua)
    }

    @Test func framesFollowTheirTopSite() {
        #expect(DarkPages.frame(top: .engine, darkSite: false) == .check)
        #expect(DarkPages.frame(top: .on, darkSite: true) == .own)
        #expect(DarkPages.frame(top: .check, darkSite: false) == .check)
        #expect(DarkPages.frame(top: .own, darkSite: false) == .own)
        #expect(DarkPages.frame(top: .off, darkSite: false) == .off)
        #expect(!DarkDecision.off.scripted)
        #expect(!DarkDecision.none.scripted)
        #expect(DarkDecision.own.scripted)
    }

    @Test func learningAgainWhenTheSiteGrowsADarkTheme() {
        let plain = DarkLearned(value: .engine, at: Date(), sign: false)
        let signed = DarkLearned(value: .engine, at: Date(), sign: true)
        #expect(DarkPages.relearns(plain, sign: true))
        #expect(!DarkPages.relearns(plain, sign: false))
        // Seen with the sign already: not looked at again for it.
        #expect(!DarkPages.relearns(signed, sign: true))
        #expect(!DarkPages.relearns(DarkLearned(value: .own, at: Date()), sign: true))
        #expect(!DarkPages.relearns(nil, sign: true))
    }

    @Test func learnedDecisionsRoundTrip() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let learned = DarkLearned(value: .own, at: at, sign: true)
        #expect(DarkLearned(learned.plist) == learned)
        #expect(DarkLearned(["v": "check", "at": 1.0]) == nil)
        #expect(DarkLearned(["v": "engine"]) == nil)
        #expect(DarkLearned(nil) == nil)
    }

    @Test func choicesSyncAndLearningStaysOnThisMac() {
        #expect(SyncShapes.syncs("dark.northwind.news"))
        #expect(SyncShapes.syncs("pages.dark"))
        #expect(SyncShapes.syncs("pages.darkLook"))
        #expect(!SyncShapes.syncs("darkLearned.northwind.news"))
    }

    @Test func theLookIsClampedAndKept() throws {
        var look = DarkLook()
        look.brightness = 400
        look.contrast = 10
        look.warmth = -5
        let kept = look.clamped
        #expect(kept.brightness == 140 && kept.contrast == 60 && kept.warmth == 0)
        let data = try JSONEncoder().encode(kept)
        #expect(try JSONDecoder().decode(DarkLook.self, from: data) == kept)
        #expect(DarkLook().groundHex(space: nil) == DarkLook.gray)
        var black = DarkLook()
        black.ground = .black
        #expect(black.groundHex(space: nil) == "000000")
        var space = DarkLook()
        space.ground = .space
        let tinted = try #require(NSColor(hex: space.groundHex(space: NSColor(srgbRed: 0.4, green: 0.3, blue: 0.9, alpha: 1))))
        var brightness: CGFloat = 0
        tinted.usingColorSpace(.sRGB)!.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        #expect(brightness < 0.2)
        let theme = DarkLook().theme(ground: "1c1c1c")
        #expect(theme["darkSchemeBackgroundColor"] as? String == "#1c1c1c")
        #expect(theme["mode"] as? Int == 1)
        #expect(DarkLook().dimCSS.isEmpty)
    }

    // MARK: the bridge

    @Test func theBridgeKeepsToItsLimits() {
        let page = URL(string: "https://northwind.news/")
        #expect(DarkFetch.allowed(URL(string: "https://cdn.example.com/a.css")!, from: page) == nil)
        #expect(DarkFetch.allowed(URL(string: "http://cdn.example.com/a.css")!, from: page) == nil)
        #expect(DarkFetch.allowed(URL(string: "file:///etc/passwd")!, from: page) == .scheme)
        #expect(DarkFetch.allowed(URL(string: "ftp://example.com/a.css")!, from: page) == .scheme)
        // The router and this Mac, only for a page that is itself local.
        #expect(DarkFetch.allowed(URL(string: "http://192.168.1.1/admin.css")!, from: page) == .local)
        #expect(DarkFetch.allowed(URL(string: "http://localhost:3000/a.css")!, from: page) == .local)
        #expect(DarkFetch.allowed(URL(string: "http://192.168.1.1/a.css")!, from: URL(string: "http://192.168.1.20/")) == nil)
        #expect(DarkFetch.limit == 2 << 20)
        #expect(DarkFetch.timeout == 10)
        // Never with cookies.
        let configuration = DarkFetch.session.configuration
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
    }

    @Test func darkReadersOwnSitesComeOver() {
        let kept = DarkReaderStorage.parse([
            "enabledByDefault": true,
            "disabledFor": ["figma.com", "*.maps.apple.com", "https://www.photos.google.com/u/0", "*", "localhost:8080"],
            "theme": ["brightness": 110, "contrast": 95, "sepia": 20, "darkSchemeBackgroundColor": "#000000"],
        ])
        #expect(kept.lightSites == ["figma.com", "maps.apple.com", "photos.google.com"])
        #expect(kept.look?.brightness == 110)
        #expect(kept.look?.warmth == 20)
        #expect(kept.look?.ground == .black)
        // Off by default, its list is where it is on: nothing is kept light.
        #expect(DarkReaderStorage.parse(["enabledByDefault": false, "disabledFor": ["a.com"]]).lightSites.isEmpty)
    }

    // MARK: the page script, with the real engine in WebKit

    /// Answers every frame's ask with `decision` and keeps what the page
    /// says it found.
    final class Relay: NSObject, WKScriptMessageHandlerWithReply {
        let decision: String
        var done: [[String: Any]] = []
        init(_ decision: String) { self.decision = decision }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            MainActor.assumeIsolated {
                let body = message.body as? [String: Any] ?? [:]
                switch body["kind"] as? String {
                case "ask": replyHandler(["decision": decision], nil)
                case "done": done.append(body); replyHandler(true, nil)
                default: replyHandler(nil, "Not here")
                }
            }
        }
    }

    @MainActor
    private func page(_ html: String, decision: String = "check", dark: Bool = true) async throws -> (WKWebView, Relay) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let relay = Relay(decision)
        let controller = configuration.userContentController
        controller.addScriptMessageHandler(relay, contentWorld: DarkPages.world, name: DarkRelay.name)
        // The page is not on screen: the engine is told to restyle at once
        // rather than wait for it to be seen.
        var theme = DarkLook().theme(ground: DarkLook.gray)
        theme["immediateModify"] = true
        let start = WKUserScript(source: PageScript.load("dark-pages", vars: [
            "THEME": DarkPages.json(theme), "FALLBACK": DarkPages.json(DarkLook.fallback(ground: DarkLook.gray)), "DIM": "\"\"", "DEFER": "false", "OWN_SITES": DarkPages.ownSites,
        ]), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: DarkPages.world)
        for script in [DarkPages.proxy, DarkPages.engine, start] { controller.addUserScript(script) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        web.loadHTMLString(html, baseURL: URL(string: "https://page.example.test/"))
        return (web, relay)
    }

    @MainActor
    private func state(_ web: WKWebView, until wanted: Set<String>, seconds: Double = 8) async throws -> String {
        let end = Date().addingTimeInterval(seconds)
        var last = ""
        while Date() < end {
            last = (try? await web.evaluateJavaScript("window.__yabDark ? window.__yabDark.state() : 'none'", in: nil, contentWorld: DarkPages.world) as? String) ?? "none"
            if wanted.contains(last) { return last }
            try await Task.sleep(for: .milliseconds(50))
        }
        return last
    }

    @MainActor
    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.evaluateJavaScript(script, in: nil, contentWorld: .page)
    }

    /// 0 black to 1 white, of an element's computed background.
    private static let groundJS = """
    (sel => { const c = getComputedStyle(document.querySelector(sel)).backgroundColor.match(/[\\d.]+/g).map(Number);
      return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255; })
    """

    @MainActor @Test func aLightPageIsDarkenedAndItsPicturesAreNot() async throws {
        let (web, relay) = try await page("""
        <!doctype html><style>body{background:#fff;color:#111;margin:0} .card{background:#f4f4f4;padding:20px}</style>
        <body><div class="card">Words <a href="#">a link</a></div>
        <img id="photo" width="40" height="40" src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect width='40' height='40' fill='%23f0c060'/></svg>">
        </body>
        """)
        #expect(try await state(web, until: ["engine", "own"]) == "engine")
        try await Task.sleep(for: .milliseconds(400))
        let body = try #require(try await js(web, Self.groundJS + "('body')") as? Double)
        let card = try #require(try await js(web, Self.groundJS + "('.card')") as? Double)
        #expect(body < 0.2, "the light page's ground is dark: \(body)")
        #expect(card < 0.25, "and its cards: \(card)")
        let mode = try await js(web, "document.documentElement.getAttribute('data-darkreader-mode')") as? String
        #expect(mode == "dynamic")
        let filter = try await js(web, "getComputedStyle(document.getElementById('photo')).filter") as? String
        #expect(filter == "none", "a picture is never inverted")
        // The fallback has gone once the engine has its own.
        let fallback = try await js(web, "document.querySelectorAll('.yab-dark-fallback').length") as? Int
        #expect(fallback == 0)
        _ = relay
    }

    @MainActor @Test func aDarkSiteIsLeftAlone() async throws {
        let (web, _) = try await page("""
        <!doctype html><style>body{background:#0d1117;color:#e6edf3}</style><body><p>Already dark</p></body>
        """)
        #expect(try await state(web, until: ["engine", "own"]) == "own")
        let mode = try await js(web, "document.documentElement.getAttribute('data-darkreader-mode') || 'none'") as? String
        #expect(mode == "none")
        let color = try await js(web, "getComputedStyle(document.body).backgroundColor") as? String
        #expect(color == "rgb(13, 17, 23)", "its own ground, untouched")
        let fallback = try await js(web, "document.querySelectorAll('.yab-dark-fallback').length") as? Int
        #expect(fallback == 0)
    }

    @MainActor @Test func aSiteWithItsOwnDarkThemeUsesIt() async throws {
        let html = """
        <!doctype html><meta name="color-scheme" content="light dark">
        <style>body{background:#fff;color:#000} @media (prefers-color-scheme: dark){body{background:#121212;color:#eee}}</style>
        <body><p>Both</p></body>
        """
        let (dark, _) = try await page(html, dark: true)
        #expect(try await state(dark, until: ["engine", "own"]) == "own")
        // The same site asked for its light look: the engine darkens it.
        let (light, _) = try await page(html, dark: false)
        #expect(try await state(light, until: ["engine", "own"]) == "engine")
    }

    /// #336: a site whose dark theme a script puts on after the document is
    /// parsed is found on the second look, once the page has loaded, and the
    /// engine comes off.
    @MainActor @Test func aDarkThemePutOnByScriptLaterIsTheSitesOwn() async throws {
        let (web, relay) = try await page("""
        <!doctype html><style>body{background:#fff;color:#000} html.dark body{background:#0f0f10;color:#eee}</style>
        <body><p>Late</p><script>document.addEventListener('DOMContentLoaded', () => {
          if (matchMedia('(prefers-color-scheme: dark)').matches) document.documentElement.classList.add('dark') })</script></body>
        """)
        #expect(try await state(web, until: ["own"]) == "own")
        let mode = try await js(web, "document.documentElement.getAttribute('data-darkreader-mode') || 'none'") as? String
        #expect(mode == "none")
        let color = try await js(web, "getComputedStyle(document.body).backgroundColor") as? String
        #expect(color == "rgb(15, 15, 16)", "its own dark ground")
        #expect(relay.done.last?["result"] as? String == "own")
    }

    /// A site learned light that has grown a dark theme of its own is left to
    /// it once loaded, not darkened over (#336).
    @MainActor @Test func aLearnedLightSiteWithItsOwnDarkNowUsesIt() async throws {
        let (web, _) = try await page("""
        <!doctype html><style>body{background:#fff;color:#000} @media (prefers-color-scheme: dark){body{background:#121212;color:#eee}}</style>
        <body><p>Grown</p></body>
        """, decision: "engine")
        #expect(try await state(web, until: ["own"]) == "own")
        let color = try await js(web, "getComputedStyle(document.body).backgroundColor") as? String
        #expect(color == "rgb(18, 18, 18)")
    }

    /// A light page with a dark rule for its header only stays darkened.
    @MainActor @Test func aLightPageWithSomeDarkRulesKeepsTheEngine() async throws {
        let (web, _) = try await page("""
        <!doctype html><style>body{background:#fff;color:#000} @media (prefers-color-scheme: dark){header{background:#111}}</style>
        <body><header>Head</header><p>Light</p></body>
        """, decision: "engine")
        #expect(try await state(web, until: ["engine"]) == "engine")
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await state(web, until: ["engine"]) == "engine")
    }

    /// #616: the engine's constructed stylesheet must be off for the late
    /// look, just like its <style> overrides. Otherwise it sees its own dark
    /// background, reports "own", and removes the engine from a light page.
    @MainActor @Test(arguments: ["check", "engine"])
    func constructedStylesStayDarkAfterLoad(decision: String) async throws {
        let (web, relay) = try await page("""
        <!doctype html><style>@media(prefers-color-scheme:dark){header{background:#111}}</style>
        <body><header>Head</header><p>Constructed light theme</p><script>
        const sheet = new CSSStyleSheet();
        sheet.replaceSync('body { background: #fff; color: #111; }');
        document.adoptedStyleSheets = [sheet];
        </script></body>
        """, decision: decision)
        #expect(try await state(web, until: ["engine"]) == "engine")
        // The second look is after load and two frames (150 ms when hidden).
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await state(web, until: ["engine", "own"]) == "engine")
        let body = try #require(try await js(web, Self.groundJS + "('body')") as? Double)
        #expect(body < 0.2, "the constructed light theme stays dark after load: \(body)")
        #expect(relay.done.last?["result"] as? String == "engine")
        // Both the source and its generated override are restored, not
        // removed or left disabled by detection.
        let disabled = try await js(web, "document.adoptedStyleSheets.filter(s => s.disabled).length") as? Int
        #expect(disabled == 0)
        let source = try await js(web, "document.adoptedStyleSheets[0].cssRules[0].style.backgroundColor") as? String
        #expect(source == "rgb(255, 255, 255)")
    }

    @MainActor @Test func aConstructedDarkThemeRemainsTheSitesOwn() async throws {
        let (web, _) = try await page("""
        <!doctype html><body>Own constructed dark theme<script>
        const sheet = new CSSStyleSheet();
        sheet.replaceSync('body { background: #101418; color: #ddd; }');
        document.adoptedStyleSheets = [sheet];
        </script></body>
        """)
        #expect(try await state(web, until: ["engine", "own"]) == "own")
        let color = try await js(web, "getComputedStyle(document.body).backgroundColor") as? String
        #expect(color == "rgb(16, 20, 24)")
        let count = try await js(web, "document.adoptedStyleSheets.length") as? Int
        #expect(count == 1)
    }

    @MainActor @Test func aCanvasDarkOnlyByColorSchemeCountsAsDark() async throws {
        let (web, _) = try await page("""
        <!doctype html><meta name="color-scheme" content="dark"><body><p>The canvas is dark</p></body>
        """)
        #expect(try await state(web, until: ["engine", "own"]) == "own")
    }

    @MainActor @Test func aDarkWrapperRoundEverythingCountsAsDark() async throws {
        let (web, _) = try await page("""
        <!doctype html><body style="margin:0"><div style="position:fixed;inset:0;background:#101418;color:#ddd">App</div></body>
        """)
        #expect(try await state(web, until: ["engine", "own"]) == "own")
    }

    @MainActor @Test func aSiteThatAsksNotToBeDarkenedIsNot() async throws {
        let (web, relay) = try await page("""
        <!doctype html><meta name="darkreader-lock"><style>body{background:#fff}</style><body>Mine</body>
        """, decision: "engine")
        #expect(try await state(web, until: ["engine", "own", "off"]) != "engine")
        let color = try await js(web, "getComputedStyle(document.body).backgroundColor") as? String
        #expect(color == "rgb(255, 255, 255)")
        _ = relay
    }

    @MainActor @Test func stylesAddedLaterByScriptAreDarkenedThroughTheProxy() async throws {
        let (web, _) = try await page("""
        <!doctype html><meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <style id="late"></style><body style="background:#fff"><div class="late">CSS in JS</div></body>
        """)
        #expect(try await state(web, until: ["engine", "own"]) == "engine")
        // The page's own script, as a CSS-in-JS library does: a rule put in
        // with insertRule, which no MutationObserver sees.
        _ = try await js(web, "document.getElementById('late').sheet.insertRule('.late { background: rgb(250, 250, 250); color: rgb(20, 20, 20); }'); 1")
        var ground = 1.0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            ground = (try await js(web, Self.groundJS + "('.late')") as? Double) ?? 1
            if ground < 0.3 { break }
        }
        #expect(ground < 0.3, "the rule a script put in later is darkened: \(ground)")
    }

    @MainActor @Test func yabTurnsAPageOffAndOnWithoutAReload() async throws {
        let (web, _) = try await page("<!doctype html><style>body{background:#fff;color:#111}</style><body>Toggle</body>")
        #expect(try await state(web, until: ["engine"]) == "engine")
        _ = try await web.evaluateJavaScript("window.__yabDark.apply('off')", in: nil, contentWorld: DarkPages.world)
        #expect(try await state(web, until: ["off"]) == "off")
        let light = try await js(web, Self.groundJS + "('body')") as? Double
        #expect((light ?? 0) > 0.9)
        _ = try await web.evaluateJavaScript("window.__yabDark.apply('engine')", in: nil, contentWorld: DarkPages.world)
        #expect(try await state(web, until: ["engine"]) == "engine")
        // Printing: off for the sheet, back after.
        let was = try await web.evaluateJavaScript("window.__yabDark.print(true)", in: nil, contentWorld: DarkPages.world) as? Bool
        #expect(was == true)
        #expect(try await state(web, until: ["engine", "off"]) != "engine")
        _ = try await web.evaluateJavaScript("window.__yabDark.print(false)", in: nil, contentWorld: DarkPages.world)
        #expect(try await state(web, until: ["engine"]) == "engine")
    }

    /// Icons each carrying the same <style> get one override after the last
    /// of them, colored as each copy's own would have been, and it moves
    /// when that copy goes.
    @MainActor @Test func identicalStylesShareOneOverrideAfterTheLast() async throws {
        let icon = "<svg width=20 height=20><defs><style>.tw{fill:#e17055}</style></defs><rect class=tw width=20 height=20/></svg>"
        let (web, _) = try await page("""
        <!doctype html><style>body{background:#fff;color:#111}</style><body>
        <p id=icons>\(String(repeating: icon, count: 12))</p>
        <svg width=20 height=20><defs><style>.ref{fill:#e17055}</style></defs><rect id=ref class=ref width=20 height=20/></svg>
        </body>
        """)
        #expect(try await state(web, until: ["engine"]) == "engine")
        let look = """
        (() => { const syncs = [...document.querySelectorAll('#icons style.darkreader--sync')];
          const own = [...document.querySelectorAll('#icons style:not(.darkreader)')];
          const fills = new Set([...document.querySelectorAll('#icons rect')].map(r => getComputedStyle(r).fill));
          return [syncs.length, syncs.length === 1 && syncs[0].previousElementSibling === own[own.length - 1],
                  [...fills].join('|'), getComputedStyle(document.getElementById('ref')).fill].join(';'); })()
        """
        var seen = ""
        for _ in 0..<40 {
            seen = try await js(web, look) as? String ?? ""
            if seen.hasPrefix("1;true;") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let parts = seen.components(separatedBy: ";")
        #expect(parts.count == 4 && parts[0] == "1" && parts[1] == "true", "one override, after the last copy: \(seen)")
        #expect(parts.count == 4 && parts[2] == parts[3] && parts[2] != "rgb(225, 112, 85)", "each icon darkened as its own copy would be: \(seen)")
        // The copy holding the override goes: the one before it takes it over.
        _ = try await js(web, "document.querySelector('#icons svg:last-of-type').remove(); 1")
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            seen = try await js(web, look) as? String ?? ""
            if seen.hasPrefix("1;true;") { break }
        }
        let after = seen.components(separatedBy: ";")
        #expect(after.count == 4 && after[0] == "1" && after[1] == "true" && after[2] == after[3], "moved to the new last copy: \(seen)")
    }

    /// A list drawn anew sixty times in one task, as jQuery's TodoMVC does:
    /// the style taken out of the head on the way leaves no override, the
    /// one that came with the last drawing is darkened.
    @MainActor @Test func aListDrawnAnewLetsGoOfTheStylesTakenOut() async throws {
        let (web, _) = try await page("""
        <!doctype html><style>body{background:#fff;color:#111}</style><style id=gone>.gone{background:#ffd6d6}</style>
        <body><p class=gone>Gone</p><ul id=list></ul><p class=warm id=warm>Warm</p></body>
        """)
        #expect(try await state(web, until: ["engine"]) == "engine")
        let overridesOfGone = "[...document.querySelectorAll('style.darkreader--sync')].filter(s => [...s.sheet.cssRules].some(r => r.selectorText === '.gone')).length"
        for _ in 0..<40 {
            if (try await js(web, overridesOfGone) as? Int) == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await js(web, overridesOfGone) as? Int == 1)
        _ = try await js(web, """
        for (let r = 1; r <= 60; r++) {
          let html = '';
          for (let i = 1; i <= 60; i++) html += '<li>Item ' + i + '</li>';
          if (r === 60) html += '<li><style>.warm{background:#c3f0c8}</style>warm</li>';
          list.innerHTML = html;
          if (r === 40) document.getElementById('gone').remove();
        }
        1
        """)
        var gone = -1, warm = ""
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            gone = try await js(web, overridesOfGone) as? Int ?? -1
            warm = try await js(web, "getComputedStyle(document.getElementById('warm')).backgroundColor") as? String ?? ""
            if gone == 0 && !["", "rgba(0, 0, 0, 0)", "rgb(195, 240, 200)"].contains(warm) { break }
        }
        #expect(gone == 0, "the override of the style taken out went with it")
        #expect(!["", "rgba(0, 0, 0, 0)", "rgb(195, 240, 200)"].contains(warm), "the style drawn in last is darkened: \(warm)")
    }

    @MainActor @Test func thePageNeverSeesTheEngineOrTheBridge() async throws {
        let (web, _) = try await page("<!doctype html><body style='background:#fff'>Private</body>")
        #expect(try await state(web, until: ["engine"]) == "engine")
        let seen = try await js(web, "[typeof window.DarkReader, typeof window.__yabDark, typeof window.__yabDarkEngine, typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yabDark), typeof window.chrome].join(',')") as? String
        #expect(seen == "undefined,undefined,undefined,undefined,undefined")
    }
}

@MainActor
@Suite struct DarkPagesSiteSwitchTests {
    /// ⌘E in a dark window with the mode Off: the site's switch is there, and
    /// turning it on then off leaves no word behind.
    @Test func offModeKeepsTheSitesSwitch() {
        #expect(DarkPages.active(windowDark: true, mode: .off))
        #expect(!DarkPages.active(windowDark: false, mode: .off))
        #expect(DarkPages.active(windowDark: false, mode: .always))
        let host = "switch-test.example"
        defer { Store.settings.removeObject(forKey: DarkPages.choiceKey(host)) }
        DarkPages.toggle(host, darkNow: false, mode: .off)
        #expect(DarkPages.choice(host) == "yes")
        DarkPages.toggle(host, darkNow: true, mode: .off)
        #expect(DarkPages.choice(host) == nil)
        DarkPages.toggle(host, darkNow: true, mode: .withTheme)
        #expect(DarkPages.choice(host) == "off")
        DarkPages.toggle(host, darkNow: false, mode: .withTheme)
        #expect(DarkPages.choice(host) == nil)
    }

    /// #743: ChatGPT and its sandboxed answers are left to their own theme.
    private static let chatGPTURLs = [
        "https://chatgpt.com/", "https://www.chatgpt.com/c/test?model=auto",
        "https://CHATGPT.COM:8443/c/test", "https://sub.chatgpt.com/",
        "https://chat.openai.com/chat", "https://www.chat.openai.com/",
        "https://oaiusercontent.com/", "https://files.oaiusercontent.com/file/test",
        "https://web-sandbox.oaiusercontent.com/", "https://answer.web-sandbox.oaiusercontent.com/",
    ]

    private static let otherURLs = [
        "https://notchatgpt.com/", "https://chatgpt.com.example.test/",
        "https://evilchat.openai.com/", "https://chat.openai.com.example.test/",
        "https://notoaiusercontent.com/", "https://oaiusercontent.com.example.test/",
        "https://openai.com/", "https://api.openai.com/",
    ]

    @Test func chatGPTIsItsOwnDarkWithoutVendoredRules() throws {
        let lists = DarkLists()
        lists.use(fixes: "", dark: "")
        let now = Date()
        let learned = DarkLearned(value: .engine, at: now)
        for text in Self.chatGPTURLs {
            let url = try #require(URL(string: text))
            #expect(lists.isDark(url))
            #expect(DarkLists.shared.isDark(url))
            #expect(DarkPages.decide(mode: .withTheme, windowDark: true, eligible: true, choice: nil,
                                     darkSite: lists.isDark(url), learned: learned, now: now) == .own)
            for mode in [DarkMode.withTheme, .always, .off] {
                let decision = DarkPages.decide(mode: mode, windowDark: true, eligible: true, choice: "yes",
                                                darkSite: lists.isDark(url), learned: learned, now: now)
                #expect(decision == .own)
                let answer = DarkPages.answer(top: decision, url: url, isMain: true)
                #expect(answer["decision"] as? String == "own")
                #expect(answer["fixes"] == nil)
            }
            #expect(DarkPages.decide(mode: .always, windowDark: false, eligible: true, choice: "on",
                                     darkSite: lists.isDark(url), learned: learned, now: now) == .own)
            #expect(DarkPages.decide(mode: .withTheme, windowDark: true, eligible: true, choice: "off",
                                     darkSite: lists.isDark(url), learned: learned, now: now) == .off)
            for top in [DarkDecision.engine, .on, .check, .own] {
                let answer = DarkPages.answer(top: top, url: url, isMain: false)
                #expect(answer["decision"] as? String == "own")
                #expect(answer["fixes"] == nil)
            }
            #expect(DarkPages.answer(top: .off, url: url, isMain: false)["decision"] as? String == "off")
        }
    }

    @Test func chatGPTRulesDoNotIncludeOtherHosts() throws {
        let lists = DarkLists()
        lists.use(fixes: "", dark: "")
        for text in Self.otherURLs {
            let url = try #require(URL(string: text))
            #expect(!lists.isDark(url))
        }
    }

    private func startPage(_ url: URL, main: Bool, ancestors: [String] = []) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("var location = \(DarkPages.json(["protocol": url.scheme! + ":", "hostname": url.host() ?? "", "href": url.absoluteString]));")
        var originHosts: [String: String] = [:]
        for origin in ancestors { originHosts[origin] = URL(string: origin)?.host() }
        context.evaluateScript("location.ancestorOrigins = \(DarkPages.json(ancestors)); var originHosts = \(DarkPages.json(originHosts));")
        context.evaluateScript("var isMain = \(main ? "true" : "false");")
        context.evaluateScript(#"""
        var window = this;
        window.top = isMain ? window : {};
        // JavaScriptCore has no browser URL constructor. Foundation supplies
        // the parsed hosts for the ancestor origins in this fixture.
        function URL(text) {
          if (!(text in originHosts)) throw Error('Invalid origin');
          this.hostname = originHosts[text];
        }
        var createdStyles = 0, placedStyles = 0, engineCalls = 0, pendingAnswer;
        var document = {
          contentType: 'text/html',
          documentElement: {},
          head: { appendChild() { placedStyles++; } },
          createElement() { createdStyles++; return { remove() {} }; },
        };
        window.__yabDarkEngine = () => { engineCalls++; throw Error('Unexpected engine'); };
        window.webkit = { messageHandlers: { yabDark: {
          postMessage(body) {
            if (body.kind === 'ask') return { then(reply) { pendingAnswer = reply; } };
            return { catch() {} };
          },
        } } };
        """#)
        var look = DarkLook()
        look.dimPictures = true
        context.evaluateScript(DarkPages.startScript(look, ground: DarkLook.gray).source)
        try #require(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return context
    }

    @Test func chatGPTGetsNoFallbackBeforeTheBridgeAnswers() throws {
        for text in Self.chatGPTURLs {
            for main in [true, false] {
                let context = try startPage(try #require(URL(string: text)), main: main)
                #expect(context.evaluateScript("typeof pendingAnswer")?.toString() == "function")
                #expect(context.evaluateScript("createdStyles")?.toInt32() == 0)
                #expect(context.evaluateScript("placedStyles")?.toInt32() == 0)
                context.evaluateScript("pendingAnswer({decision: 'own'}); window.__yabDark.look({}, '', 'img { filter: brightness(.5); }');")
                context.evaluateScript("window.__yabDark.apply('engine'); window.__yabDark.apply('on'); window.__yabDark.apply('check');")
                #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
                #expect(context.evaluateScript("window.__yabDark.state()")?.toString() == "own")
                #expect(context.evaluateScript("createdStyles")?.toInt32() == 0)
                #expect(context.evaluateScript("engineCalls")?.toInt32() == 0)
            }
        }
    }

    @Test func otherSitesStillGetTheirFirstPaintFallback() throws {
        for text in Self.otherURLs + ["about:blank", "about:srcdoc"] {
            let context = try startPage(try #require(URL(string: text)), main: false,
                                        ancestors: ["null", "https://notchatgpt.com"])
            #expect(context.evaluateScript("createdStyles")?.toInt32() == 1)
            #expect(context.evaluateScript("placedStyles")?.toInt32() == 1)
        }
    }

    @Test func chatGPTChildDocumentsKeepTheirOwnTheme() throws {
        for text in ["about:blank", "about:srcdoc", "https://embedded.example.test/"] {
            for origin in ["https://chatgpt.com", "https://chat.openai.com", "https://answer.web-sandbox.oaiusercontent.com"] {
                let context = try startPage(try #require(URL(string: text)), main: false,
                                            ancestors: ["null", origin, "https://other.example.test"])
                #expect(context.evaluateScript("createdStyles")?.toInt32() == 0)
                context.evaluateScript("pendingAnswer({decision: 'check'}); window.__yabDark.apply('engine'); window.__yabDark.print(false);")
                #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
                #expect(context.evaluateScript("window.__yabDark.state()")?.toString() == "own")
                #expect(context.evaluateScript("createdStyles")?.toInt32() == 0)
                #expect(context.evaluateScript("engineCalls")?.toInt32() == 0)
                context.evaluateScript("window.__yabDark.apply('off');")
                #expect(context.evaluateScript("window.__yabDark.state()")?.toString() == "off")
            }
        }
    }
}
