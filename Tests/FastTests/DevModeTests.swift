import Foundation
import Testing
@testable import Fast

// Developer Mode (DevMode.swift): which pages are a server on this Mac, a
// stack read the short way, and what is copied for an agent, its secrets out.
struct DevModeTests {
    static let page = URL(string: "http://localhost:3000/cart?items=3")!

    @Test func onlyThisMacsOwnServersAreLocal() {
        for local in ["http://localhost:3000", "http://app.localhost:5173/x", "https://shop.test", "http://127.0.0.1:8000", "http://[::1]:4000"] {
            #expect(Address.isLocal(URL(string: local)), "\(local)")
        }
        for other in ["https://github.com", "http://192.168.1.4:3000", "http://printer.local", "file:///tmp/a.html", "about:blank"] {
            #expect(!Address.isLocal(URL(string: other)), "\(other)")
        }
    }

    @MainActor @Test func aSignInsAnswerIsNoPageBeingMade() {
        let signedIn = URL(string: "http://localhost:1455/success")!
        // codex login: auth.openai.com's redirects end on its little server,
        // or its page sends the tab there by script.
        #expect(DevSites.sentFromAfar(page: signedIn, setOut: URL(string: "https://auth.openai.com/api/accounts/consent"), before: nil, yabSent: nil))
        #expect(DevSites.sentFromAfar(page: signedIn, setOut: signedIn, before: URL(string: "https://auth.openai.com/log-in"), yabSent: nil))
        let app = URL(string: "http://localhost:3000/")!
        // Typed over a page elsewhere, it is yours.
        #expect(!DevSites.sentFromAfar(page: app, setOut: app, before: URL(string: "https://github.com"), yabSent: "localhost:3000"))
        // Opened fresh, moved about within, or come to from yab's own page.
        #expect(!DevSites.sentFromAfar(page: app, setOut: app, before: nil, yabSent: nil))
        #expect(!DevSites.sentFromAfar(page: app, setOut: app, before: URL(string: "http://localhost:3000/cart"), yabSent: nil))
        #expect(!DevSites.sentFromAfar(page: app, setOut: app, before: URL(string: "yab://start"), yabSent: nil))
    }

    @MainActor @Test func manualModeAcceptsWebSitesWithoutMakingThemLocal() {
        for (raw, key) in [("https://example.com/a?x=1", "example.com:443"),
                           ("http://example.com/b", "example.com:80"),
                           ("https://example.com:8443/", "example.com:8443"),
                           ("http://localhost:3000/", "localhost:3000")] {
            #expect(DevSites.name(URL(string: raw)) == key)
        }
        #expect(!Address.isLocal(URL(string: "https://example.com")))
        for raw in ["file:///tmp/page.html", "about:blank", "yab://start", "javascript:alert(1)", "ftp://example.com/"] {
            #expect(DevSites.name(URL(string: raw)) == nil, "\(raw)")
        }
        #expect(DevSites.name(nil) == nil)
    }

    @MainActor @Test func theExistingCommandsToggleARemoteSiteAndFollowItsAddress() throws {
        let browser = Browser(windowID: UUID())
        let host = "dev-\(UUID().uuidString.lowercased()).example"
        let url = URL(string: "https://\(host)/first")!
        let name = try #require(DevSites.name(url))
        defer { DevSites.forget(name); browser.letGo() }
        let tab = Tab(bench: true)
        tab.restore(url: url, title: "Synthetic page")
        browser.lay([tab]); browser.activeID = tab.id
        #expect(DevSites.name(tab.address) != nil && !tab.isLocal && !tab.isDev)
        #expect(Command.devModeOn.available(in: browser))
        #expect(!Command.devModeOff.available(in: browser))
        Command.devModeOn.run(in: browser)
        #expect(tab.isDev)
        #expect(!Command.devModeOn.available(in: browser))
        #expect(Command.devModeOff.available(in: browser))
        tab.restore(url: URL(string: "https://\(host)/second")!, title: "Same site")
        #expect(tab.isDev)
        tab.restore(url: URL(string: "https://other-\(host)/")!, title: "Other site")
        #expect(!tab.isDev)
        tab.restore(url: url, title: "Returned")
        #expect(tab.isDev)
        Command.devModeOff.run(in: browser)
        #expect(!tab.isDev && DevSites.choice(url) == false)
        tab.restore(url: URL(string: "yab://start")!, title: "Internal")
        browser.toggleDevMode()
        #expect(DevSites.name(tab.address) == nil && !tab.isDev)
        #expect(!Command.devModeOn.available(in: browser))
    }

    @MainActor @Test func remoteSitesAreNeverOfferedAutomaticDeveloperMode() {
        let browser = Browser(windowID: UUID())
        let previous = browser.prefs.offerDevMode
        defer { browser.prefs.offerDevMode = previous; browser.letGo() }
        browser.prefs.offerDevMode = true
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: "https://dev-\(UUID().uuidString.lowercased()).example/")!, title: "Remote fixture")
        browser.offerDevMode(tab)
        #expect(!tab.asks.contains { $0.kind == .devMode })
        #expect(!tab.isDev)
    }

    @MainActor @Test(arguments: [false, true])
    func splitModeBelongsToThePopoverTab(local: Bool) throws {
        let browser = Browser(windowID: UUID())
        let host = "split-\(UUID().uuidString.lowercased())" + (local ? ".localhost" : ".example")
        let url = URL(string: "https://\(host)/first")!
        let name = try #require(DevSites.name(url))
        defer { DevSites.forget(name); browser.letGo() }
        let left = Tab(bench: true), right = Tab(bench: true)
        left.restore(url: url, title: "Left")
        right.restore(url: URL(string: "https://\(host)/second")!, title: "Right")
        browser.lay([left, right]); browser.activeID = left.id
        browser.pairs.append(Pair(first: left.id, second: right.id, share: 0.5))

        // The inactive half's popover still acts on that half, not the
        // active page or every page of its server.
        browser.setDevMode(right, true)
        #expect(right.isDev && !left.isDev)
        #expect(browser.activeID == left.id)
        #expect(Command.devModeOn.available(in: browser))
        #expect(!Command.devModeOff.available(in: browser))
        #expect(DevSites.servers.first { $0.name == name }?.on == true)

        Command.devModeOn.run(in: browser)
        #expect(left.isDev && right.isDev)
        browser.setDevMode(right, false)
        #expect(left.isDev && !right.isDev)
        #expect(DevSites.servers.first { $0.name == name }?.on == true)
        Command.devModeOff.run(in: browser)
        #expect(!left.isDev && !right.isDev)
        #expect(DevSites.servers.first { $0.name == name }?.on == false)
    }

    @MainActor @Test func settingsCanRememberAServerWithNoOpenTabs() throws {
        let url = URL(string: "http://settings-\(UUID().uuidString.lowercased()).localhost:3000/")!
        let name = try #require(DevSites.name(url))
        defer { DevSites.forget(name) }
        DevSites.set(name: name, false)

        // This is the real Settings setter. No browser has this host open,
        // so it passes an empty tab list, as in the reporter's video.
        Browser.setDevMode(server: name, true)
        #expect(DevSites.servers.first { $0.name == name }?.on == true)
        #expect(DevSites.choice(url) == true)
        #expect((Store.settings.dictionary(forKey: "devSites") as? [String: Bool])?[name] == true)

        let fresh = Tab(bench: true)
        fresh.restore(url: url, title: "Fresh")
        #expect(!fresh.isDev, "Remembering a server preference must not grant every new tab Developer Mode")

        Browser.setDevMode(server: name, false)
        #expect(DevSites.servers.first { $0.name == name }?.on == false)
        #expect(DevSites.choice(url) == false)
        #expect((Store.settings.dictionary(forKey: "devSites") as? [String: Bool])?[name] == false)

        Browser.setDevMode(server: name, true)
        #expect(DevSites.servers.first { $0.name == name }?.on == true)
        Browser.forgetDevMode(server: name)
        #expect(!DevSites.servers.contains { $0.name == name })
        #expect(DevSites.choice(url) == nil)
    }

    @MainActor @Test func serverPreferencesAndBulkTabChoicesStayIndependentByPort() throws {
        let host = "settings-\(UUID().uuidString.lowercased()).localhost"
        let url = URL(string: "http://\(host):3000/")!, other = URL(string: "http://\(host):4321/")!
        let name = try #require(DevSites.name(url)), otherName = try #require(DevSites.name(other))
        defer { DevSites.forget(name); DevSites.forget(otherName) }
        let first = Tab(bench: true), second = Tab(bench: true), fresh = Tab(bench: true)
        first.restore(url: url, title: "First")
        second.restore(url: url, title: "Second")
        fresh.restore(url: url, title: "Fresh")
        DevSites.set(name: otherName, true)
        DevSites.set(name: name, true, tabs: [first.id, second.id])
        #expect(first.isDev && second.isDev && !fresh.isDev)
        #expect(DevSites.servers.first { $0.name == name }?.on == true)
        #expect(DevSites.servers.first { $0.name == otherName }?.on == true)

        DevSites.set(tab: first.id, name: name, false)
        #expect(!first.isDev && second.isDev)
        #expect(DevSites.servers.first { $0.name == name }?.on == true)
        DevSites.set(name: name, false)
        #expect(!first.isDev && !second.isDev && !fresh.isDev)
        #expect(DevSites.servers.first { $0.name == name }?.on == false)
        #expect(DevSites.servers.first { $0.name == otherName }?.on == true)
    }

    @MainActor @Test func aNewTabDoesNotInheritModeButARestoredTabKeepsIt() throws {
        let browser = Browser(windowID: UUID())
        let url = URL(string: "https://tab-\(UUID().uuidString.lowercased()).example/")!
        let name = try #require(DevSites.name(url))
        defer { DevSites.forget(name); browser.letGo() }
        let original = Tab(bench: true)
        original.restore(url: url, title: "Original")
        browser.lay([original]); browser.activeID = original.id
        browser.setDevMode(original, true)
        let stored = Store.settings.dictionary(forKey: "devTabSites") as? [String: [String]]
        #expect(stored?[original.id.uuidString] == [name])

        let fresh = Tab(bench: true), restored = Tab(id: original.id, bench: true)
        fresh.restore(url: url, title: "Fresh")
        restored.restore(url: url, title: "Restored")
        #expect(!fresh.isDev)
        #expect(restored.isDev)
        browser.setDevMode(original, false)
        #expect(!restored.isDev)
    }

    @MainActor @Test func oldServerChoicesDoNotEnableEveryTab() throws {
        let url = URL(string: "https://old-\(UUID().uuidString.lowercased()).example/")!
        let name = try #require(DevSites.name(url))
        defer { DevSites.forget(name) }
        // The old version stored only a global host choice. It cannot
        // identify which of two split tabs actually asked for the mode.
        DevSites.set(name: name, true)
        let left = Tab(bench: true), right = Tab(bench: true)
        left.restore(url: url, title: "Left")
        right.restore(url: url, title: "Right")
        #expect(!left.isDev && !right.isDev)
        #expect(DevSites.choice(url) == true)
        // Settings still reflects the saved preference; it grants no tab.
        #expect(DevSites.servers.first { $0.name == name }?.on == true)
    }

    @MainActor @Test func forgettingAServerClearsOnlyThatServersTabChoices() throws {
        let browser = Browser(windowID: UUID())
        let host = "forget-\(UUID().uuidString.lowercased()).example"
        let url = URL(string: "https://\(host)/")!, other = URL(string: "https://\(host):8443/")!
        let name = try #require(DevSites.name(url)), otherName = try #require(DevSites.name(other))
        defer { DevSites.forget(name); DevSites.forget(otherName); browser.letGo() }
        let first = Tab(bench: true), second = Tab(bench: true)
        first.restore(url: url, title: "First"); second.restore(url: url, title: "Second")
        browser.setDevMode(first, true); browser.setDevMode(second, true)
        first.restore(url: other, title: "Other port"); browser.setDevMode(first, true)
        DevSites.forget(name)
        #expect(first.isDev && !second.isDev)
        first.restore(url: url, title: "Returned")
        #expect(!first.isDev)
    }

    @Test func aFrameIsSaidTheShortWay() {
        #expect(DevLog.frame("CartRow@http://localhost:3000/components/Cart.tsx:42:31", page: Self.page) == "components/Cart.tsx:42:31 · CartRow")
        #expect(DevLog.frame("@http://localhost:3000/spam.html:27:44", page: Self.page) == "spam.html:27:44")
        #expect(DevLog.frame("global code@http://localhost:3000/app.js:1:9", page: Self.page) == "app.js:1:9")
        #expect(DevLog.frame("render@https://cdn.example.com/lib.js:3:4", page: Self.page) == "https://cdn.example.com/lib.js:3:4 · render")
    }

    @Test func theFrameworksFramesStandBehind() {
        let stack = "CartRow@http://localhost:3000/Cart.tsx:42:31\nrenderWithHooks@http://localhost:3000/node_modules/react-dom/cjs/react-dom.js:1:2\nCart@http://localhost:3000/Cart.tsx:88:9"
        let (own, all) = DevLog.frames(stack)
        #expect(all.count == 3)
        #expect(own.count == 2)
    }

    @MainActor @Test func anErrorIsCopiedWithWhereAndHowOften() {
        let entry = DevLog.Entry(id: "e", level: .error, text: "TypeError: Cannot read properties of undefined (reading 'amount')",
                                 stack: "CartRow@http://localhost:3000/Cart.tsx:42:31\nCart@http://localhost:3000/Cart.tsx:88:9",
                                 source: "", count: 3, last: Date())
        let text = DevCopy.entry(entry, page: Self.page)
        #expect(text.hasPrefix("## Error on localhost:3000/cart\n"))
        #expect(text.contains("  at Cart.tsx:42:31 · CartRow\n"))
        #expect(text.contains("3 times since the page loaded"))
        #expect(!text.contains("http://localhost:3000"))
    }

    @MainActor @Test func aRequestIsCopiedWithoutItsSecrets() {
        let request = DevLog.Request(id: 1, method: "POST", url: "http://localhost:3000/api/price?token=abc123&sku=1", status: 500, ms: 184,
                                     kind: "fetch", failure: nil, requestBody: "{\"sku\":\"tote\"}",
                                     responseBody: "{\"error\":\"no price\",\"key\":\"sk-live-0123456789abcdefghij\"}",
                                     headers: ["authorization": "Bearer sk-live-0123456789abcdefghij", "cookie": "session=1", "content-type": "application/json"])
        let text = DevCopy.request(request, page: Self.page)
        #expect(text.hasPrefix("## POST /api/price?token=…&sku=1 → 500 (184 ms)\n"))
        #expect(!text.contains("abc123"))
        #expect(text.contains("authorization: [removed]"))
        #expect(text.contains("cookie: [removed]"))
        #expect(text.contains("content-type: application/json"))
        #expect(!text.contains("sk-live"))
        #expect(text.contains("Page: localhost:3000/cart\n"))
        let curl = DevCopy.curl(request)
        #expect(curl.hasPrefix("curl -X POST 'http://localhost:3000/api/price?token=…&sku=1'"))
        #expect(!curl.contains("abc123"))
        #expect(!curl.contains("authorization"))
        #expect(!curl.contains("cookie"))
        #expect(curl.contains("-H 'content-type: application/json'"))
    }

    @Test func keysAndTokensAreTakenOut() {
        #expect(DevCopy.clean("key ghp_0123456789abcdefghijklmn here") == "key [looks like a key] here")
        #expect(DevCopy.clean("AKIA0123456789ABCDEF") == "[looks like a key]")
        #expect(DevCopy.clean("/cb?code=xyz&state=1") == "/cb?code=…&state=1")
        #expect(DevCopy.clean("nothing secret") == "nothing secret")
    }

    @Test func aBatchFromThePageIsRead() {
        let json = """
        {"g":[{"k":"error|Failed row #","v":"error","n":1000000,"l":1700000000000,"t":"Failed row 0","s":"@http://localhost:3000/a.js:1:2","o":""},
              {"k":"warning|w","v":"warning","n":2,"l":1700000000000}],
         "r":[{"m":"POST","u":"http://localhost:3000/api","st":500,"ms":12,"t":1700000000123,"k":"fetch","h":{"content-type":"application/json"}},
              {"m":"GET","u":"http://localhost:3000/app.js","st":200,"ms":3,"k":"script"}],
         "x":7}
        """
        let batch = DevLog.Batch.parse(json)
        #expect(batch?.groups.count == 2)
        #expect(batch?.groups.first?.count == 1_000_000)
        #expect(batch?.groups.first?.text == "Failed row 0")
        #expect(batch?.groups.last?.text == nil)
        #expect(batch?.requests.first?.status == 500)
        // When it was sent, which tells it from others to its address in
        // WebKit's Network; none said, none kept.
        #expect(batch?.requests.first?.request(id: 1).sent == 1_700_000_000_123)
        #expect(batch?.requests.last?.request(id: 2).sent == nil)
        #expect(batch?.dropped == 7)
        #expect(DevLog.Batch.parse("not json") == nil)
    }
}
