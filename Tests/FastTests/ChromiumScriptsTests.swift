import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumScriptsTests {
    @Test func savedSiteLooksChooseTheDocumentHostAndKeepTheirProfile() async throws {
        _ = NSApplication.shared
        let domain = UUID().uuidString.lowercased() + ".test"
        let target = URL(string: "https://www.\(domain)/article")!
        let tab = Tab(bench: true), otherProfile = UUID()
        tab.restore(url: URL(string: "https://elsewhere.test/")!, title: "Source")
        let store = BoostEditorLooks.shared
        let profile = AddonProfiles.of(tab)
        var look = BoostEditorLook()
        look.hidden = [Veil(selector: "#www-banner", label: "Banner", date: Date())]
        look.css = "h1 { color: purple; }"
        store.set(look, host: target.host!, profile: profile)
        var bareLook = BoostEditorLook()
        bareLook.hidden = [Veil(selector: "#bare-banner", label: "Bare banner", date: Date())]
        store.set(bareLook, host: domain, profile: profile)
        var foreign = BoostEditorLook()
        foreign.hidden = [Veil(selector: "#other-profile", label: "Other profile", date: Date())]
        store.set(foreign, host: target.host!, profile: otherProfile)
        defer {
            store.set(BoostEditorLook(), host: target.host!, profile: profile)
            store.set(BoostEditorLook(), host: domain, profile: profile)
            store.set(BoostEditorLook(), host: target.host!, profile: otherProfile)
            store.flush()
            tab.close()
        }
        let source = try #require(store.chromiumSource(for: tab))
        let addons = ChromiumAddons(for: tab)
        #expect(addons.look == source)
        #expect(addons.scripts.contains { $0.source == source && $0.world == .yab && $0.atEnd && $0.mainOnly })
        #expect(!source.contains("#other-profile"))
        // Register once, while the tab is on an unrelated host. Both new
        // documents must choose their own saved look without any rearming.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        defer { web.stopLoading() }
        #expect(try await hiddenBanners(in: web, at: target) == ["none", "block", "block"])
        #expect(try await hiddenBanners(in: web, at: URL(string: "https://\(domain)/")!) == ["block", "none", "block"])
        #expect(try await hiddenBanners(in: web, at: URL(string: "https://constructor/")!) == ["block", "block", "block"])
        let privateTab = Tab(shy: true, bench: true)
        defer { privateTab.close() }
        privateTab.restore(url: target, title: "Private")
        #expect(ChromiumAddons(for: privateTab).look == nil)
        // A rule in another sign-in profile must not supply this tab's look.
        store.set(BoostEditorLook(), host: target.host!, profile: profile)
        #expect(ChromiumAddons(for: tab).look?.contains("#www-banner") == false)
        #expect(ChromiumAddons(for: tab).look?.contains("#other-profile") == false)
        look.enabled = false
        store.set(look, host: target.host!, profile: profile)
        #expect(ChromiumAddons(for: tab).look?.contains("#www-banner") == false)
    }

    @Test func hiddenStylesChooseTheNewDocumentWithoutArmingForItsDestination() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let ipv6 = URL(string: "https://[::1]/")!
        let rules = ["one.test": "#www-banner { display: none !important; }",
                     "two.test": "#bare-banner { display: none !important; }",
                     PageScripts.host(of: ipv6)!: "#www-banner { display: none !important; }"]
        let policy = Veiling.styles(rules)
        let tab = Tab(shy: true, bench: true)
        defer { tab.close() }
        let previousCSS = "#other-profile { display: none !important; }"
        let registrations = PageScripts.chromium(for: tab, .init(host: "previous.test", css: previousCSS), hiddenCSS: rules)
        #expect(registrations.contains { $0.source == policy && $0.world == .yab && !$0.atEnd && $0.mainOnly })
        #expect(!registrations.contains { $0.source == Veiling.style(previousCSS) })
        configuration.userContentController.addUserScript(WKUserScript(
            source: policy, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        defer { web.stopLoading() }
        #expect(try await hiddenBanners(in: web, at: URL(string: "https://www.one.test/")!) == ["none", "block", "block"])
        #expect(try await hiddenBanners(in: web, at: URL(string: "https://two.test/")!) == ["block", "none", "block"])
        #expect(try await hiddenBanners(in: web, at: URL(string: "https://unrelated.test/")!) == ["block", "block", "block"])
        #expect(try await hiddenBanners(in: web, at: ipv6) == ["none", "block", "block"])
        let firstID = UUID(), secondID = UUID()
        let first = Browser(windowID: firstID), second = Browser(windowID: secondID)
        defer {
            for browser in [first, second] { for tab in browser.tabs { tab.close() } }
            for id in [firstID, secondID] {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        #expect(first.curtain === second.curtain)
    }

    private func hiddenBanners(in web: WKWebView, at url: URL) async throws -> [String] {
        web.loadHTMLString("<html><body><div id='www-banner'>WWW</div><div id='bare-banner'>Bare</div><div id='other-profile'>Other</div></body></html>", baseURL: url)
        var ready = false
        for _ in 0..<100 {
            ready = (try? await BoostJavaScript.evaluate("location.href === \(BoostScript.json(url.absoluteString)) && document.readyState === 'complete' && !!document.querySelector('#other-profile')", on: web)) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready)
        return try #require(try await BoostJavaScript.evaluate("['www-banner','bare-banner','other-profile'].map(id => getComputedStyle(document.getElementById(id)).display)", on: web) as? [String])
    }

    @Test func webKitSavedLookUsesTheSameIPv6HostSyntax() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BoostEditorLooks(file: root.appendingPathComponent("site-looks.json"))
        let tab = Tab(bench: true), url = URL(string: "https://[::1]/")!
        defer { tab.close(); store.flush(); try? FileManager.default.removeItem(at: root) }
        var look = BoostEditorLook()
        look.hidden = [Veil(selector: "#www-banner", label: "Banner", date: Date())]
        let host = try #require(BoostEditorLook.host(url))
        store.set(look, host: host, profile: AddonProfiles.of(tab))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(try #require(store.script(for: tab, host: host)))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        defer { web.stopLoading() }
        #expect(try await hiddenBanners(in: web, at: url) == ["none", "block", "block"])
        #expect(try await hiddenBanners(in: web, at: URL(string: "https://elsewhere.test/")!) == ["block", "block", "block"])
    }

    @Test func worldNamesMatchEvaluationWorlds() {
        #expect(ChromiumScripts.world(.page) == "")
        #expect(ChromiumScripts.world(.client) == "yab-client")
        #expect(ChromiumScripts.world(.yab) == "yab-world-yab")
        #expect(ChromiumScripts.world(.agent) == "yab-world-yab-agent")
    }

    @Test func acceptedNavigationReportsLoadingBeforeHelperStarts() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.navigate(to: URLRequest(url: URL(string: "https://example.test/")!))
        #expect(page.isLoading)
        #expect(page.remoteID == nil)
    }

    @Test func frameTokensStayWithTheirOwnerAndHelperTab() throws {
        let first = ChromiumScripts(), second = ChromiumScripts()
        let frames = first.frames(.array([.object(["token": .string("document-1"), "url": .string("https://frame.example/login"),
            "scheme": .string("https"), "host": .string("frame.example"), "port": .number(443), "main": .bool(false)])]), tab: "tab-1")
        let frame = try #require(frames.first)
        #expect(frame.origin.host == "frame.example")
        #expect(try first.token(frame, tab: "tab-1") == "document-1")
        #expect(throws: PageEngineError.self) { try second.token(frame, tab: "tab-1") }
        #expect(throws: PageEngineError.self) { try first.token(frame, tab: "tab-2") }
        #expect(try first.token(nil, tab: nil) == nil)
    }
    @Test func generalRelaysKeepMainFrameGuards() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let frame = PageFrame(isMain: false, url: URL(string: "https://frame.test/"), token: NSObject())
        let main = PageFrame(isMain: true, url: URL(string: "https://page.test/"), token: NSObject())
        let json = tab.chromiumScriptReceiver(JSONRelay.name)!
        let state: [String: Any] = ["kind": "state", "shown": "tree", "size": 12]
        json.receive(PageScriptMessage(body: state, frame: frame))
        #expect(tab.json == nil)
        json.receive(PageScriptMessage(body: state, frame: main))
        #expect(tab.json?.shown == .tree)
        let veil = tab.chromiumScriptReceiver(VeilRelay.name)!
        var trouble: String?
        tab.onPickTrouble = { _, reason in trouble = reason }
        veil.receive(PageScriptMessage(body: ["trouble": "child"], frame: frame))
        #expect(trouble == nil)
        veil.receive(PageScriptMessage(body: ["trouble": "main"], frame: main))
        #expect(trouble == "main")
    }

    @Test func pageAPIsAndPrivateTelemetryKeepTheirOriginalBoundaries() {
        _ = NSApplication.shared
        let normal = Tab(shy: false), privateTab = Tab(shy: true)
        defer { normal.close(); privateTab.close() }
        let plan = PageScripts.Arming(host: "example.test", css: "")
        let registrations = PageScripts.chromium(for: normal, plan)
        let badge = registrations.first { $0.source == BadgeRelay.page }
        let bridge = registrations.first { $0.source == BadgeRelay.bridge }
        #expect(badge?.world == .page)
        #expect(badge?.mainOnly == true)
        #expect(bridge?.world == .yab)
        #expect(bridge?.mainOnly == true)
        #expect(registrations.contains { $0.source == WatchRelay.script && !$0.mainOnly })
        #expect(registrations.contains { $0.source == PageScript.load("sent") })
        let privateScripts = PageScripts.chromium(for: privateTab, plan)
        #expect(!privateScripts.contains { $0.source == WatchRelay.script })
        #expect(!privateScripts.contains { $0.source == PageScript.load("sent") })
    }

    @Test func callSwitchesAndPeekScriptsRideInYabsWorld() {
        _ = NSApplication.shared
        let tab = Tab(shy: false)
        defer { tab.close() }
        let registrations = PageScripts.chromium(for: tab, PageScripts.Arming(host: "meet.google.com", css: ""))
        for source in [CallRelay.script, LinkCardRules.script, PeekOrigin.script(force: false)] {
            let found = registrations.first { $0.source == source }
            #expect(found?.world == .yab)
            #expect(found?.mainOnly == true)
        }
        #expect(registrations.first { $0.source == CallRelay.script }?.atEnd == true)
        // The film on a page, in a world of its own in every frame (Float, PiP).
        let isolate = registrations.first { $0.source == Isolate.script.source }
        #expect(isolate?.world == .named("float"))
        #expect(isolate?.mainOnly == false)
        // Yab's own getDisplayMedia, in the page's world and in every frame, with its bridge in Yab's.
        let share = registrations.first { $0.source == ShareScript.page }
        #expect(share?.world == .page)
        #expect(share?.mainOnly == false)
        let bridge = registrations.first { $0.source == ShareScript.bridge }
        #expect(bridge?.world == .yab)
        #expect(bridge?.mainOnly == false)
        #expect(registrations.first { $0.source == LinkCardRules.script }?.atEnd == false)
        // Only the variant the tab asks for.
        #expect(!registrations.contains { $0.source == PeekOrigin.script(force: true) })
        tab.forcePeeks = { true }
        let forced = PageScripts.chromium(for: tab, PageScripts.Arming(host: "meet.google.com", css: ""))
        #expect(forced.contains { $0.source == PeekOrigin.script(force: true) })
        #expect(!forced.contains { $0.source == PeekOrigin.script(force: false) })
    }

    @Test func youTubeAdSkippingRidesInThePageWorldOnlyWhereShieldAsks() {
        _ = NSApplication.shared
        let tab = Tab(shy: false)
        defer { tab.close() }
        let plan = PageScripts.Arming(host: "www.youtube.com", css: "")
        #expect(!PageScripts.chromium(for: tab, plan).contains { $0.source == YouTube.user.source })
        tab.skipsAds = true
        let skipping = PageScripts.chromium(for: tab, plan).first { $0.source == YouTube.user.source }
        #expect(skipping?.world == .page)
        #expect(skipping?.mainOnly == true)
    }

    @Test func callRelayUsesTheNativeMainFrameOriginAndKeepsSlackWindowState() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let relay = tab.chromiumScriptReceiver(CallRelay.name)!
        func send(_ host: String, scheme: String = "https", main: Bool = true, body: [String: Any]) {
            let frame = PageFrame(isMain: main, url: URL(string: "\(scheme)://\(host)/"), token: NSObject(),
                                  origin: PageOrigin(scheme: scheme, host: host, port: scheme == "https" ? 443 : 80))
            relay.receive(PageScriptMessage(body: body, frame: frame))
        }
        send("meet.google.com", body: ["mic": true, "camera": false])
        #expect(tab.pageMic == true && tab.pageCamera == false)
        for host in ["meet.google.com.evil.test", "notzoom.us", "slack.com"] {
            send(host, body: ["mic": false, "camera": true])
            #expect(tab.pageMic == true && tab.pageCamera == false)
        }
        send("meet.google.com", scheme: "http", body: ["mic": false])
        send("meet.google.com", main: false, body: ["mic": false])
        #expect(tab.pageMic == true && tab.pageCamera == false)
        send("us06web.zoom.us", body: ["mic": false, "camera": true])
        #expect(tab.pageMic == false && tab.pageCamera == true)
        send("app.slack.com", body: ["mic": NSNull(), "camera": NSNull()])
        #expect(tab.pageMic == false && tab.pageCamera == true)
        send("app.slack.com", body: ["mic": true, "camera": false])
        #expect(tab.pageMic == true && tab.pageCamera == false)
    }

    @Test func draftStateBelongsToTheMainDocumentAndResetsOnNavigation() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let relay = tab.chromiumScriptReceiver(FormRelay.name)!
        let child = PageFrame(isMain: false, url: URL(string: "https://frame.test/"), token: NSObject())
        let main = PageFrame(isMain: true, url: URL(string: "https://page.test/"), token: NSObject())
        relay.receive(PageScriptMessage(body: ["kind": "draft", "on": true], frame: child))
        #expect(!tab.draft)
        relay.receive(PageScriptMessage(body: ["kind": "draft", "on": true], frame: main))
        #expect(tab.draft)
        relay.receive(PageScriptMessage(body: ["kind": "draft", "on": false], frame: child))
        #expect(tab.draft)
        relay.receive(PageScriptMessage(body: ["kind": "draft", "on": false], frame: main))
        #expect(!tab.draft)
        relay.receive(PageScriptMessage(body: ["kind": "draft", "on": true], frame: main))
        tab.chromiumScriptsCommitted()
        #expect(!tab.draft)
    }

    @Test func aNewChromiumDocumentDropsThePreviousSitesCallSwitches() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        tab.pageMic = true
        tab.pageCamera = false
        tab.chromiumScriptsCommitted()
        #expect(tab.pageMic == nil && tab.pageCamera == nil)
    }

    @Test func yabsOwnSiteIsToldItIsOpenInYabOnChromiumToo() {
        _ = NSApplication.shared
        let tab = Tab(shy: false)
        defer { tab.close() }
        let mark = Dress.script(Links.browser).source
        let ours = PageScripts.chromium(for: tab, PageScripts.Arming(host: "yetanotherbrowser.com", css: ""))
        #expect(ours.first { $0.source == mark }?.world == .yab)
        let other = PageScripts.chromium(for: tab, PageScripts.Arming(host: "example.test", css: ""))
        #expect(!other.contains { $0.source == mark })
    }

    @Test func imageRelayRetainsItsSchemeAndFramePolicy() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let child = PageFrame(isMain: false, url: URL(string: "https://frame.test/"), token: NSObject())
        let receiver = tab.chromiumScriptReceiver(ImageRelay.name)!
        receiver.receive(PageScriptMessage(body: ["src": "https://frame.test/picture.png"], frame: child))
        #expect(tab.pointedImage?.url.absoluteString == "https://frame.test/picture.png")
        receiver.receive(PageScriptMessage(body: ["src": "file:///private/picture.png"], frame: child))
        #expect(tab.pointedImage?.url.absoluteString == "https://frame.test/picture.png")
        receiver.receive(PageScriptMessage(body: ["link": "mailto:person@example.test"], frame: child))
        #expect(tab.pointedLink?.url.absoluteString == "mailto:person@example.test")
        receiver.receive(PageScriptMessage(body: ["link": "javascript:alert(1)"], frame: child))
        #expect(tab.pointedLink?.url.absoluteString == "mailto:person@example.test")
    }

}
