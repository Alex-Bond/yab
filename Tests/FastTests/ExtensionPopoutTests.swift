import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// chrome.windows.create with type "popup" for an extension's own page: a
/// window of its own, that the extension finds again by its
/// page's address, sees as a popup at the size it asked for, closes with
/// windows.remove or the page's window.close(), and hears windows.onRemoved
/// for. Bitwarden's passkey prompt is one; as a tab it was none of these.
@MainActor
@Suite(.serialized)
struct ExtensionPopoutTests {
    @Test func thePageIsKnownByTheAddressItWasOpenedAt() throws {
        let copy = try #require(URL(string: "chrome-extension://abc/popup/index.yab-popup.html#/fido2?sessionId=1&singleActionPopout=k"))
        #expect(Extensions.popped(copy).absoluteString == "chrome-extension://abc/popup/index.html#/fido2?sessionId=1&singleActionPopout=k")
        let own = try #require(URL(string: "chrome-extension://abc/popup/index.html?uilocation=popout#/tabs/vault"))
        #expect(Extensions.popped(own) == own)
        let site = try #require(URL(string: "https://example.com/index.yab-popup.html"))
        #expect(Extensions.popped(site) == site)
    }

    private static func call(_ web: WKWebView, _ body: String) async throws -> [String: Any] {
        let value = try await web.callAsyncJavaScript(body, contentWorld: .page)
        let text = try #require(value as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private static func until(_ seconds: Double = 30, _ check: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await check() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await check()
    }

    @Test func aPopupOfItsOwnPageIsAWindowItFindsAndCloses() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-popout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Popout test","version":"1.0","permissions":["tabs"]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Start</title>".write(to: folder.appendingPathComponent("start.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Prompt</title>".write(to: folder.appendingPathComponent("prompt.html"), atomically: true, encoding: .utf8)

        // A controller of its own, Yab's delegate answering it: unloaded
        // from Yab's own, the last extension there, it ended other suites'
        // pages as they navigated (Extensions.keepOneLoaded).
        let controller = TestExtensions.controller()
        controller.delegate = Extensions.shared
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        // At chrome-extension://, as yab loads every extension (Extensions.load).
        context.baseURL = try #require(URL(string: "\(Extensions.scheme)://popout\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))/"))
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        try controller.load(context)
        defer {
            ExtensionPopout.close(extension: context.uniqueIdentifier)
            try? controller.unload(context)
        }
        let start = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: try #require(context.webViewConfiguration))
        start.load(URLRequest(url: context.baseURL.appendingPathComponent("start.html")))
        #expect(try await Self.until { (try? await start.evaluateJavaScript("document.readyState === 'complete' && !!chrome.windows")) as? Bool == true })
        _ = try await start.evaluateJavaScript("globalThis.removed = []; chrome.windows.onRemoved.addListener(id => removed.push(id)); true")

        let made = try await Self.call(start, """
            const w = await chrome.windows.create({type: 'popup', url: 'prompt.html#/start?singleActionPopout=k',
                                                   focused: false, left: 120, top: 140, width: 380, height: 450});
            const found = await chrome.tabs.query({url: chrome.runtime.getURL('prompt.html') + '*'});
            const got = await chrome.windows.get(w.id, {populate: true});
            return JSON.stringify({id: w.id, type: w.type, found: found.map(t => ({window: t.windowId, url: t.url})),
                                   got: {type: got.type, tabs: got.tabs.length, left: got.left, top: got.top, width: got.width, height: got.height}});
            """)
        let id = try #require(made["id"] as? Int)
        #expect(made["type"] as? String == "popup")
        let popout = try #require(ExtensionPopout.open.first { $0.extensionID == context.uniqueIdentifier })
        #expect(ExtensionPopout.open.filter { $0.extensionID == context.uniqueIdentifier }.count == 1)
        // The page as wide as asked, the frame as tall (ExtensionWindowFrame).
        #expect(popout.shown.extensionFrame.size == NSSize(width: 380, height: 450))
        #expect(popout.web.frame.width == 380)
        // Found again by the address it was opened at, in its own window.
        let found = try #require(made["found"] as? [[String: Any]])
        #expect(found.count == 1)
        #expect(found.first?["window"] as? Int == id)
        let got = try #require(made["got"] as? [String: Any])
        #expect(got["type"] as? String == "popup")
        #expect(got["tabs"] as? Int == 1)
        // Where it asked, in Chrome's coordinates, round trip through WebKit.
        #expect(got["left"] as? Int == 120)
        #expect(got["top"] as? Int == 140)
        #expect(got["width"] as? Int == 380)
        #expect(got["height"] as? Int == 450)

        // windows.remove closes it, and the extension hears it.
        _ = try await start.callAsyncJavaScript("await chrome.windows.remove(\(id)); return 1", contentWorld: .page)
        #expect(try await Self.until { ExtensionPopout.open.allSatisfy { $0.extensionID != context.uniqueIdentifier } })
        #expect(try await Self.until { (try? await start.evaluateJavaScript("removed.includes(\(id))")) as? Bool == true })
        #expect(!popout.window.isVisible)

        // The page's own window.close() closes it too, history or not.
        let again = try await Self.call(start, """
            const w = await chrome.windows.create({type: 'popup', url: 'prompt.html', focused: false, width: 380, height: 450});
            return JSON.stringify({id: w.id});
            """)
        let second = try #require(again["id"] as? Int)
        let prompt = try #require(ExtensionPopout.open.first { $0.extensionID == context.uniqueIdentifier })
        // Its own page loaded, not the empty one a new view starts with,
        // whose readyState is already complete: a hash set on that went
        // with it when prompt.html came in, and history stayed at one entry
        // (whole-suite runs on m4, where the page took longer to come).
        #expect(try await Self.until { (try? await prompt.web.evaluateJavaScript("location.pathname === '/prompt.html' && document.readyState === 'complete'")) as? Bool == true })
        // Routed by its hash, as Bitwarden's prompt: more than one history
        // entry, which WebKit's own close refuses.
        for route in ["#/a", "#/b"] {
            _ = try await prompt.web.evaluateJavaScript("location.hash = '\(route)'; true")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await Self.until { (try? await prompt.web.evaluateJavaScript("history.length")) as? Int ?? 0 > 1 }, "at \(prompt.web.url?.absoluteString ?? "no address")")
        // Once its close is carried (the document has loaded).
        #expect(try await Self.until { (try? await prompt.web.evaluateJavaScript("!String(window.close).includes('[native code]')")) as? Bool == true })
        _ = try await prompt.web.evaluateJavaScript("window.close(); true")
        #expect(try await Self.until { ExtensionPopout.open.allSatisfy { $0.extensionID != context.uniqueIdentifier } })
        #expect(try await Self.until { (try? await start.evaluateJavaScript("removed.includes(\(second))")) as? Bool == true })

        // Closed by hand, its close button: the same.
        let third = try #require(try await Self.call(start, """
            const w = await chrome.windows.create({type: 'popup', url: 'prompt.html', focused: false});
            return JSON.stringify({id: w.id});
            """)["id"] as? Int)
        let byHand = try #require(ExtensionPopout.open.first { $0.extensionID == context.uniqueIdentifier })
        byHand.window.performClose(nil)
        #expect(try await Self.until { ExtensionPopout.open.allSatisfy { $0.extensionID != context.uniqueIdentifier } })
        #expect(try await Self.until { (try? await start.evaluateJavaScript("removed.includes(\(third))")) as? Bool == true })
        withExtendedLifetime(start) {}
    }
}
