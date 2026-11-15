import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Actual WebKit pages from two owned loopback origins. A user's page never
/// supplies the engine or test reports, and the suite keeps no WKFrameInfo.
@MainActor
final class WebsiteDarkeningTests: XCTestCase {
    private var site: BasicsSite!
    private var other: BasicsSite!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var pages: WebPool!
    private var tabs: [YabPhone.Tab] = []
    private var previousSetting = false
    private let reports = ColorReports()

    override func setUp() async throws {
        previousSetting = SettingsStore.shared.darkenWebsites
        SettingsStore.shared.darkenWebsites = false
        site = try BasicsSite(); other = try BasicsSite()
        for server in [site!, other!] {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                server.start { done.resume(with: $0) }
            }
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        pages = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        XCTAssertTrue(WebsiteDarkening.resourcesAvailable, "The app must bundle the Mac's Dark Reader and its CSP-safe proxy")
    }

    override func tearDown() async throws {
        tabs.forEach { pages?.forget($0.id) }
        pages = nil; tabs = []
        window?.rootViewController = nil; window?.isHidden = true; window = nil
        previousKey?.makeKey()
        site?.stop(); other?.stop(); site = nil; other = nil
        SettingsStore.shared.darkenWebsites = previousSetting
        reports.values = [:]
    }

    func testToggleUpdatesCurrentCrossOriginFramesAndFutureDocuments() async throws {
        window.overrideUserInterfaceStyle = .dark
        let view = try await ready("/links")
        let parent = site.url("/links").absoluteString
        let lightChild = other.url("/links?child=light").absoluteString
        let darkChild = other.url("/dark?child=native").absoluteString
        try await addReports(to: view)
        _ = try await view.callAsyncJavaScript("""
            for (const url of urls) {
              const frame = document.createElement('iframe');
              frame.src = url; frame.style.cssText = 'width:200px;height:160px';
              document.body.append(frame);
            }
            return true;
            """, arguments: ["urls": [lightChild, darkChild]], in: nil, in: .page)
        try await until { self.reports.values[parent]?.engine == false && self.reports.values[lightChild]?.engine == false && self.reports.values[darkChild]?.engine == false }
        XCTAssertEqual(reports.values[darkChild]?.background, "rgb(16, 16, 18)")

        SettingsStore.shared.darkenWebsites = true
        try await until { self.reports.values[parent]?.darkened == true && self.reports.values[lightChild]?.darkened == true }
        XCTAssertEqual(reports.values[darkChild]?.engine, false, "A native dark iframe keeps its own look")
        XCTAssertEqual(reports.values[darkChild]?.background, "rgb(16, 16, 18)")
        let pageEngine = try await view.evaluateJavaScript("typeof window.DarkReader") as? String
        XCTAssertEqual(pageEngine, "undefined", "The engine is isolated from the page")

        SettingsStore.shared.darkenWebsites = false
        try await until { self.reports.values[parent]?.engine == false && self.reports.values[lightChild]?.engine == false }
        XCTAssertEqual(reports.values[darkChild]?.background, "rgb(16, 16, 18)")

        // The view was created while off. Its next document must ask the
        // current setting rather than replay its creation-time script flag.
        SettingsStore.shared.darkenWebsites = true
        let next = site.url("/second?after-toggle")
        view.load(URLRequest(url: next))
        try await until { self.reports.values[next.absoluteString]?.darkened == true }
        SettingsStore.shared.darkenWebsites = false
        try await until { self.reports.values[next.absoluteString]?.engine == false }
    }

    func testAppearanceAndNativeThemeChangesPreserveMediaAndOriginalColors() async throws {
        SettingsStore.shared.darkenWebsites = true
        window.overrideUserInterfaceStyle = .light
        let view = try await ready("/links")
        let url = site.url("/links").absoluteString
        try await addReports(to: view)
        try await until { self.reports.values[url]?.engine == false }
        window.overrideUserInterfaceStyle = .dark
        try await until { self.reports.values[url]?.darkened == true }
        _ = try await view.evaluateJavaScript("""
            (() => {
              const media = document.createElement('canvas'); media.id = 'owned-media';
              media.width = media.height = 2;
              const context = media.getContext('2d'); context.fillStyle = '#f02040'; context.fillRect(0, 0, 2, 2);
              document.body.append(media);
              const image = document.createElement('img'); image.id = 'owned-image';
              image.src = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><path fill="#f02040" d="M0 0h20v20H0z"/><path fill="#20a0f0" d="M20 0h20v20H20z"/></svg>');
              document.body.append(image);
              return true;
            })()
            """)
        _ = try await view.callAsyncJavaScript("await document.getElementById('owned-image').decode(); return true;", arguments: [:], in: nil, in: .page)
        let filters = try await view.evaluateJavaScript("[getComputedStyle(document.documentElement).filter, getComputedStyle(document.getElementById('owned-media')).filter, getComputedStyle(document.getElementById('owned-image')).filter]") as? [String]
        XCTAssertEqual(filters, ["none", "none", "none"], "Darkening never inverts the page or its media")
        let pixels = try await view.evaluateJavaScript("Array.from(document.getElementById('owned-media').getContext('2d').getImageData(0,0,1,1).data)") as? [Int]
        XCTAssertEqual(pixels, [240, 32, 64, 255])

        // A site switching its own theme while Yab is dark takes precedence.
        _ = try await view.evaluateJavaScript("document.body.style.backgroundColor = '#101012'; document.body.style.color = '#eeeeee'; true")
        try await until { self.reports.values[url]?.engine == false && self.reports.values[url]?.background == "rgb(16, 16, 18)" }
        _ = try await view.evaluateJavaScript("document.body.style.backgroundColor = '#ffffff'; document.body.style.color = '#111111'; true")
        try await until { self.reports.values[url]?.darkened == true }
        window.overrideUserInterfaceStyle = .light
        try await until { self.reports.values[url]?.engine == false && self.reports.values[url]?.background == "rgb(255, 255, 255)" }
    }

    func testNewlyCreatedPrivatePageReadsTheCurrentSetting() async throws {
        SettingsStore.shared.darkenWebsites = true
        window.overrideUserInterfaceStyle = .dark
        let view = try await ready("/links?private", privately: true)
        try await addReports(to: view)
        try await until { self.reports.values[self.site.url("/links?private").absoluteString]?.darkened == true }
        SettingsStore.shared.darkenWebsites = false
        try await until { self.reports.values[self.site.url("/links?private").absoluteString]?.engine == false }
    }

    func testDarkeningToggleUpdatesThePageAndNativeStatusBarTogether() async throws {
        let appearance = SettingsStore.shared.appearance
        SettingsStore.shared.appearance = .dark
        let space = Space(id: "darkening-status", name: "Darkening", emoji: "", tint: RGB(238, 233, 226))
        let app = AppModel(world: World(name: UUID().uuidString, space: space.id, spaces: [space]),
                           fixturesEnabled: false, privateLockEnabled: { false })
        let root = RootController(app: app)
        window.rootViewController = root
        let tab = PageFixtures.liveTab(for: site.url("/links?status"), id: "owned-darkening-status")
        defer {
            app.pages.forget(tab.id)
            window.rootViewController = UIViewController()
            SettingsStore.shared.appearance = appearance
        }
        app.browser.open(tab)
        let view = app.pages.activate(tab)
        try await until { app.pages.painted.contains(tab.id) && !view.isLoading && view.window === self.window }
        try await addReports(to: view)
        let url = site.url("/links?status").absoluteString
        try await until {
            self.reports.values[url]?.engine == false && app.chrome.pageDark[tab.id] == false
                && !app.pageIsDark && root.preferredStatusBarStyle == .darkContent
        }
        SettingsStore.shared.darkenWebsites = true
        try await until {
            self.reports.values[url]?.darkened == true && app.pageIsDark
                && root.preferredStatusBarStyle == .lightContent
        }
        SettingsStore.shared.darkenWebsites = false
        try await until {
            self.reports.values[url]?.engine == false && !app.pageIsDark
                && root.preferredStatusBarStyle == .darkContent
        }
        XCTAssertEqual(root.preferredStatusBarStyle, .darkContent)
    }

    func testASitesDarkWrapperWinsEvenWithAWhiteBodyBackground() async throws {
        SettingsStore.shared.darkenWebsites = true
        window.overrideUserInterfaceStyle = .dark
        let view = try await ready("/links?wrapper")
        let url = site.url("/links?wrapper").absoluteString
        try await addReports(to: view)
        try await until { self.reports.values[url]?.darkened == true }
        _ = try await view.evaluateJavaScript("""
            document.body.innerHTML = '<main id="own-theme" style="position:fixed;inset:0;background:#101012;color:#eeeeee">Native dark website</main>';
            document.body.style.backgroundColor = '#ffffff'; true
            """)
        try await until { self.reports.values[url]?.engine == false }
        let ground = try await view.evaluateJavaScript("getComputedStyle(document.getElementById('own-theme')).backgroundColor") as? String
        XCTAssertEqual(ground, "rgb(16, 16, 18)")
    }

    private func ready(_ path: String, privately: Bool = false) async throws -> WKWebView {
        let tab = PageFixtures.liveTab(for: site.url(path), id: "darkening-" + UUID().uuidString, isPrivate: privately)
        tabs.append(tab)
        let view = pages.activate(tab)
        let host = window.rootViewController!.view!
        view.frame = host.bounds; host.addSubview(view); window.layoutIfNeeded()
        try await until { self.pages.painted.contains(tab.id) && !view.isLoading }
        return view
    }

    private func addReports(to view: WKWebView) async throws {
        let controller = view.configuration.userContentController
        controller.add(reports, name: "ownedDarkeningColors")
        controller.addUserScript(WKUserScript(source: Self.report, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        _ = try await view.evaluateJavaScript(Self.report)
    }

    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        guard predicate() else {
            XCTFail("Darkening did not reach its actual DOM colors: \(reports.values)", file: file, line: line)
            throw NSError(domain: "WebsiteDarkeningTests", code: 1)
        }
    }

    private static let report = """
        (() => {
          if (window.__ownedDarkeningReport) return true;
          window.__ownedDarkeningReport = true;
          setInterval(() => {
            let background = getComputedStyle(document.body).backgroundColor;
            const body = background.match(/[\\d.]+/g)?.map(Number) || [];
            if (body.length > 3 && body[3] < 0.5) background = getComputedStyle(document.documentElement).backgroundColor;
            const rgb = background.match(/[\\d.]+/g)?.map(Number) || [];
            const engine = Boolean(document.getElementById('yab-website-darkening'));
            window.webkit.messageHandlers.ownedDarkeningColors.postMessage({
              url: location.href, background, engine,
              darkened: engine && rgb.length >= 3 && rgb.slice(0,3).reduce((a,b) => a+b,0) < 300
            });
          }, 60);
          return true;
        })()
        """

    private final class ColorReports: NSObject, WKScriptMessageHandler {
        struct Colors: CustomStringConvertible {
            let background: String
            let engine: Bool
            let darkened: Bool
            var description: String { "\(background) engine=\(engine) darkened=\(darkened)" }
        }
        var values: [String: Colors] = [:]

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let url = body["url"] as? String,
                      let color = body["background"] as? String, let engine = body["engine"] as? Bool,
                      let darkened = body["darkened"] as? Bool else { return }
                values[url] = Colors(background: color, engine: engine, darkened: darkened)
            }
        }
    }
}
