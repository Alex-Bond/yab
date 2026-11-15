import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// A real native tab id must survive moving before its old window closes,
/// even when the row's debounced notification has not run yet.
@MainActor
@Suite(.serialized)
struct ExtensionMovedTabIdentityTests {
    private static func page(_ name: String) -> URL {
        URL(string: "http://127.0.0.1:9/\(name)")!
    }

    private func call(_ web: WKWebView, _ body: String) async throws -> [String: Any] {
        let value = try await web.callAsyncJavaScript(body, contentWorld: .page)
        let text = try #require(value as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func nativeTabIDSurvivesImmediateSourceWindowClose() async throws {
        try #require(Store.testing)
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moved-tab-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Moved tab identity","version":"1.0","permissions":["tabs"],"host_permissions":["http://127.0.0.1/*"]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>probe</title>".write(to: folder.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        // Use the production owner's own controller: an unrelated test
        // controller would not receive unfollow's actual didCloseTab call.
        let signIn = UUID()
        let owner = Extensions(signIn: signIn)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.baseURL = try #require(URL(string: "\(Extensions.scheme)://moved\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))/"))
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*"))
        try owner.controller.load(context)
        defer { try? owner.controller.unload(context) }
        let source = Browser(windowID: UUID()), destination = Browser(windowID: UUID())
        owner.follow(source)
        owner.follow(destination)
        defer {
            owner.unfollow(source)
            owner.unfollow(destination)
            source.letGo()
            destination.letGo()
            for browser in [source, destination] {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
            }
        }
        try #require(source.spaceID == destination.spaceID)
        try #require(BrowserWindows.shared.window(for: source) == nil)
        try #require(BrowserWindows.shared.window(for: destination) == nil)

        func tab(_ name: String, in browser: Browser) throws -> Tab {
            // The context configuration only permits its extension's own URLs.
            // Ordinary pages use web configuration with the same store and controller.
            let configuration = Web.configuration(store: owner.store, extensions: false)
            configuration.webExtensionController = owner.controller
            let tab = Tab(configuration: configuration, factory: .webKitOnly)
            browser.prepare(tab)
            // Load an ordinary HTTP document without a server or external request.
            requireNativeWebKitFixture(tab, "ExtensionMovedTabIdentityTests").loadHTMLString("<!doctype html><title>\(name)</title>", baseURL: Self.page(name))
            return tab
        }
        let moved = try tab("moved", in: source)
        let closing = try tab("closing", in: source)
        let sibling = try tab("sibling", in: destination)
        source.lay([moved, closing])
        destination.lay([sibling])
        source.activeID = moved.id
        destination.activeID = sibling.id
        owner.browser = source
        let sourceWindow = try #require(owner.window(of: moved))
        let destinationWindow = try #require(owner.window(of: sibling))
        owner.controller.didFocusWindow(sourceWindow)
        let movedView = requireNativeWebKitFixture(moved, "ExtensionMovedTabIdentityTests")
        let movedAdapter = owner.adapter(for: moved)
        let probe = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: try #require(context.webViewConfiguration))
        defer { probe.stopLoading() }
        probe.load(URLRequest(url: context.baseURL.appendingPathComponent("probe.html")))
        let targets = [("moved", moved, source), ("closing", closing, source), ("sibling", sibling, destination)]
        func state() -> [[String: Any]] {
            targets.map { name, tab, browser in
                ["name": name, "tabID": tab.id.uuidString,
                 "inExpectedRow": browser.tabs.filter { $0 === tab }.count == 1,
                 "active": browser.active === tab,
                 "controllerMatches": tab.built?.configuration.webExtensionController === owner.controller,
                 "storeMatches": tab.built?.configuration.websiteDataStore === owner.store,
                 "storeID": tab.built?.configuration.websiteDataStore.identifier?.uuidString ?? "",
                 "loadedURL": tab.built?.url?.absoluteString ?? "", "expectedURL": Self.page(name).absoluteString,
                 "address": tab.address?.absoluteString ?? "", "loading": tab.loading,
                 "toldWindow": owner.told(tab)?.uuidString ?? "", "expectedWindow": browser.windowID!.uuidString]
            }
        }
        let ready = try await Loaded.until(10) {
            let ready = (try? await probe.evaluateJavaScript("location.pathname === '/probe.html' && document.readyState === 'complete' && !!chrome.tabs")) as? Bool == true
            return ready && owner.signIn == signIn && owner.store.identifier == signIn
                && probe.configuration.websiteDataStore.identifier == signIn
                && probe.configuration.webExtensionController === owner.controller
                && targets.allSatisfy { name, tab, browser in
                browser.tabs.filter { $0 === tab }.count == 1
                    && tab.built?.configuration.webExtensionController === owner.controller
                    && tab.built?.configuration.websiteDataStore.identifier == signIn
                    && tab.built?.url == Self.page(name) && tab.address == Self.page(name) && !tab.loading
                    && owner.told(tab) == browser.windowID
            }
                && owner.front === source && source.active === moved && destination.active === sibling
                && sourceWindow.tabs(for: context).count == 2 && destinationWindow.tabs(for: context).count == 1
        }
        print("EXTENSION_MOVED_TAB_FIXTURE " + String(decoding: try JSONSerialization.data(withJSONObject: [
            "ready": ready, "targets": state(), "expectedStoreID": signIn.uuidString,
            "ownerStoreID": owner.store.identifier?.uuidString ?? "",
            "probeStoreMatches": probe.configuration.websiteDataStore === owner.store,
            "probeStoreID": probe.configuration.websiteDataStore.identifier?.uuidString ?? "",
            "probeControllerMatches": probe.configuration.webExtensionController === owner.controller,
            "sourceIsFront": owner.front === source,
            "sourceTabCount": sourceWindow.tabs(for: context).count,
            "destinationTabCount": destinationWindow.tabs(for: context).count
        ], options: [.sortedKeys]), as: UTF8.self))
        try #require(ready)
        let before = try await call(probe, """
            const tabs = await chrome.tabs.query({});
            return JSON.stringify({tabs: tabs.map(t => ({id:t.id, windowId:t.windowId, url:t.url}))});
            """)
        print("EXTENSION_MOVED_TAB_BEFORE " + String(decoding: try JSONSerialization.data(withJSONObject: ["before": before, "targets": state()], options: [.sortedKeys]), as: UTF8.self))
        let rows = try #require(before["tabs"] as? [[String: Any]])
        func row(_ name: String) throws -> [String: Any] {
            try #require(rows.first { $0["url"] as? String == Self.page(name).absoluteString })
        }
        let old = try row("moved"), closed = try row("closing"), kept = try row("sibling")
        let oldID = try #require(old["id"] as? Int)
        let closedID = try #require(closed["id"] as? Int)
        let siblingID = try #require(kept["id"] as? Int)
        let sourceID = try #require(old["windowId"] as? Int)
        let destinationID = try #require(kept["windowId"] as? Int)
        try #require(Set([oldID, closedID, siblingID]).count == 3)
        try #require(sourceID != destinationID && (closed["windowId"] as? Int) == sourceID)

        // No await between the real move and the production window-close
        // hook: the 60ms row delivery cannot run between these two calls.
        try #require(BrowserWindows.shared.move(moved, from: source, to: destination, announce: false))
        owner.unfollow(source)
        try #require(try await Loaded.until(5) { owner.told(moved) == destination.windowID })

        let after = try await call(probe, """
            const out = {};
            try { const t = await chrome.tabs.get(\(oldID)); out.moved = {id:t.id, windowId:t.windowId, url:t.url}; }
            catch (e) { out.movedError = String(e); }
            try { await chrome.tabs.get(\(closedID)); out.closedFound = true; }
            catch (e) { out.closedFound = false; }
            try { const t = await chrome.tabs.get(\(siblingID)); out.sibling = {id:t.id, windowId:t.windowId, url:t.url}; }
            catch (e) { out.siblingError = String(e); }
            out.tabs = (await chrome.tabs.query({})).map(t => ({id:t.id, windowId:t.windowId, url:t.url}));
            return JSON.stringify(out);
            """)
        print("EXTENSION_MOVED_TAB_NATIVE " + String(decoding: try JSONSerialization.data(withJSONObject: ["before": before, "after": after, "movedID": oldID, "closedID": closedID, "siblingID": siblingID, "sourceWindowID": sourceID, "destinationWindowID": destinationID], options: [.sortedKeys]), as: UTF8.self))
        let actual = after["moved"] as? [String: Any]
        #expect(after["movedError"] == nil)
        #expect(actual?["id"] as? Int == oldID)
        #expect(actual?["windowId"] as? Int == destinationID)
        #expect(actual?["url"] as? String == Self.page("moved").absoluteString)
        #expect(after["closedFound"] as? Bool == false)
        let still = after["sibling"] as? [String: Any]
        #expect(after["siblingError"] == nil)
        #expect(still?["id"] as? Int == siblingID)
        #expect(still?["windowId"] as? Int == destinationID)
        let remaining = try #require(after["tabs"] as? [[String: Any]])
        #expect(remaining.filter { $0["url"] as? String == Self.page("moved").absoluteString }.map { $0["id"] as? Int } == [oldID])
        #expect(!remaining.contains { $0["id"] as? Int == closedID })
        #expect(owner.adapter(for: moved) === movedAdapter)
        #expect(moved.built === movedView)
        #expect(owner.adapter(for: moved).webView(for: context) === movedView)
        withExtendedLifetime((probe, context, movedView)) {}
    }
}
