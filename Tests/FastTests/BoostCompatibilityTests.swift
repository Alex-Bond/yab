import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// A frozen Store snapshot, exercised by the real parser and isolated WebKit
/// wrapper. HTTP responses are fixtures; no live accounts or public sites.
@MainActor @Suite(.serialized)
struct BoostCompatibilityTests {
    private struct Snapshot: Decodable {
        let commit: String
        let packages: [Package]
    }
    private struct Package: Decodable {
        let id: String
        let sites: [String]
        let preview: String
        let files: [String: String]
    }
    private func snapshot() throws -> Snapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/boost-store-1092.json")
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    @Test func storePackagesAndShippedRecipesRemainValid() throws {
        let store = try snapshot()
        #expect(store.commit == "605a7bc29dffce9194d5e97752719ff5fd1faaa8")
        #expect(store.packages.count == 52)
        for entry in store.packages {
            let package = try BoostPackage.read(id: entry.id, files: entry.files, sites: entry.sites)
            #expect(package.name.isEmpty == false, "\(entry.id)")
        }
        #expect(BoostCatalog.entries.count == 20)
        for entry in BoostCatalog.entries {
            let package = try BoostPackage.read(id: entry.id, files: entry.files, sites: [entry.site])
            #expect(package.rung == .look, "\(entry.id)")
            #expect(!BoostScript.source(package).contains("Use fetch for boost network requests."))
        }
    }

    private struct Scenario {
        let url: String
        let html: String
        let expectJS: String
        var setupJS = ""
    }
    private func scenario(_ id: String, preview: String) -> Scenario {
        switch id {
        case "absolute-dates":
            return .init(url: "https://www.reddit.com/", html: "<faceplate-timeago ts='2026-01-02T12:00:00Z'></faceplate-timeago>", expectJS: "!!document.querySelector('.yab-abs-date')")
        case "feed-pause":
            return .init(url: "https://x.com/home", html: "<main></main>", expectJS: "!!document.querySelector('.yab-feed-pause')")
        case "google-domain-blocklist":
            return .init(url: "https://www.google.com/search?q=fixture", html: "<main id='main'><div id='rso'><div class='g'><a href='https://example.org/'><h3>Result</h3></a></div></div></main>", expectJS: "!!document.querySelector('.yab-block-pill')")
        case "hn-side-by-side":
            return .init(url: "https://news.ycombinator.com/item?id=1", html: "<span class='pagetop'></span><table class='fatitem'><tr class='athing submission'><td><span class='titleline'><a href='https://example.org/'>Story</a></span></td></tr></table><table class='comment-tree'></table>", expectJS: "!!document.querySelector('.yab-hn-article') && !!document.querySelector('.yab-hn-later-link')")
        case "x-reply-filter":
            return .init(url: "https://x.com/author/status/1", html: "<main role='main'><div data-testid='cellInnerDiv'><article data-testid='tweet'><div data-testid='User-Name'><a href='/author'>@author</a></div></article></div><div data-testid='cellInnerDiv'><article data-testid='tweet'><div data-testid='User-Name'><a href='/spam12345'>@spam12345</a></div></article></div></main>", expectJS: "!!document.querySelector('[data-yab-replies=folded]')")
        case "youtube-dislikes":
            return .init(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", html: "<ytd-watch-metadata><dislike-button-view-model><button></button></dislike-button-view-model></ytd-watch-metadata>", expectJS: "document.querySelector('.yab-dislikes')?.textContent === '123' && sent.length === 1 && sent[0].url.startsWith('https://returnyoutubedislikeapi.com/') && sent[0].credentials === 'omit' && sent[0].redirect === 'error'")
        case "youtube-sponsor-skip":
            return .init(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", html: "<div id='movie_player'><video></video></div>", expectJS: "document.querySelector('#movie_player').dataset.yabSponsorSegments === '1' && sent.length === 1 && sent[0].url.startsWith('https://sponsor.ajay.app/') && !sent[0].url.includes('jNQXAC9IVRw') && sent[0].credentials === 'omit'")
        case "x-open-following":
            return .init(url: "https://x.com/home", html: "<div role='tablist'><a role='tab' href='/home' aria-selected='true'>For you</a><a role='tab' href='/home' aria-selected='false'>Following</a></div>", expectJS: "document.querySelector('[aria-selected=true]').textContent === 'Following'", setupJS: "document.querySelectorAll('[role=tab]').forEach(tab=>tab.addEventListener('click',e=>{e.preventDefault();document.querySelectorAll('[role=tab]').forEach(t=>t.setAttribute('aria-selected',String(t===tab)));}));")
        case "youtube-no-autoplay":
            return .init(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", html: "<div id='movie_player'><button><div class='ytp-autonav-toggle-button' aria-checked='true'></div></button><button class='ytp-autonav-endscreen-upnext-cancel-button'>Cancel</button></div>", expectJS: "document.querySelector('.ytp-autonav-toggle-button').getAttribute('aria-checked') === 'false' && document.body.dataset.cancelled === 'yes'", setupJS: "document.querySelector('#movie_player button').addEventListener('click',()=>document.querySelector('.ytp-autonav-toggle-button').setAttribute('aria-checked','false'));document.querySelector('.ytp-autonav-endscreen-upnext-cancel-button').addEventListener('click',()=>{document.body.dataset.cancelled='yes';});")
        case "youtube-player-defaults":
            return .init(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", html: "<ytd-watch-flexy><div id='movie_player'><video></video><button class='ytp-size-button'></button><button class='ytp-settings-button'></button><div class='ytp-settings-menu' style='display:none'></div></div></ytd-watch-flexy><ytd-popup-container><yt-confirm-dialog-renderer>Continue watching?<div id='confirm-button'><button>Yes</button></div></yt-confirm-dialog-renderer></ytd-popup-container>", expectJS: "document.querySelector('ytd-watch-flexy').hasAttribute('theater') && document.body.dataset.quality === '1080' && document.body.dataset.continued === 'yes'", setupJS: Self.playerSetup)
        default:
            return .init(url: preview, html: "<main>Fixture</main>", expectJS: "true")
        }
    }

    private static let playerSetup = #"""
    document.querySelector('.ytp-size-button').addEventListener('click',()=>document.querySelector('ytd-watch-flexy').setAttribute('theater',''));
    document.querySelector('#confirm-button button').addEventListener('click',()=>{document.body.dataset.continued='yes';});
    const menu=document.querySelector('.ytp-settings-menu');
    document.querySelector('.ytp-settings-button').addEventListener('click',()=>{
      menu.style.display=menu.style.display==='none'?'block':'none';
      menu.innerHTML='<div class="ytp-menuitem"><div class="ytp-menuitem-content">Auto (720p)</div></div>';
      menu.firstChild.addEventListener('click',()=>{
        menu.innerHTML='<div class="ytp-menuitem">720p</div><div class="ytp-menuitem">1080p</div>';
        menu.querySelectorAll('.ytp-menuitem').forEach(item=>item.addEventListener('click',()=>{
          document.body.dataset.quality=item.textContent.startsWith('1080')?'1080':'720'; menu.style.display='none';
        }));
      });
    });
    """#

    private func run(_ package: BoostPackage, scenario: Scenario) async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        defer { web.stopLoading() }
        web.loadHTMLString("<!doctype html><head></head><body><div id='boost-compat-fixture'></div>\(scenario.html)</body>", baseURL: URL(string: scenario.url))
        var ready = false
        for _ in 0..<150 {
            ready = (try? await BoostJavaScript.evaluate("document.readyState === 'complete' && !!document.querySelector('#boost-compat-fixture')", on: web)) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready, "\(package.id): fixture did not load")
        if !scenario.setupJS.isEmpty { _ = try await BoostJavaScript.evaluate(scenario.setupJS, on: web) }
        let world = WKContentWorld.world(name: "store-compat-" + UUID().uuidString)
        // Capture asynchronous failures as well as source()'s synchronous ones.
        // Supply HTTP data only, leaving the full production subsystem intact.
        _ = try await BoostJavaScript.evaluate(#"""
        window.sent=[]; window.asyncErrors=[];
        addEventListener('error',e=>{ asyncErrors.push(String(e.error || e.message)); e.preventDefault(); });
        addEventListener('unhandledrejection',e=>{ asyncErrors.push(String(e.reason)); e.preventDefault(); });
        window.fetch=(url,options)=>{
          sent.push({url:String(url),...options});
          const data=String(url).includes('sponsor.ajay.app') ? [{videoID:'jNQXAC9IVRw',segments:[{actionType:'skip',category:'sponsor',segment:[10,20],UUID:'fixture'}]}] : {dislikes:123,likes:456};
          return Promise.resolve(new Response(JSON.stringify(data),{status:200}));
        }; true;
        """#, on: web, world: world)
        if package.id == "youtube-player-defaults" {
            // Media readiness is a fixture in the boost world: page-world JS
            // expandos do not cross WebKit content worlds.
            _ = try await BoostJavaScript.evaluate("const video=document.querySelector('video'); Object.defineProperty(video,'readyState',{get:()=>4}); video.play=()=>Promise.resolve(); true;", on: web, world: world)
        }
        let report = try #require(try await BoostJavaScript.evaluate(BoostScript.source(package), on: web, world: world) as? [String: Any])
        #expect(report["loaded"] as? Bool == true, "\(package.id): \(report)")
        // Run real timers and async fetch callbacks, not just initial injection.
        try await Task.sleep(for: .milliseconds(2300))
        let errors = (report["errors"] as? [String] ?? []) + (try await BoostJavaScript.evaluate("asyncErrors", on: web, world: world) as? [String] ?? [])
        #expect(errors.isEmpty, "\(package.id): \(errors)")
        #expect(try await BoostJavaScript.evaluate(scenario.expectJS, on: web, world: world) as? Bool == true, "\(package.id): \(scenario.expectJS)")
        _ = try await BoostJavaScript.evaluate(BoostScript.remove, on: web, world: world)
        #expect(try await BoostJavaScript.evaluate("document.querySelectorAll('style[data-yab-boost]').length === 0", on: web, world: world) as? Bool == true, "\(package.id): undo")
        print("BOOST_COMPAT \(package.id) PASS")
    }

    @Test func storeContentRunsWithoutBreakages() async throws {
        for entry in try snapshot().packages {
            let package = try BoostPackage.read(id: entry.id, files: entry.files, sites: entry.sites)
            guard !package.content.isEmpty else {
                // No injected content to regress: these four packages use the
                // separate tool/service/app runtimes, not BoostNetwork.
                print("BOOST_STORE \(entry.id) VALID_SEPARATE_RUNTIME")
                continue
            }
            try await run(package, scenario: scenario(entry.id, preview: entry.preview))
        }
    }

    @Test func shippedCSSRecipesRunAndUndo() async throws {
        for entry in BoostCatalog.entries {
            let package = try BoostPackage.read(id: entry.id, files: entry.files, sites: [entry.site])
            try await run(package, scenario: .init(url: entry.url.absoluteString, html: "<main>Fixture</main>", expectJS: "document.querySelector('style[data-yab-boost]').sheet.cssRules.length > 0"))
        }
    }
}
