import AppKit
import Testing
import WebKit
@testable import Fast

// Arming a tab for its next page (PageScripts): the same list twice is sent
// once, a changed list is sent whole, extensions' scripts are never doubled,
// and in a page's frames the wallet is only a look for a box.
@MainActor
@Suite(.serialized)
struct PageScriptsTests {
    private func browser() -> (Browser, UUID) {
        let id = UUID()
        return (Browser(windowID: id), id)
    }

    private func done(_ browser: Browser, _ id: UUID) {
        for page in browser.tabs { page.close() }
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    // What a script added later has to be: the same object while its input
    // is the same, or every navigation arms again.
    @Test func theListIsTheSameObjectsWhileNothingChanged() {
        let (browser, id) = browser()
        defer { done(browser, id) }
        let tab = browser.open(URL(string: "about:blank#scripts")!, foreground: true)
        let one = PageScripts.list(for: tab, .init(host: "news.test", css: ""))
        let two = PageScripts.list(for: tab, .init(host: "news.test", css: ""))
        #expect(one.count == two.count)
        for (a, b) in zip(one, two) { #expect(a === b, "\(a.source.prefix(60)) was made again") }
        let veiled = PageScripts.list(for: tab, .init(host: "news.test", css: ".ad{display:none}"))
        #expect(veiled.count == one.count + 1)
        #expect(veiled.last === PageScripts.list(for: tab, .init(host: "news.test", css: ".ad{display:none}")).last)
    }

    @Test func armingTheSameListSendsNothing() {
        let (browser, id) = browser()
        defer { done(browser, id) }
        let tab = browser.open(URL(string: "about:blank#arming")!, foreground: true)
        let controller = WKUserContentController()
        let list = PageScripts.list(for: tab, .init(host: "news.test", css: ""))
        #expect(PageScripts.fit(controller, list))
        #expect(!PageScripts.fit(controller, list))
        #expect(controller.userScripts.count == list.count)
        // Another site's hidden things: the list changes, and is sent whole.
        let veiled = PageScripts.list(for: tab, .init(host: "shop.test", css: "#promo{display:none}"))
        #expect(PageScripts.fit(controller, veiled))
        #expect(controller.userScripts.count == veiled.count)
        #expect(PageScripts.fit(controller, list))
        #expect(controller.userScripts.count == list.count)
        // Taken off by something else (a tab put to sleep): sent again.
        controller.removeAllUserScripts()
        #expect(PageScripts.fit(controller, list))
        PageScripts.forget(controller)
        #expect(PageScripts.fit(controller, list))
        #expect(!PageScripts.fit(controller, list))
    }

    @Test func aTabArmedForEachPageOfOneSiteIsSentItsScriptsOnce() {
        let (browser, id) = browser()
        defer { done(browser, id) }
        // This fixture invokes WebKit delegate/SPI contracts directly.
        let tab = Tab(factory: .webKitOnly)
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        tab.go(to: URL(string: "about:blank#again")!)
        tab.arm(hiding: "", on: "news.test")
        // This tab's own controller: the app's counts move with every other
        // suite's tabs arming at the same time.
        let controller = requireNativeWebKitFixture(tab, "PageScriptsTests").configuration.userContentController
        let before = PageScripts.sends(to: controller), asked = PageScripts.counts.asked
        #expect(before >= 1)
        for _ in 0..<5 { tab.arm(hiding: "", on: "news.test") }
        #expect(PageScripts.counts.asked >= asked + 5)
        #expect(PageScripts.sends(to: controller) == before)
        tab.arm(hiding: "h1{display:none}", on: "news.test")
        #expect(PageScripts.sends(to: controller) == before + 1)
    }

    @Test func theWholeWalletIsTheTopPagesOnly() {
        let (browser, id) = browser()
        defer { done(browser, id) }
        // This fixture invokes WebKit delegate/SPI contracts directly.
        let tab = Tab(factory: .webKitOnly)
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        tab.go(to: URL(string: "about:blank#wallet")!)
        let list = PageScripts.list(for: tab, .init(host: "shop.test", css: ""))
        let whole = list.filter { $0.source == WalletRelay.script }
        #expect(whole.count == 1)
        #expect(whole.first?.isForMainFrameOnly == true)
        let look = list.filter { $0.source == WalletRelay.soon }
        #expect(look.count == 1)
        #expect(look.first?.isForMainFrameOnly == false)
        #expect(WalletRelay.soon.utf8.count < 2_000)
    }

    // A frame with a box sends for the wallet and gets it; a frame with
    // none keeps only the look.
    @Test func aFrameWithABoxGetsTheWalletAndAnAdDoesNot() async throws {
        let (browser, id) = browser()
        defer { done(browser, id) }
        // Original wallet/frame assertions execute on the actual selected engine.
        let tab = Tab(factory: .standard)
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        tab.go(to: URL(string: "about:blank#frames")!)
        let html = """
        <!doctype html><title>Checkout</title>
        <iframe id=card srcdoc="<input autocomplete=cc-number name=cardnumber>"></iframe>
        <iframe id=ad srcdoc="<p>Spring sale</p>"></iframe>
        <iframe id=late srcdoc="<p>Loading</p><script>setTimeout(() => document.body.innerHTML = '<input name=cvc>', 300)</script>"></iframe>
        """
        tab.page.navigate(html: html, base: URL(string: "https://shop.test/checkout")!)
        let ask = "[0, 1, 2].map(i => typeof frames[i].__yabWallet + '/' + typeof frames[i].__yabWalletSoon).join(' ')"
        var said = ""
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            said = (try? await tab.page.fixtureExpression(ask, world: .yab)) as? String ?? ""
            if said == "object/boolean undefined/boolean object/boolean" { break }
        }
        #expect(said == "object/boolean undefined/boolean object/boolean")
        let top = (try? await tab.page.fixtureExpression("typeof window.__yabWallet", world: .yab)) as? String
        #expect(top == "object")
    }

    // WebKit keeps an extension's scripts when the app's are cleared; armed
    // again and again, they must stay one each.
    @Test func extensionScriptsStayOneEach() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-arming-extension-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Arming regression","version":"1.0","content_scripts":[{"matches":["https://example.test/*"],"js":["content.js"],"run_at":"document_start"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("globalThis.armed = 1;".utf8).write(to: folder.appendingPathComponent("content.js"))
        let extensionConfiguration = WKWebExtensionController.Configuration.nonPersistent()
        extensionConfiguration.defaultWebsiteDataStore = .nonPersistent()
        let extensions = WKWebExtensionController(configuration: extensionConfiguration)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.hasAccessToPrivateData = true
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://example.test/*"))
        try extensions.load(context)
        defer { try? extensions.unload(context) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = extensionConfiguration.defaultWebsiteDataStore
        configuration.webExtensionController = extensions
        let web = WKWebView(frame: .zero, configuration: configuration)
        let controller = web.configuration.userContentController
        for _ in 0..<100 {
            if !controller.userScripts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let injected = controller.userScripts.map { $0 }
        try #require(!injected.isEmpty, "The fixture must contain actual WebKit extension scripts")

        let (browser, id) = browser()
        defer { done(browser, id) }
        let tab = browser.open(URL(string: "about:blank#extension")!, foreground: true)
        let plain = PageScripts.list(for: tab, .init(host: "example.test", css: ""))
        let veiled = PageScripts.list(for: tab, .init(host: "example.test", css: "p{color:red}"))
        for list in [plain, plain, veiled, plain, veiled, veiled] {
            PageScripts.fit(controller, list)
            let scripts = controller.userScripts.map { $0 }
            #expect(scripts.count == injected.count + list.count)
            for script in injected { #expect(scripts.filter { $0 === script }.count == 1) }
        }
        withExtendedLifetime(web) {}
    }
}
