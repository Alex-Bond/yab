import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// A normal Little Arc guest and the main row have different, real stores.
/// The loopback SERP waits for the test, so source changes happen before
/// resolution rather than racing an arbitrary sleep or external website.
/// Focus cases require the NSApplication.run host in evals/instant-links/native_guest.py.
@MainActor
@Suite(.serialized)
struct InstantLinksGuestTests {
    @MainActor private final class World {
        let server: LocalNetworkFixture
        let browser: Browser
        let a = Space(id: UUID(), name: "Instant main fixture", icon: "A", ownSignIns: true)
        let b = Space(id: UUID(), name: "Instant guest fixture", icon: "B", ownSignIns: true)
        let shell: NSWindow
        var link: LinkWindow?
        var main: Tab!
        var guest: Tab { link!.tab }
        var storeA: WKWebsiteDataStore { Spaces.store(for: a.id) }
        var storeB: WKWebsiteDataStore { Spaces.store(for: b.id) }
        let previousWindow = Links.window
        let previousCurrent = Spaces.current
        let previousPolicy = NSApplication.shared.activationPolicy()
        let previousSpaces = Store.settings.object(forKey: "spaces")
        let previousList = try? Data(contentsOf: Store.file("spaces.json"))
        let saved: [String: Any?]

        init() throws {
            try #require(Store.testing, "Run this fixture through the test-world farm command")
            try #require(BrowserWindows.shared.activeWindow == nil,
                         "The focus fixture requires its own browser window")
            server = try LocalNetworkFixture()
            saved = Dictionary(uniqueKeysWithValues: ["field.instant", "instant.fixtureTemplate", Engine.key,
                "search.suggest", "dev.offer"].map { ($0, Store.settings.object(forKey: $0)) })
            browser = Browser(windowID: UUID())
            shell = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            shell.isReleasedWhenClosed = false
            shell.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
            shell.orderBack(nil)
            Links.window = shell
            browser.prefs.usesSpaces = true
            browser.prefs.instantLinks = true
            browser.prefs.searchSuggest = false
            browser.prefs.offerDevMode = false
            browser.prefs.engine = .google
            browser.spaces.append(contentsOf: [a, b])
            Spaces.sharing.subtract([a.id, b.id])
            browser.switchSpace(to: a.id)
            Store.settings.set(server.root + "/search?q=%s", forKey: "instant.fixtureTemplate")
            for (path, title) in [("/main", "Main original"), ("/main-next", "Main next"),
                                  ("/guest", "Guest original"), ("/guest-next", "Guest next"),
                                  ("/result", "Guest result")] {
                server.route(path, .init("<!doctype html><title>\(title)</title><h1>\(title)</h1>"))
            }
            server.route("/gate", .init("hold"))
            // Different host, same owned endpoint: it is a destination, not
            // the search engine's own link, and has no external dependency.
            let result = "http://localhost:\(server.port)/result"
            server.route("/search", .init("""
                <!doctype html><div id="search"></div><script>
                const timer = setInterval(async () => {
                  if ((await (await fetch('/gate?t='+Date.now())).text()) !== 'ready') return;
                  clearInterval(timer);
                  document.querySelector('#search').innerHTML = '<a href="\(result)"><h3>Owned result</h3></a>';
                }, 50);
                </script>
                """))
        }

        func url(_ path: String) -> URL { URL(string: server.root + path)! }
        func state(_ phase: String) -> String {
            // Only fixture state: no request headers, cookies, external URLs,
            // or unrelated window titles leave this test.
            let state: [String: Any] = [
                "phase": phase, "appRunning": NSApp.isRunning, "appActive": NSApp.isActive,
                "activationPolicy": NSApp.activationPolicy().rawValue,
                "keyWindow": NSApp.keyWindow == nil ? "none" : NSApp.keyWindow === shell ? "main"
                    : NSApp.keyWindow === link?.window ? "guest" : "other",
                "frontmostIsTest": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "mainVisible": shell.isVisible, "mainKey": shell.isKeyWindow,
                "mainCanBecomeKey": shell.canBecomeKey,
                "guestVisible": link?.window.isVisible ?? false, "guestKey": link?.window.isKeyWindow ?? false,
                "guestCanBecomeKey": link?.window.canBecomeKey ?? false,
                "mainPath": main?.address?.path ?? "none", "mainLoading": main?.loading ?? false,
                "guestPath": link?.tab.address?.path ?? "none", "guestLoading": link?.tab.loading ?? false,
                "mainSpace": browser.spaceID == a.id, "mainSelected": browser.active === main,
                "searchRequests": server.requests.filter { $0.path.hasPrefix("/search?") }.count,
                "resultRequests": server.requests.filter { $0.path == "/result" }.count
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), encoding: .utf8)!
        }
        func until(_ phase: String, _ test: () -> Bool) async throws {
            let end = Date().addingTimeInterval(12)
            while !test(), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
            let settled = test()
            if !settled { print("INSTANT_GUEST_TIMEOUT " + state(phase)) }
            try #require(settled, Comment(rawValue: state(phase)))
        }
        func activateGuest() async throws {
            print("INSTANT_GUEST_FOCUS_HOST " + state("before-activation"))
            try #require(NSApp.isRunning,
                         "Native focus needs NSApplication.run; use evals/instant-links/native_guest.py, not ordinary swift test")
            let before = NSApp.activationPolicy()
            let policySet: Bool? = before == .regular ? nil : NSApp.setActivationPolicy(.regular)
            let action = policySet.map { "setter-result=\($0)" } ?? "already-regular setter=not-called"
            print("INSTANT_GUEST_ACTIVATION_POLICY before=\(before.rawValue) \(action) " + state("regular-policy"))
            try #require(NSApp.activationPolicy() == .regular, "The native test host must permit activation")
            NSApp.activate(ignoringOtherApps: true)
            link!.window.makeKeyAndOrderFront(nil)
            try await until("guest-active-and-key") { NSApp.isActive && self.link!.window.isKeyWindow }
            print("INSTANT_GUEST_FOCUS_READY " + state("guest-active-and-key"))
        }
        func start() async throws {
            try #require(storeA !== storeB)
            await storeA.httpCookieStore.setCookie(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                .name: "instant_fixture", .value: "space-a"])!)
            await storeB.httpCookieStore.setCookie(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                .name: "instant_fixture", .value: "space-b"])!)
            main = browser.open(url("/main"), foreground: true)
            LinkWindow.show(url("/guest"), for: browser, home: b.id)
            link = try #require(LinkWindow.all.last { $0.tab.store === storeB })
            link!.window.setFrameOrigin(NSPoint(x: -30000, y: 0))
            try await until("source-pages-loaded") { self.main.title == "Main original" && self.guest.title == "Guest original"
                && !self.main.loading && !self.guest.loading }
        }
        func submit() async throws -> (Tab, Task<Void, Never>) {
            browser.edit(over: guest, in: link!.window)
            browser.typed = "instant guest fixture"
            try #require(browser.submitInstant())
            let tab = try #require(browser.parked[b.id]?.tabs.first { $0.instantState == .searching })
            #expect(tab.store === storeB)
            #expect(tab.store !== storeA)
            #expect(browser.spaceID == a.id)
            #expect(browser.active === main)
            #expect(main.address == url("/main"))
            let task = try #require(tab.instantTask)
            try await until("search-request-received") { self.server.requests.contains { $0.path.hasPrefix("/search?") } }
            let request = try #require(server.requests.first { $0.path.hasPrefix("/search?") })
            #expect(request.headers.contains("instant_fixture=space-b"))
            #expect(!request.headers.contains("instant_fixture=space-a"))
            return (tab, task)
        }
        func release() { server.route("/gate", .init("ready")) }
        func close() {
            link?.window.close()
            link?.window.contentView = nil
            browser.letGo()
            shell.close()
            shell.contentView = nil
            Links.window = previousWindow
            NSApp.setActivationPolicy(previousPolicy)
            Spaces.current = previousCurrent
            Store.settings.set(previousSpaces, forKey: "spaces")
            if let previousList { try? previousList.write(to: Store.file("spaces.json")) }
            for (key, value) in saved { Store.settings.set(value, forKey: key) }
            for id in [a.id, b.id] {
                Spaces.sharing.remove(id)
                Spaces.erase(id)
            }
            if let window = browser.windowID {
                for space in browser.spaces {
                    let suffix = space.id == Space.firstID ? "" : "-\(space.id.uuidString)"
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString)\(suffix).json"))
                }
                Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
            }
            server.stop()
        }
    }

    @Test func guestResultsKeepTheirStoreWithoutTakingTheChangedMainPage() async throws {
        let world = try World()
        defer { world.close() }
        try await world.start()
        let (result, task) = try await world.submit()
        world.main.go(to: world.url("/main-next"))
        world.shell.makeKeyAndOrderFront(nil)
        world.release()
        await task.value
        try await world.until("result-loaded-main-changed") { result.title == "Guest result" && !result.loading }
        #expect(result.address?.path == "/result")
        #expect(result.store === world.storeB)
        #expect(world.browser.parked[world.b.id]?.tabs.contains { $0 === result } == true)
        #expect(world.browser.spaceID == world.a.id && world.browser.active === world.main)
        #expect(world.main.address == world.url("/main-next"))
        #expect(world.guest.address == world.url("/guest"))
        let cookies = await result.store.httpCookieStore.allCookies()
        #expect(cookies.contains { $0.name == "instant_fixture" && $0.value == "space-b" })
        #expect(!cookies.contains { $0.name == "instant_fixture" && $0.value == "space-a" })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_NATIVE_TEST_HOST"] == "1"))
    func guestDoesNotRevealWhenOnlyFocusMoved() async throws {
        let world = try World()
        defer { world.close() }
        try await world.start()
        try await world.activateGuest()
        let (result, task) = try await world.submit()
        world.shell.makeKeyAndOrderFront(nil)
        try await world.until("main-takes-key") { world.shell.isKeyWindow }
        print("INSTANT_GUEST_FOCUS_MOVED " + world.state("main-takes-key"))
        world.release()
        await task.value
        try await world.until("result-loaded-focus-moved") { result.title == "Guest result" && !result.loading }
        #expect(world.browser.spaceID == world.a.id && world.browser.active === world.main)
        #expect(NSApp.keyWindow === world.shell)
        #expect(world.main.address == world.url("/main"))
        #expect(world.guest.address == world.url("/guest"))
        #expect(result.store === world.storeB)
    }

    @Test func guestNavigationInvalidatesThePendingResult() async throws {
        let world = try World()
        defer { world.close() }
        try await world.start()
        let (result, task) = try await world.submit()
        world.guest.go(to: world.url("/guest-next"))
        try await world.until("guest-navigated") { world.guest.title == "Guest next" && !world.guest.loading }
        world.release()
        await task.value
        #expect(result.gone)
        #expect(!world.server.requests.contains { $0.path == "/result" })
        #expect(world.browser.spaceID == world.a.id && world.browser.active === world.main)
        #expect(world.main.address == world.url("/main"))
        #expect(world.guest.address == world.url("/guest-next"))
    }

    @Test func guestCloseInvalidatesThePendingResult() async throws {
        let world = try World()
        defer { world.close() }
        try await world.start()
        let (result, task) = try await world.submit()
        world.link!.window.close()
        world.release()
        await task.value
        #expect(result.gone)
        #expect(!world.server.requests.contains { $0.path == "/result" })
        #expect(world.browser.spaceID == world.a.id && world.browser.active === world.main)
        #expect(world.main.address == world.url("/main"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_NATIVE_TEST_HOST"] == "1"))
    func unchangedGuestMayRevealItsResultInTheMatchingSpace() async throws {
        let world = try World()
        defer { world.close() }
        try await world.start()
        try await world.activateGuest()
        let (result, task) = try await world.submit()
        world.release()
        await task.value
        try await world.until("result-loaded-guest-unchanged") { result.title == "Guest result" && !result.loading }
        #expect(world.browser.spaceID == world.b.id && world.browser.active === result)
        #expect(result.store === world.storeB)
        #expect(world.main.address == world.url("/main"))
        #expect(world.guest.address == world.url("/guest"))
    }
}
