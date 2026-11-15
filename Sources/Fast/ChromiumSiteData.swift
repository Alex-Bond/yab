import Foundation
import WebKit
import YabCoreClient

/// What Clear Data, Sign Out and Clear History do to Chromium's side of a
/// sign-in. Chromium's Settings page is the one way in to its removal, so a
/// hidden management tab runs it: every store Chromium clears, cleared as Chromium
/// clears it. Nothing here starts Chromium for a sign-in that never used it.
@MainActor
enum ChromiumSiteData {
    /// Chromium's own names for what its Clear Browsing Data takes.
    enum Kind: String, CaseIterable {
        case history = "browser.clear_data.browsing_history"
        case downloads = "browser.clear_data.download_history"
        case cache = "browser.clear_data.cache"
        case cookies = "browser.clear_data.cookies"
        case forms = "browser.clear_data.form_data"
    }

    /// Every sign-in with Chromium data on this Mac: the shared one and each
    /// space's own, each once.
    static var stores: [WKWebsiteDataStore] {
        var seen = Set<ObjectIdentifier>()
        return ([Store.websites] + Spaces.read().filter(\.ownSignIns).map { Spaces.store(for: $0.id) })
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private static func profile(of store: WKWebsiteDataStore) -> String? {
        guard store.isPersistent else { return nil }
        let profile = ChromiumPersistentProfiles.profile(store: store, placement: Space.firstID)
        let folder = Store.file("Chromium").appendingPathComponent("space-" + profile)
        return FileManager.default.fileExists(atPath: folder.path) ? profile : nil
    }

    /// A whole sign-in's history, cache or cookies and site data, in each
    /// store. True when nothing was left behind.
    /// A --test run's way to see what follows when Chromium can't clear.
    static var failsForTesting = false

    @discardableResult
    static func clear(_ kinds: Set<Kind>, in chosen: [WKWebsiteDataStore]? = nil,
                      failed: (WKWebsiteDataStore) -> Void = { _ in }) async -> Bool {
        var whole = true
        for store in chosen ?? stores {
            guard let profile = profile(of: store) else { continue }
            do {
                if Store.testing, failsForTesting { throw YabCoreError.remote("failing for the test") }
                try await removing(kinds, profile: profile, store: store)
            }
            catch {
                whole = false
                failed(store)
                DebugLog.note("chromium-clear", ["error": String(describing: error)])
            }
        }
        return whole
    }

    /// One site, its subdomains included: cookies, storage, service workers
    /// and what Chromium keeps for it. The cache goes whole, as Chromium has
    /// no way to take one site's out; other sites keep their sign-ins.
    @discardableResult
    static func forget(site: String, store: WKWebsiteDataStore, page: ChromiumPage? = nil, address: URL? = nil) async -> Bool {
        guard store.isPersistent else { return await forgetPrivately(site: site, store: store, page: page, address: address) }
        guard let profile = profile(of: store) else { return true }
        do {
            if Store.testing, failsForTesting { throw YabCoreError.remote("failing for the test") }
            try await withSettings(profile: profile, store: store, page: "content/all") { core, tab in
                try await finish(core, tab: tab, script: forgetScript(site))
                // Chrome's site list can leave a cookie partitioned under the
                // site by another (an embed's): those go by name too, and a
                // second read of the jar proves none is left.
                let gone = try await core.request("site.cookies.clear", params: ["tab": .string(tab), "site": .string(site)])
                if let left = gone["left"].number, left > 0 { throw YabCoreError.remote("Chromium kept \(Int(left)) cookies of the site") }
            }
            try await removing([.cache], profile: profile, store: store)
            return true
        } catch {
            DebugLog.note("chromium-forget", ["error": String(describing: error)])
            return false
        }
    }

    /// One site's cookies and nothing else (Clear Cookies and Refresh), on the
    /// Chromium page showing it. With the page on WebKit the cookie bridge
    /// carries the deletion over, as it carries a sign-out.
    @discardableResult
    static func clearCookies(site: String, page: ChromiumPage?) async -> Bool {
        guard let page, let remote = page.remoteID else { return true }
        do {
            let core = try await ChromiumProcess.shared.connection()
            _ = try await core.request("site.cookies.clear", params: ["tab": .string(remote), "site": .string(site)])
            return true
        } catch {
            DebugLog.note("chromium-cookies", ["error": String(describing: error)])
            return false
        }
    }

    /// A private page has no Settings page: the site's cookies and its
    /// origins' storage, on a page of the window's Chromium profile. The tab
    /// asked from may be on WebKit now, after a sign-in on Chromium: then any
    /// other Chromium page of that profile, or a hidden one. The rest ends
    /// with the window. A helper that isn't running holds nothing private.
    private static func forgetPrivately(site: String, store: WKWebsiteDataStore, page: ChromiumPage?, address: URL?) async -> Bool {
        guard let core = ChromiumProcess.shared.connectedClient,
              let profile = page?.profile ?? ChromiumPrivateProfiles.existing(for: store) else { return true }
        let origins = privateOrigins(site: site, shown: [page?.url, address])
        var hidden: ChromiumHiddenPage?
        defer { hidden?.close() }
        do {
            let remote: String
            if let id = page?.remoteID {
                remote = id
            } else {
                // A document of the profile's own, so DevTools is there to ask.
                try await ChromiumPrivateProfiles.open(profile, privateMode: true, core: core)
                let made = try await ChromiumHiddenPage(core: core, profile: profile)
                hidden = made
                guard let first = origins.first.flatMap(URL.init(string:)) else { return true }
                let wanted = EngineStorageCarry.origin(of: first)
                try await made.show(where: { EngineStorageCarry.origin(of: $0) == wanted }) { core, id in
                    _ = try await core.request("tab.loadHTML", params: ["tab": .string(id), "url": .string(first.absoluteString + "/"),
                                                                        "html": .string("<!doctype html><title></title>")])
                }
                remote = made.tab
            }
            _ = try await core.request("site.cookies.clear", params: ["tab": .string(remote), "site": .string(site)])
            for origin in origins {
                _ = try await core.request("site.origin.clear", params: ["tab": .string(remote), "origin": .string(origin)])
            }
            return true
        } catch {
            DebugLog.note("chromium-forget", ["error": String(describing: error)])
            return false
        }
    }

    /// The origins a private profile may keep for a site: what the tabs
    /// show, and its bare and www names on both schemes.
    nonisolated static func privateOrigins(site: String, shown: [URL?]) -> [String] {
        let named = ["https://", "http://"].flatMap { [$0 + site, $0 + "www." + site] }
        var out: [String] = []
        for origin in shown.compactMap({ $0.flatMap(Self.origin) }) + named {
            guard let host = URL(string: origin)?.host?.lowercased(), host == site || host.hasSuffix("." + site),
                  !out.contains(origin) else { continue }
            out.append(origin)
        }
        return out
    }

    nonisolated private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }

    private static func removing(_ kinds: Set<Kind>, profile: String, store: WKWebsiteDataStore) async throws {
        try await run(profile: profile, store: store, page: "clearBrowserData", script: clearScript(kinds), forgetUse: kinds.contains(.history))
    }

    private static func withSettings(profile: String, store: WKWebsiteDataStore, page: String,
                                     _ work: (YabCoreClient, String) async throws -> Void) async throws {
        try ChromiumPersistentProfiles.authorize(profile, store: store)
        let core = try await ChromiumProcess.shared.connection()
        try await core.openProfile(profile)
        let created = try await core.request("settings.open", params: ["profile": .string(profile), "page": .string(page)])
        guard let tab = created["tab"].string else { throw YabCoreError.protocolViolation("Missing settings tab") }
        do {
            _ = try await core.waitForDocument(tab: tab, profile: profile, url: "chrome://settings/" + page)
            try await work(core, tab)
            try? await core.closeTab(tab)
        } catch {
            try? await core.closeTab(tab)
            throw error
        }
    }

    /// The script starts the work and leaves its answer in the page: a large
    /// profile takes longer than one DevTools call may wait.
    private static func run(profile: String, store: WKWebsiteDataStore, page: String, script: String, forgetUse: Bool = false) async throws {
        try await withSettings(profile: profile, store: store, page: page) { core, tab in
            try await finish(core, tab: tab, script: script, forgetUse: forgetUse)
        }
    }

    private static func finish(_ core: YabCoreClient, tab: String, script: String, forgetUse: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(120)
        var sent = Date.distantPast
        while Date() < deadline {
            // The first Settings page of a session can lose the answer with
            // the data already gone: asked again, it answers at once.
            if Date().timeIntervalSince(sent) > 10 {
                if sent != .distantPast { DebugLog.note("chromium-clear", ["error": "asked again"]) }
                _ = try await core.request("settings.run", params: ["tab": .string(tab), "script": .string(script)])
                sent = Date()
            }
            let state = try await core.request("settings.run", params: ["tab": .string(tab), "script": .string("window.__yabDone ?? null")])
            if let error = state["value"]["error"].string { throw YabCoreError.remote(error) }
            if state["value"]["ok"] == .bool(true) {
                if forgetUse { _ = try await core.request("settings.forgetUse", params: ["tab": .string(tab)]) }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw YabCoreError.remote("Chromium did not finish clearing")
    }

    /// Settings' WebUI answers `cr.webUIResponse` and `cr.webUIListenerCallback`.
    private static let prelude = """
    const settled = async () => { for (let i = 0; i < 400 && !(window.cr && cr.webUIResponse); i++) await new Promise(o => setTimeout(o, 25)); };
    const ask = (name, ...args) => new Promise((done, fail) => {
      const id = 'yab-' + name + Math.random(), old = cr.webUIResponse;
      cr.webUIResponse = (key, ok, value) => { if (key !== id) { old(key, ok, value); return; } cr.webUIResponse = old; ok ? done(value) : fail(new Error(String(value))); };
      chrome.send(name, [id, ...args]);
    });
    const heard = name => new Promise(done => {
      const old = cr.webUIListenerCallback;
      cr.webUIListenerCallback = (event, ...values) => { if (event !== name) { old(event, ...values); return; } cr.webUIListenerCallback = old; done(values[0]); };
    });
    """

    private static func clearScript(_ kinds: Set<Kind>) -> String {
        let names = kinds.map(\.rawValue).sorted().map { "'\($0)'" }.joined(separator: ",")
        return """
        (() => { \(prelude)
        window.__yabDone = null;
        (async () => {
          try {
            await settled();
            await ask('initializeClearBrowsingData');
            // All time, as WebKit's removal since the distant past.
            await ask('clearBrowsingData', [\(names)], 4);
            window.__yabDone = {ok: true};
          } catch (error) { window.__yabDone = {error: String(error)}; }
        })();
        return true; })()
        """
    }

    private static func forgetScript(_ site: String) -> String {
        let name = String(data: (try? JSONEncoder().encode(site)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        return """
        (() => { \(prelude)
        const site = \(name);
        const theirs = list => (list || []).filter(group => (group.origins || []).some(row => {
          let host = ''; try { host = new URL(row.origin).hostname; } catch (error) {}
          return host === site || host.endsWith('.' + site);
        }) || group.etldPlus1 === site);
        const sites = async () => { const list = heard('onStorageListFetched'); await ask('getAllSites'); return list; };
        window.__yabDone = null;
        (async () => {
          try {
            await settled();
            for (let turn = 0; turn < 20; turn++) {
              const kept = theirs(await sites()).filter(group => group.numCookies > 0 || (group.origins || []).some(row => row.usage > 0 || row.numCookies > 0));
              if (!kept.length) { window.__yabDone = {ok: true}; return; }
              for (const group of kept) chrome.send('clearSiteGroupDataAndCookies', [group.groupingKey]);
              await new Promise(o => setTimeout(o, 200));
            }
            window.__yabDone = {error: 'Chromium kept this site after clearing'};
          } catch (error) { window.__yabDone = {error: String(error)}; }
        })();
        return true; })()
        """
    }
}
