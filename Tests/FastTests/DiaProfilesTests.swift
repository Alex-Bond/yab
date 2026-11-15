import Foundation
import SQLite3
import Testing
import WebKit
@testable import Fast

/// Dia's profiles brought in from a made-up Dia folder: each profile its own
/// space, and each profile's sign-ins only in its own store.
@MainActor
@Suite(.serialized)
struct DiaProfilesTests {
    /// A Dia folder in a temp dir: profile folders under User Data, their
    /// names in Local State, their tabs in StorableProfileContainers.json.
    private func fixture(profiles: [String: String], tabs: [String: [String]]) throws -> (root: URL, source: Chromium.Source) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("yab-dia-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("User Data", isDirectory: true)
        for folder in profiles.keys {
            let profile = data.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: profile.appendingPathComponent("Preferences"))
        }
        let cache = profiles.mapValues { ["name": $0] }
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": cache]])
            .write(to: data.appendingPathComponent("Local State"))
        func tab(_ url: String) -> [String: Any] {
            ["contents": [["variant": ["webContent": ["_0": ["url": url, "title": url]]]]]]
        }
        let containers: [[String: Any]] = tabs.keys.sorted().map { owner in
            ["id": ["profileID": owner, "container": ["window": ["_0": "W-\(owner)"]]], "tabs": tabs[owner]!.map(tab)]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "containers": containers])
            .write(to: root.appendingPathComponent("StorableProfileContainers.json"))
        let source = Chromium.Source(name: "Dia", folder: "Dia/User Data", service: "", account: "", bundle: TabImport.dia, dataRoot: data)
        return (root, source.authorizingImport())
    }

    /// A browser with one shared space on screen and nothing brought before.
    private func browser() -> (Browser, UUID) {
        let row = UUID()
        let browser = Browser(windowID: UUID())
        // The first space too, as every list read back from the file has it.
        browser.spaces = [Spaces.read()[0], Space(id: row, name: "Import test", icon: "", ownSignIns: false)]
        browser.spaceID = row
        Spaces.sharing.insert(row)
        return (browser, row)
    }

    /// `asSite`: secure and HttpOnly, as a site signing you in sets it and
    /// as the fixture's Cookies rows are (is_secure, is_httponly).
    private func cookie(_ name: String, _ domain: String, _ value: String = "synthetic", asSite: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if asSite {
            properties[.secure] = "TRUE"
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        return HTTPCookie(properties: properties)!
    }

    /// A profile's Cookies file as Chromium keeps it, its values plain.
    private func cookies(_ rows: [(name: String, value: String)], host: String, in profile: URL) throws {
        let file = profile.appendingPathComponent("Network/Cookies")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let values = rows.map { "('\(host)','\($0.name)',X'','\($0.value)','/',0,0,1,1,0)" }.joined(separator: ",")
        #expect(sqlite3_exec(db, """
        CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',24);
        CREATE TABLE cookies(host_key TEXT,name TEXT,encrypted_value BLOB,value TEXT,path TEXT,expires_utc INTEGER,has_expires INTEGER,is_secure INTEGER,is_httponly INTEGER,samesite INTEGER);
        INSERT INTO cookies VALUES \(values);
        """, nil, nil, nil) == SQLITE_OK)
    }

    @Test func twoDiaProfilesBecomeTwoSpacesWithTheirOwnSignIns() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read(), sharing = Spaces.sharing
        let (browser, row) = browser()
        let usedSpaces = browser.prefs.usesSpaces
        let (root, source) = try fixture(profiles: ["Default": "Personal", "Profile 1": "Work"],
                                         tabs: ["Default": ["https://home.test/"], "Profile 1": ["https://work.test/"]])
        defer {
            try? FileManager.default.removeItem(at: root)
            for space in browser.spaces where !space.isFirst { Session.erase(space: space.id) }
            Spaces.write(previous); Spaces.sharing = sharing
            browser.prefs.usesSpaces = usedSpaces
        }

        let places = try TabImport.places(in: source)
        #expect(places.map(\.profile) == ["Default", "Profile 1"])
        #expect(places.map(\.shared) == [true, false])

        // The welcome with spaces off and "keep spaces" not ticked: the
        // first profile into the row, the other its own space.
        let batches = Bringing.batches(places, asSpaces: false, spaces: false)
        #expect(batches.count == 2)
        for batch in batches {
            browser.bring(batch.places, withOpen: true, asSpaces: batch.asSpaces, signIns: false, from: source)
        }
        #expect(browser.prefs.usesSpaces)
        let work = try #require(browser.spaces.first { $0.origin == "Dia:Profile 1" })
        #expect(work.id != row)
        #expect(work.ownSignIns && work.signedInAs == "Dia:Profile 1")
        #expect(!Spaces.sharing.contains(work.id))
        #expect(browser.spaces.filter { !$0.isFirst }.count == 2)

        let rowPages = browser.tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString }
        #expect(rowPages == ["https://home.test/"])
        // A space of this window not on screen: the window's own file.
        #expect(Session.read(space: work.id, window: browser.windowID).tabs.map(\.url) == ["https://work.test/"])

        // Nothing more to make: both profiles have their spaces.
        #expect(browser.profileSpaces(from: source) == 0)

        // Each profile's cookies only in its own store.
        let home = cookie("home-sid", "home.test"), office = cookie("work-sid", "work.test")
        let names = TabImport.profileNames(in: source)
        let routed = browser.cookieWork(["Default": [home], "Profile 1": [office]], names: names, from: source)
        #expect(routed.count == 2)
        for (target, cookies) in routed {
            if target == nil { #expect(cookies.map(\.name) == ["home-sid"]) }
            else {
                #expect(target == work.id)
                #expect(cookies.map(\.name) == ["work-sid"])
            }
        }
        #expect(browser.spaces.filter { !$0.isFirst }.count == 2)
    }

    @Test func aProfileWithNothingToBringStillGetsItsOwnSpace() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read(), sharing = Spaces.sharing
        let (browser, _) = browser()
        let usedSpaces = browser.prefs.usesSpaces
        let (root, source) = try fixture(profiles: ["Default": "Personal", "Profile 1": "Work", "Profile 2": "Side"],
                                         tabs: ["Default": ["https://home.test/"]])
        defer {
            try? FileManager.default.removeItem(at: root)
            for space in browser.spaces where !space.isFirst { Session.erase(space: space.id) }
            Spaces.write(previous); Spaces.sharing = sharing
            browser.prefs.usesSpaces = usedSpaces
        }
        // Offered too, as profiles with no tabs.
        let places = try TabImport.places(in: source)
        #expect(places.map(\.profile) == ["Default", "Profile 1", "Profile 2"])
        #expect(places.dropFirst().allSatisfy { $0.isEmpty && $0.apart })
        #expect(browser.profileSpaces(from: source) == 2)
        let made = browser.spaces.filter { $0.signedInAs?.hasPrefix("Dia:") == true }
        #expect(Set(made.compactMap(\.signedInAs)) == ["Dia:Profile 1", "Dia:Profile 2"])
        #expect(made.allSatisfy { $0.ownSignIns })
        #expect(browser.profileSpaces(from: source) == 0)
    }

    @Test(arguments: [true, false]) func systemAndGuestProfilesNeverBecomeSpaces(_ named: Bool) throws {
        guard Store.testing else { return }
        let previous = Spaces.read(), sharing = Spaces.sharing
        let (browser, _) = browser()
        let (root, source) = try fixture(profiles: ["Default": "Personal", "Profile 1": "Work",
                                                   "System Profile": "SYSTEM_PROFILE", "Guest Profile": "Guest"], tabs: [:])
        defer {
            try? FileManager.default.removeItem(at: root)
            for space in browser.spaces where !space.isFirst { Session.erase(space: space.id) }
            Spaces.write(previous); Spaces.sharing = sharing
        }
        if !named { try FileManager.default.removeItem(at: source.root.appendingPathComponent("Local State")) }
        #expect(browser.profileSpaces(from: source) == 1)
        #expect(browser.spaces.filter { $0.signedInAs?.hasPrefix("Dia:") == true }.compactMap(\.signedInAs) == ["Dia:Profile 1"])
        #expect(browser.profileSpaces(from: source) == 0)
    }

    /// Settings' Bring In, as the welcome brings them: every profile listed,
    /// one with no window too, each its own space signed in as it was in
    /// Dia, and those spaces, found again later, still the ones signed in.
    @Test func settingsBringsEveryProfileIntoItsOwnSignedInSpace() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read(), sharing = Spaces.sharing
        let (browser, row) = browser()
        let usedSpaces = browser.prefs.usesSpaces
        let (root, source) = try fixture(profiles: ["Default": "Personal", "Profile 1": "Work", "Profile 2": "Side"],
                                         tabs: ["Default": ["https://home.test/"], "Profile 1": ["https://work.test/"]])
        defer {
            try? FileManager.default.removeItem(at: root)
            for space in browser.spaces where !space.isFirst { Session.erase(space: space.id) }
            Spaces.write(previous); Spaces.sharing = sharing
            browser.prefs.usesSpaces = usedSpaces
        }
        let places = try TabImport.places(in: source)
        let listed = places.filter { $0.comes(withOpen: false) }
        #expect(listed.map(\.name) == ["Work", "Side"])
        let side = try #require(places.last)
        #expect(TabBringer.detail(side, withOpen: true) == "No tabs")
        #expect(TabBringer.detail(side, withOpen: false) == "No tabs")
        #expect(browser.landingWords(of: side, among: places, asSpaces: true) == "new space, its own sign-ins")

        // The two of their own; Personal would go into the first space.
        // The fixture has no cookies: nothing is read, no key is asked for.
        let apart = Array(places.dropFirst())
        let took = browser.bring(apart, withOpen: true, asSpaces: true, signIns: true, from: source)
        #expect(took.spaces == 2)
        let work = try #require(browser.spaces.first { $0.origin == "Dia:Profile 1" })
        let made = try #require(browser.spaces.first { $0.origin == "Dia:Profile 2" })
        #expect(made.ownSignIns && made.signedInAs == "Dia:Profile 2" && made.name == "Side")
        #expect(Session.read(space: made.id).tabs.isEmpty)
        #expect(browser.signsIn(work.id, as: places[1], from: source))
        #expect(browser.signsIn(made.id, as: side, from: source))
        #expect(!browser.signsIn(row, as: places[0], from: source))
        #expect(browser.profileSpaces(from: source) == 0)

        // Brought again: found where they went, no space made twice.
        let again = browser.bring(apart, withOpen: true, asSpaces: true, signIns: true, from: source)
        #expect(again.spaces == 0 && again.pinned == 0 && again.open == 0)
        #expect(browser.spaces.filter { $0.signedInAs?.hasPrefix("Dia:") == true }.count == 2)
    }

    /// Settings' Bring In end to end, through the press its button makes
    /// (TabBringer.take): a Dia profile's sign-ins land in its own space's
    /// store, read from its Cookies file; brought again, the space found
    /// again takes back a cookie it lost, and a sign-in made here since
    /// stays.
    @Test func settingsBringsAProfilesSignInsIntoItsSpaceAndKeepsNewerOnes() async throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read(), sharing = Spaces.sharing
        let (browser, _) = browser()
        let usedSpaces = browser.prefs.usesSpaces
        let (root, source) = try fixture(profiles: ["Default": "Personal", "Profile 1": "Work"],
                                         tabs: ["Default": ["https://home.test/"], "Profile 1": ["https://work.test/"]])
        try cookies([("sid", "dia"), ("pref", "dark")], host: "work.test", in: source.root.appendingPathComponent("Profile 1"))
        // Dia's key, standing in: the keychain isn't asked.
        Chromium.standInKeys.withLock { $0[source.root.path] = "stand-in" }
        var made: UUID?
        defer {
            Chromium.standInKeys.withLock { $0[source.root.path] = nil }
            try? FileManager.default.removeItem(at: root)
            for space in browser.spaces where !space.isFirst { Session.erase(space: space.id) }
            if let made { Spaces.erase(made) }
            Spaces.write(previous); Spaces.sharing = sharing
            browser.prefs.usesSpaces = usedSpaces
        }
        let places = try TabImport.places(in: source)
        let work = try #require(places.first { $0.profile == "Profile 1" })
        #expect(TabBringer.take([work], withOpen: true, asSpaces: true, from: source, into: browser).spaces == 1)
        let space = try #require(browser.spaces.first { $0.origin == "Dia:Profile 1" })
        made = space.id
        #expect(space.ownSignIns && !Spaces.sharing.contains(space.id))
        let store = Spaces.store(for: space.id).httpCookieStore
        func jar() async -> [String: String] {
            let all = await store.allCookies()
            return Dictionary(all.filter { $0.domain.hasSuffix("work.test") }.map { ($0.name, $0.value) },
                              uniquingKeysWith: { first, _ in first })
        }
        // The cookies come in behind the press, off the main thread first.
        func until(_ done: ([String: String]) -> Bool) async -> [String: String] {
            for _ in 0..<100 {
                let now = await jar()
                if done(now) { return now }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return await jar()
        }
        let brought = await until { $0.count == 2 }
        #expect(brought == ["sid": "dia", "pref": "dark"])

        // Signed in here since, and a cookie gone: brought again. Set as
        // the site would, secure and HttpOnly like the one brought: WebKit
        // keeps such a cookie from being replaced by a plain one of the same
        // name, so a plain one here was dropped and the jar still said "dia".
        await store.setCookie(cookie("sid", "work.test", "yab", asSite: true))
        for gone in await store.allCookies() where gone.name == "pref" { await store.deleteCookie(gone) }
        let before = await jar()
        #expect(before == ["sid": "yab"])
        #expect(TabBringer.take([work], withOpen: true, asSpaces: true, from: source, into: browser).spaces == 0)
        let again = await until { $0["pref"] != nil }
        #expect(again == ["sid": "yab", "pref": "dark"])
    }

    /// One place with tabs comes at once; a profile with none is listed
    /// first, as are several.
    @Test func onlyAPlaceWithTabsComesWithoutAList() {
        let entry = TabImport.Entry(url: URL(string: "https://work.test/")!, title: "Work")
        let home = TabImport.Place(id: "Chrome:Default", name: "Personal", profile: "Default", shared: true, isProfile: true, pinned: [], open: [entry])
        let work = TabImport.Place(id: "Chrome:Profile 1", name: "Work", profile: "Profile 1", shared: false, isProfile: true, pinned: [entry], open: [])
        let side = TabImport.Place(id: "Chrome:Profile 2", name: "Side", profile: "Profile 2", shared: false, isProfile: true, pinned: [], open: [])
        #expect(TabBringer.atOnce([work], withOpen: false))
        #expect(TabBringer.atOnce([home, work], withOpen: false))
        #expect(!TabBringer.atOnce([home, work], withOpen: true))
        #expect(!TabBringer.atOnce([side], withOpen: true))
        #expect(!TabBringer.atOnce([home, side], withOpen: false))
        #expect(!TabBringer.atOnce([work, side], withOpen: false))
    }

    /// A sign-in made here since stays: only cookies a store holds none of
    /// by name, domain and path go in.
    @Test func cookiesAStoreHoldsAlreadyStay() {
        final class Jar {}
        let a = Jar(), b = Jar()
        let held = [ObjectIdentifier(a): Set([Browser.cookieKey(cookie("sid", "work.test"))])]
        let work = [(a, cookie("sid", "Work.test")), (a, cookie("pref", "work.test")), (b, cookie("sid", "work.test"))]
        let left = Browser.unset(work, held: held)
        #expect(left.map { ($0.0 === a ? "a:" : "b:") + $0.1.name } == ["a:pref", "b:sid"])
    }

    @Test func aSpaceSignedInAsAnotherBrowsersProfileIsNotReused() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read(), sharing = Spaces.sharing
        let (browser, _) = browser()
        defer { Spaces.write(previous); Spaces.sharing = sharing }
        var arc = Space(id: UUID(), name: "Work", icon: "", ownSignIns: true)
        arc.signedInAs = "Arc:Profile 1"
        browser.spaces.append(arc)
        let entry = TabImport.Entry(url: URL(string: "https://work.test/")!, title: "Work")
        let home = TabImport.Place(id: "Dia:Default", name: "Personal", profile: "Default", shared: true, isProfile: true, pinned: [entry], open: [])
        let work = TabImport.Place(id: "Dia:Profile 1", name: "Work", profile: "Profile 1", shared: false, isProfile: true, pinned: [entry], open: [])
        #expect(work.signIn == "Dia:Profile 1")
        #expect(browser.landing(of: work, among: [home, work], asSpaces: true) == .new)
        arc.signedInAs = nil
        browser.spaces[browser.spaces.count - 1] = arc
        #expect(browser.landing(of: work, among: [home, work], asSpaces: true) == .space(arc.id))
    }
}
