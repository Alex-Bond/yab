import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// WebKit is told of a stand-in for an extension's popup
/// (ExtensionShims.mendPopup), so the popup Yab opens is the page at its own
/// address, as Rabby's popup checks before naming its port, and it hears
/// the extension's events, which a page at WebKit's popup path doesn't.
@MainActor
@Suite(.serialized)
struct ExtensionPopupAddressTests {
    private static func until(_ seconds: Double = 30, _ check: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await check() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await check()
    }

    @Test func standInNames() {
        #expect(ExtensionShims.standIn("popup.html") == "popup.yab-action.html")
        #expect(ExtensionShims.standIn("/popup/index.html?uilocation=popup#/tabs") == "/popup/index.yab-action.html?uilocation=popup#/tabs")
        #expect(ExtensionShims.standIn("popup.yab-action.html") == "popup.yab-action.html")
        #expect(ExtensionShims.standIn("https://example.com/p.html") == "https://example.com/p.html")
        #expect(ExtensionShims.unStandIn("/popup/index.yab-action.html#/x") == "/popup/index.html#/x")
    }

    @Test func thePopupIsAtItsAddressAndHearsStorage() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-popup-address-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Popup address test","description":"Test","version":"1.0","permissions":["storage"],"action":{"default_popup":"popup.html"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let page = "<!doctype html><html><head><title>Popup</title><script src=\"seen.js\"></script></head><body></body></html>"
        try page.write(to: folder.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try page.write(to: folder.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Start</title>".write(to: folder.appendingPathComponent("start.html"), atomically: true, encoding: .utf8)
        // What the page's own first script sees, and what it hears.
        try "globalThis.seenPath = location.pathname; globalThis.heard = []; chrome.storage.onChanged.addListener((c) => heard.push(Object.keys(c)));"
            .write(to: folder.appendingPathComponent("seen.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)
        // Prepared again (a newer shim), the stand-in stays one.
        try "x".write(to: folder.appendingPathComponent(ExtensionShims.stamp), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect((manifest["action"] as? [String: Any])?["default_popup"] as? String == "popup.yab-action.html")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("popup.yab-action.html").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("popup.yab-action.yab-action.html").path))

        // A controller of its own: unloaded from Yab's own, the last
        // extension there, it ended other suites' pages as they navigated.
        let controller = TestExtensions.controller()
        controller.delegate = Extensions.shared
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.baseURL = try #require(URL(string: "\(Extensions.scheme)://address\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))/"))
        context.setPermissionStatus(.grantedExplicitly, for: .storage)
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        try controller.load(context)
        defer { try? controller.unload(context) }
        // Yab opens the page itself.
        #expect(Extensions.popupURL(for: context)?.path == "/popup.html")
        let configuration = try #require(context.webViewConfiguration)

        let popup = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 400), configuration: configuration)
        popup.load(URLRequest(url: try #require(Extensions.popupURL(for: context))))
        let other = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        other.load(URLRequest(url: context.baseURL.appendingPathComponent("other.html")))
        for web in [popup, other] {
            #expect(try await Self.until { (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!globalThis.heard")) as? Bool == true })
        }
        #expect(try await popup.evaluateJavaScript("seenPath") as? String == "/popup.html")

        // Another of its pages stores something: both hear it, the popup too.
        let start = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        start.load(URLRequest(url: context.baseURL.appendingPathComponent("start.html")))
        #expect(try await Self.until { (try? await start.evaluateJavaScript("document.readyState === 'complete' && !!chrome.storage")) as? Bool == true })
        _ = try await start.callAsyncJavaScript("await chrome.storage.local.set({probe: Date.now()}); return 1", contentWorld: .page)
        #expect(try await Self.until { (try? await other.evaluateJavaScript("JSON.stringify(heard)")) as? String == #"[["probe"]]"# })
        #expect(try await Self.until { (try? await popup.evaluateJavaScript("JSON.stringify(heard)")) as? String == #"[["probe"]]"# })

        // A popup the extension sets later: WebKit hears of its stand-in,
        // the extension reads back what it set. (The stand-in's file is put
        // in the extension's folder under Yab's, not this one.)
        let set = try await start.callAsyncJavaScript("""
            await chrome.action.setPopup({popup: 'other.html'});
            return JSON.stringify({popup: await chrome.action.getPopup({})});
            """, contentWorld: .page) as? String
        #expect(set?.contains("other.html") == true && set?.contains("yab-action") == false, "\(set ?? "nil")")
        withExtendedLifetime((popup, start, other)) {}
    }
}
