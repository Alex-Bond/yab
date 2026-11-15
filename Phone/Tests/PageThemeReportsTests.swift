import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// The page may change color after loading. Exercise the real report and
/// native status-bar route without depending on a particular darkening engine.
@MainActor
final class PageThemeReportsTests: XCTestCase {
    private var site: BasicsSite!
    private var app: AppModel!
    private var root: RootController!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var appearance = SettingsStore.Appearance.system
    private var disabled = false
    private var reported: [Bool] = []

    override func setUp() async throws {
        appearance = SettingsStore.shared.appearance
        SettingsStore.shared.appearance = .light
        disabled = Motion.disabled; Motion.disabled = true
        site = try BasicsSite()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            site.start { done.resume(with: $0) }
        }
        let space = Space(id: "page-theme", name: "Page themes", emoji: "", tint: RGB(238, 233, 226))
        app = AppModel(world: World(name: UUID().uuidString, space: space.id, spaces: [space]),
                       fixturesEnabled: false, privateLockEnabled: { false })
        let receive = app.pages.onReport
        app.pages.onReport = { [weak self] id, report in
            receive?(id, report)
            self?.reported.append(report.dark)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        root = RootController(app: app)
        window.rootViewController = root
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        app?.pages.suspendPageDialogs()
        for tab in app?.browser.allTabs ?? [] { app.pages.forget(tab.id) }
        window?.rootViewController = nil; window?.isHidden = true
        window = nil; root = nil; app = nil
        previousKey?.makeKey()
        site?.stop(); site = nil
        SettingsStore.shared.appearance = appearance
        Motion.disabled = disabled
    }

    func testInsertedChangedAndRemovedStylesUpdateTheNativeStatusBar() async throws {
        let view = try await ready()
        try await requireTheme(false)
        _ = try await view.evaluateJavaScript("""
            const sheet = document.createElement('style'); sheet.id = 'owned-theme';
            sheet.textContent = 'html,body{background:#101012!important;color:#eee!important}';
            document.head.append(sheet); true;
            """)
        try await requireTheme(true)
        _ = try await view.evaluateJavaScript("document.getElementById('owned-theme').textContent = 'html,body{background:#fff!important;color:#111!important}'; true")
        try await requireTheme(false)
        _ = try await view.evaluateJavaScript("document.getElementById('owned-theme').textContent = 'html,body{background:#101012!important;color:#eee!important}'; true")
        try await requireTheme(true)
        _ = try await view.evaluateJavaScript("document.getElementById('owned-theme').remove(); true")
        try await requireTheme(false)

        // A busy page still needs only one report for each changed color.
        _ = try await view.callAsyncJavaScript("""
            for (let i = 0; i < 30; i++) {
              document.body.className = 'same-ground-' + i;
              const label = document.createElement('span'); label.textContent = 'Updated';
              document.body.append(label); label.remove();
            }
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return true;
            """, arguments: [:], in: nil, in: .page)
        XCTAssertEqual(reported, [false, true, false, true, false], "Unchanged colors must not repeat native theme reports")
    }

    func testNativeClassAndInlineThemeChangesUpdateTheNativeStatusBar() async throws {
        let view = try await ready()
        try await requireTheme(false)
        _ = try await view.evaluateJavaScript("""
            const sheet = document.createElement('style');
            sheet.textContent = 'body{min-height:100vh}body.native-dark{background:#101012!important;color:#eee!important}';
            document.head.append(sheet);
            document.body.classList.add('native-dark'); true;
            """)
        try await requireTheme(true)
        _ = try await view.evaluateJavaScript("document.body.classList.remove('native-dark'); true")
        try await requireTheme(false)
        _ = try await view.evaluateJavaScript("document.body.style.backgroundColor = '#101012'; true")
        try await requireTheme(true)
        _ = try await view.evaluateJavaScript("document.body.style.backgroundColor = '#ffffff'; true")
        try await requireTheme(false)
    }

    private func ready() async throws -> WKWebView {
        let tab = PageFixtures.liveTab(for: site.url("/links"), id: "owned-page-theme")
        app.browser.open(tab)
        let view = app.pages.activate(tab)
        try await until { self.app.pages.painted.contains(tab.id) && !view.isLoading && view.window === self.window }
        return view
    }

    private func requireTheme(_ dark: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let style: UIStatusBarStyle = dark ? .lightContent : .darkContent
        try await until(file: file, line: line) {
            self.reported.last == dark && self.app.pageIsDark == dark && self.root.preferredStatusBarStyle == style
        }
        XCTAssertEqual(app.pageIsDark, dark, file: file, line: line)
        XCTAssertEqual(root.preferredStatusBarStyle, style, file: file, line: line)
    }

    private func until(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Theme did not reach the native status bar: reports=\(reported), pageIsDark=\(app.pageIsDark), style=\(root.preferredStatusBarStyle.rawValue)", file: file, line: line)
        throw NSError(domain: "PageThemeReportsTests", code: 1)
    }
}
