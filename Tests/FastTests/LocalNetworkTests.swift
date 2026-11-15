import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// Addresses read by the Local Network Access rules Chrome ships.
struct LocalNetworkSpaceTests {
    @Test func addressesFallInChromesSpaces() {
        let cases: [(String, LocalNetwork.Space)] = [
            ("localhost", .loopback), ("app.localhost", .loopback), ("127.0.0.1", .loopback), ("127.9.9.9", .loopback),
            ("0.0.0.0", .loopback), ("[::1]", .loopback), ("::", .loopback), ("[::ffff:127.0.0.1]", .loopback),
            ("10.0.0.1", .local), ("172.16.0.1", .local), ("172.31.255.1", .local), ("192.168.1.1", .local),
            ("169.254.1.1", .local), ("100.64.0.1", .local), ("100.127.255.255", .local), ("0.1.2.3", .local),
            ("[fd12:3456::1]", .local), ("fe80::1", .local), ("[fec0::1]", .local), ("[2001:db8::1]", .local),
            ("[3fff:0fff::1]", .local), ("[::ffff:192.168.0.1]", .local), ("printer.local", .local), ("nas", .local),
            ("example.com", .public), ("8.8.8.8", .public), ("172.32.0.1", .public), ("100.128.0.1", .public),
            ("198.18.0.1", .public), ("224.0.0.1", .public), ("[2606:4700::1111]", .public), ("[3fff:1000::1]", .public),
            ("127.0.0.1.sslip.io", .public), ("localhost.example.com", .public),
        ]
        for (host, space) in cases { #expect(LocalNetwork.space(of: host) == space, "\(host)") }
    }

    /// Chrome reads a page's space off the address its name reached, so
    /// app.lvh.me is this Mac's page (feedback #884).
    @Test func aNameIsReadByWhereItResolved() {
        #expect(LocalNetwork.space(ofResolved: []) == nil)
        #expect(LocalNetwork.space(ofResolved: ["127.0.0.1"]) == .loopback)
        #expect(LocalNetwork.space(ofResolved: ["::1", "127.0.0.1"]) == .loopback)
        #expect(LocalNetwork.space(ofResolved: ["127.0.0.1", "192.168.1.5"]) == .local)
        #expect(LocalNetwork.space(ofResolved: ["10.0.0.7"]) == .local)
        #expect(LocalNetwork.space(ofResolved: ["fe80::1%lo0"]) == .local)
        // One public address and the connection may go there: a website.
        #expect(LocalNetwork.space(ofResolved: ["127.0.0.1", "93.184.215.14"]) == .public)
        #expect(LocalNetwork.space(ofResolved: ["2606:4700::1111"]) == .public)
    }

    /// The system's resolver, as WebKit's own: lvh.me and nip.io names
    /// point here, a website doesn't.
    @Test func localDevelopmentNamesResolveHere() {
        #expect(![nil, .public].contains(LocalNetwork.space(ofResolved: LocalNetwork.addresses(of: "localhost"))))
        #expect(LocalNetwork.space(ofResolved: LocalNetwork.addresses(of: "app.lvh.me")) == .loopback)
        #expect(LocalNetwork.space(ofResolved: LocalNetwork.addresses(of: "127.0.0.1.nip.io")) == .loopback)
        #expect(LocalNetwork.space(ofResolved: LocalNetwork.addresses(of: "example.com")) == .public)
        #expect(LocalNetwork.space(ofResolved: LocalNetwork.addresses(of: "no-such-name.invalid")) == nil)
    }

    @Test func aHomeNamesEveryPortAndScheme() throws {
        let filter = LocalNetwork.homeFilter("App.lvh.me")
        let regex = try NSRegularExpression(pattern: filter)
        func matches(_ url: String) -> Bool { regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        #expect(matches("http://app.lvh.me:3000/"))
        #expect(matches("https://app.lvh.me/login"))
        #expect(matches("https://user@app.lvh.me:8443/x"))
        #expect(!matches("http://api.lvh.me:3000/"))
        #expect(!matches("http://app.lvh.me.evil.com/"))
        #expect(!matches("http://appxlvh.me/"))
    }

    @MainActor @Test func aPageIsHomeByItsNameOrWhereItResolved() {
        LocalNetwork.forgetLooks()
        #expect(LocalNetwork.isHome("localhost"))
        #expect(LocalNetwork.isHome("192.168.1.1"))
        #expect(!LocalNetwork.isHome("app.lvh.me"))
        #expect(LocalNetwork.needsLook(URL(string: "http://app.lvh.me:3000/")!))
        #expect(!LocalNetwork.needsLook(URL(string: "http://localhost:3000/")!))
        #expect(!LocalNetwork.needsLook(URL(string: "http://8.8.8.8/")!))
        #expect(!LocalNetwork.needsLook(URL(string: "file:///tmp/a.html")!))
        LocalNetwork.record("app.lvh.me", .loopback)
        LocalNetwork.record("www.example.com", .public)
        #expect(LocalNetwork.isHome("app.lvh.me"))
        #expect(LocalNetwork.homes == ["app.lvh.me"])
        #expect(!LocalNetwork.needsLook(URL(string: "http://app.lvh.me:3000/")!))
        #expect(!LocalNetwork.isHome("example.com"))
        // No ad blocker on a local page; a website keeps it.
        #expect(Shield.shared.isOff(on: "localhost"))
        #expect(Shield.shared.isOff(on: "app.lvh.me"))
        #expect(!Shield.shared.isOff(on: "example.com"))
        // A name that resolves elsewhere now leaves.
        LocalNetwork.record("app.lvh.me", .public)
        #expect(!LocalNetwork.isHome("app.lvh.me"))
        #expect(LocalNetwork.homes.isEmpty)
        LocalNetwork.forgetLooks()
    }

    @Test func aGrantNamesOnlyItsOrigin() {
        let filter = LocalNetwork.originFilter("https://example.com:443")
        #expect(filter == #"^https://example\.com(:443)?/"#)
        #expect(LocalNetwork.originFilter("http://127.0.0.1.sslip.io:8080") == #"^http://127\.0\.0\.1\.sslip\.io:8080/"#)
    }

    @MainActor @Test func theListCompilesWithAndWithoutGrants() async throws {
        let store = try #require(WKContentRuleListStore.default())
        let grants: [[LocalNetwork.Kind: [String]]] = [[:], [.loopback: ["https://a.example:443"], .local: ["https://b.example:8443"]]]
        for granted in grants {
            for homes in [[], ["app.lvh.me", "api.lvh.me", "my-app.test"]] {
                let list = try await store.compileContentRuleList(forIdentifier: "local-network-test", encodedContentRuleList: LocalNetwork.rules(granted: granted, homes: homes))
                #expect(list != nil)
            }
        }
        try? await store.removeContentRuleList(forIdentifier: "local-network-test")
    }
}

/// What a developer's browser must keep doing, and what a website must not.
@Suite(.serialized)
struct LocalNetworkPageTests {
    @MainActor private static func view(listed: Bool = true) async -> PageView {
        _ = await LocalNetwork.ready()
        let config = Web.configuration(shy: true, store: .nonPersistent())
        if !listed { config.userContentController.removeAllContentRuleLists() }
        return PageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
    }
    /// A tab going somewhere goes as plain WebKit lets it: the same steps
    /// on a view without the list first, then with it, told apart by path.
    @MainActor private static func asPlainWebKit(_ flow: (PageView, String) async throws -> Bool) async throws {
        let plainView = await view(listed: false)
        defer { plainView.stopLoading() }
        let plain = try await flow(plainView, "plain")
        let listedView = await view()
        defer { listedView.stopLoading() }
        let listed = try await flow(listedView, "listed")
        #expect(plain, "plain WebKit didn't get there either: the test, not the list")
        #expect(listed == plain)
    }
    /// A public name for the fixture: WebKit sees a website, the socket is
    /// still this Mac's.
    private static func site(_ fixture: LocalNetworkFixture) async throws -> String {
        let origin = "http://127.0.0.1.sslip.io:\(fixture.port)"
        _ = try await URLSession.shared.data(from: URL(string: origin + "/warm")!)
        return origin
    }
    private static func reached(_ fixture: LocalNetworkFixture, _ path: String, seconds: Double = 6) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if fixture.requests.contains(where: { $0.path.hasPrefix(path) }) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    // MARK: kept working

    @MainActor @Test func typedLocalAddressFollowsItsOwnRedirect() async throws {
        let dev = try LocalNetworkFixture(); defer { dev.stop() }
        for tag in ["plain", "listed"] {
            dev.route("/\(tag)", .init("", status: "302 Found", headers: "Location: /login-\(tag)\r\n"))
        }
        try await Self.asPlainWebKit { web, tag in
            _ = web.load(URLRequest(url: URL(string: dev.root + "/\(tag)")!))
            // In a full test run the plain view's first load here comes
            // near the old 15 s deadline (passing and failing runs alike
            // took 20.8 s in all); alone the whole suite takes 17 s.
            return await Self.reached(dev, "/login-\(tag)", seconds: 30)
        }
    }

    @MainActor @Test func signInRedirectReachesTheCommandLine() async throws {
        let provider = try LocalNetworkFixture(), cli = try LocalNetworkFixture()
        defer { provider.stop(); cli.stop() }
        let site = try await Self.site(provider)
        for tag in ["plain", "listed"] {
            provider.route("/consent-\(tag)", .init("<form method=post action='/approve-\(tag)'></form><script>setTimeout(()=>document.forms[0].submit(),100)</script>"))
            provider.route("/approve-\(tag)", .init("", status: "302 Found", headers: "Location: \(cli.root)/callback-\(tag)?code=abc\r\n"))
        }
        try await Self.asPlainWebKit { web, tag in
            _ = web.load(URLRequest(url: URL(string: site + "/consent-\(tag)")!))
            return await Self.reached(cli, "/callback-\(tag)", seconds: 15)
        }
    }

    @MainActor @Test func signInScriptReachesTheCommandLine() async throws {
        let provider = try LocalNetworkFixture(), cli = try LocalNetworkFixture()
        defer { provider.stop(); cli.stop() }
        let site = try await Self.site(provider)
        for tag in ["plain", "listed"] {
            provider.route("/done-\(tag)", .init("<script>setTimeout(()=>location.href='\(cli.root)/scripted-\(tag)?code=abc',100)</script>"))
        }
        try await Self.asPlainWebKit { web, tag in
            _ = web.load(URLRequest(url: URL(string: site + "/done-\(tag)")!))
            return await Self.reached(cli, "/scripted-\(tag)", seconds: 15)
        }
    }

    @MainActor @Test func linkOnAWebsiteOpensTheLocalServer() async throws {
        let docs = try LocalNetworkFixture(), dev = try LocalNetworkFixture()
        defer { docs.stop(); dev.stop() }
        let site = try await Self.site(docs)
        for tag in ["plain", "listed"] {
            docs.route("/readme-\(tag)", .init("<a id=l href='\(dev.root)/app-\(tag)'>open</a><script>setTimeout(()=>l.click(),100)</script>"))
        }
        try await Self.asPlainWebKit { web, tag in
            _ = web.load(URLRequest(url: URL(string: site + "/readme-\(tag)")!))
            return await Self.reached(dev, "/app-\(tag)", seconds: 15)
        }
    }

    @MainActor @Test func localPageReachesItsAPIAndItsSocketsAnywhereLocal() async throws {
        let frontend = try LocalNetworkFixture(), api = try LocalNetworkFixture()
        defer { frontend.stop(); api.stop() }
        api.route("/api", .init("{}", headers: "Access-Control-Allow-Origin: *\r\n"))
        frontend.route("/", .init("""
        <script>
        window.done={};
        fetch('\(api.root)/api').then(r=>done.api=r.status).catch(()=>done.api='blocked');
        fetch('http://localhost:\(frontend.port)/same').catch(()=>0);
        const ws=new WebSocket('ws://127.0.0.1:\(frontend.port)/hmr');ws.onopen=()=>ws.send('ping');ws.onmessage=()=>done.hmr=true;ws.onerror=()=>done.hmr=false;
        </script>
        """))
        let web = await Self.view(); defer { web.stopLoading() }
        _ = web.load(URLRequest(url: URL(string: "http://localhost:\(frontend.port)/")!))
        #expect(await Self.reached(api, "/api"))
        #expect(await Self.reached(frontend, "/same"))
        for _ in 0..<60 where frontend.messages.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(frontend.messages.contains(Data("ping".utf8)))
    }

    /// Storybook's preview, a router's frames: a local page's frames on
    /// itself or on another local port.
    @MainActor @Test func localPageFramesLocalPages() async throws {
        let page = try LocalNetworkFixture(), other = try LocalNetworkFixture()
        defer { page.stop(); other.stop() }
        page.route("/", .init("<iframe src='/preview'></iframe><iframe src='\(other.root)/panel'></iframe><iframe srcdoc=\"<img src='\(other.root)/inside-srcdoc'>\"></iframe>"))
        page.route("/preview", .init("<img src='\(other.root)/from-frame'>"))
        let web = await Self.view(); defer { web.stopLoading() }
        _ = web.load(URLRequest(url: URL(string: page.root + "/")!))
        #expect(await Self.reached(page, "/preview"))
        #expect(await Self.reached(other, "/panel"))
        #expect(await Self.reached(other, "/from-frame"))
        #expect(await Self.reached(other, "/inside-srcdoc"))
    }

    /// Feedback #884: a page on app.lvh.me, which resolves here, frames
    /// and calls its servers on localhost and 127.0.0.1, allowed. The
    /// same page before its name was looked up is a website's, held back.
    @MainActor @Test func aNameResolvingHereReachesThisMac() async throws {
        let site = try LocalNetworkFixture(), dev = try LocalNetworkFixture()
        defer { site.stop(); dev.stop() }
        let origin = try await Self.site(site)
        let host = try #require(URL(string: origin)?.host())
        for tag in ["before", "after"] {
            site.route("/app-\(tag)", .init("""
            <iframe src='\(dev.root)/frame-\(tag)'></iframe>
            <iframe src='http://localhost:\(dev.port)/named-\(tag)'></iframe>
            <script>fetch('\(dev.root)/api-\(tag)').catch(()=>0)</script>
            """))
        }
        LocalNetwork.forgetLooks()
        await withCheckedContinuation { c in LocalNetwork.whenSettled { c.resume() } }
        let web = await Self.view(); defer { web.stopLoading() }
        _ = web.load(URLRequest(url: URL(string: origin + "/app-before")!))
        #expect(await Self.reached(site, "/app-before"))
        #expect(!(await Self.reached(dev, "/", seconds: 3)), "\(dev.requests.map(\.path))")

        LocalNetwork.record(host, LocalNetwork.space(ofResolved: LocalNetwork.addresses(of: host)))
        #expect(LocalNetwork.homes.contains(host))
        await withCheckedContinuation { c in LocalNetwork.whenSettled { c.resume() } }
        _ = web.load(URLRequest(url: URL(string: origin + "/app-after")!))
        #expect(await Self.reached(dev, "/frame-after"))
        #expect(await Self.reached(dev, "/named-after"))
        #expect(await Self.reached(dev, "/api-after"))
        LocalNetwork.forgetLooks()
        await withCheckedContinuation { c in LocalNetwork.whenSettled { c.resume() } }
    }

    // MARK: held back

    @MainActor @Test func websiteCannotReachThisMac() async throws {
        let site = try LocalNetworkFixture(), victim = try LocalNetworkFixture()
        defer { site.stop(); victim.stop() }
        let origin = try await Self.site(site)
        site.route("/evil", .init("""
        <script>
        fetch('\(victim.root)/fetch',{method:'POST',mode:'no-cors',body:'x'}).catch(()=>0);
        new Image().src='\(victim.root)/img';
        new Image().src='http://localhost:\(victim.port)/named';
        new Image().src='http://[::ffff:7f00:1]:\(victim.port)/mapped';
        new Image().src='http://0x7f000001:\(victim.port)/hex';
        try{new WebSocket('ws://127.0.0.1:\(victim.port)/ws')}catch(e){}
        navigator.sendBeacon('\(victim.root)/beacon','x');
        </script>
        <iframe src='\(victim.root)/frame'></iframe>
        <iframe src='/redirect'></iframe>
        """))
        site.route("/redirect", .init("", status: "302 Found", headers: "Location: \(victim.root)/redirected\r\n"))
        let web = await Self.view(); defer { web.stopLoading() }
        _ = web.load(URLRequest(url: URL(string: origin + "/evil")!))
        #expect(await Self.reached(site, "/redirect"))
        #expect(!(await Self.reached(victim, "/", seconds: 3)), "\(victim.requests.map(\.path))")
        #expect(victim.tcpConnections == 0)
    }

    @MainActor @Test func aLetterCannotReachThisMac() async throws {
        let victim = try LocalNetworkFixture(); defer { victim.stop() }
        let web = await Self.view(); defer { web.stopLoading() }
        _ = web.loadHTMLString("<img src='\(victim.root)/pixel'><img src='http://192.168.0.1/pixel'>", baseURL: nil)
        #expect(!(await Self.reached(victim, "/", seconds: 3)))
    }

    // MARK: asked and allowed

    @MainActor @Test func anAllowedSiteReachesThisMacUntilForgotten() async throws {
        let site = try LocalNetworkFixture(), app = try LocalNetworkFixture()
        defer { site.stop(); app.stop() }
        let origin = try await Self.site(site)
        let granted = try #require(Browser.origin(of: URL(string: origin)))
        site.route("/tool", .init("<script>fetch('\(app.root)/'+location.search.slice(1)).catch(()=>0)</script>"))
        LocalNetwork.remember(granted, .loopback, true)
        await withCheckedContinuation { c in LocalNetwork.whenSettled { c.resume() } }
        let web = await Self.view(); defer { web.stopLoading() }
        _ = web.load(URLRequest(url: URL(string: origin + "/tool?allowed")!))
        #expect(await Self.reached(app, "/allowed"))
        LocalNetwork.forget(granted, .loopback)
        await withCheckedContinuation { c in LocalNetwork.whenSettled { c.resume() } }
        #expect(LocalNetwork.said(granted, .loopback) == nil)
        _ = web.load(URLRequest(url: URL(string: origin + "/tool?forgotten")!))
        #expect(await Self.reached(site, "/tool?forgotten"))
        #expect(!(await Self.reached(app, "/forgotten", seconds: 3)))
    }

    @MainActor @Test func aNoIsKeptOnlyWhileYabIsOpen() {
        let origin = "https://nag.example:443"
        LocalNetwork.remember(origin, .local, false)
        #expect(LocalNetwork.said(origin, .local) == false)
        #expect(LocalNetwork.granted[.local]?.contains(origin) != true)
        LocalNetwork.forget(origin, .local)
        #expect(LocalNetwork.said(origin, .local) == nil)
    }

    @MainActor @Test func onlyAListeningAppIsAskedAbout() async throws {
        let app = try LocalNetworkFixture(); defer { app.stop() }
        let open = await withCheckedContinuation { c in LocalNetwork.answers(URL(string: app.root + "/x")!) { c.resume(returning: $0) } }
        #expect(open)
        app.stop()
        // The listener's cancel lands on its own queue a moment later.
        try await Task.sleep(nanoseconds: 500_000_000)
        let closed = await withCheckedContinuation { c in LocalNetwork.answers(URL(string: app.root + "/x")!) { c.resume(returning: $0) } }
        #expect(!closed)
    }
}
