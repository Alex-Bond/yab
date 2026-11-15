import Foundation
import Testing
import WebKit
@testable import Fast

/// window.close() from an extension's popup. WebKit refuses it once a page
/// it loaded natively has more than one history entry, which a popup
/// routed by its hash (Bitwarden) always has by the time it fills; the
/// popup's bridge carries the call to the native side instead.
@MainActor
struct ExtensionPopupCloseTests {
    private final class Watcher: NSObject, WKUIDelegate, WKScriptMessageHandler {
        var closed = 0
        var posted: [String] = []
        func webViewDidClose(_ webView: WKWebView) { closed += 1 }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String { posted.append(body) }
        }
    }

    private static let handler = "yabPopupCloseTest"
    private static let token = "document-token"

    private static func page(routed: Bool) async throws -> (WKWebView, Watcher) {
        let watcher = Watcher(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(watcher, name: handler)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 240), configuration: configuration)
        web.uiDelegate = watcher
        // A page loaded from a URL, as the popup is: one from a string
        // gets no history entries of its own.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("popup-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("popup.html")
        try "<p>popup</p><iframe srcdoc='<p>frame</p>'></iframe>".write(to: file, atomically: true, encoding: .utf8)
        web.loadFileURL(file, allowingReadAccessTo: folder)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && frames.length === 1")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Routes, as a hash-routed popup moves between its views.
        for step in 0..<(routed ? 3 : 0) {
            _ = try await web.evaluateJavaScript("location.hash = '#/view\(step)'; true")
            try await Task.sleep(for: .milliseconds(50))
        }
        let length = try await web.evaluateJavaScript("history.length") as? Int ?? 0
        #expect(routed ? length > 1 : length == 1)
        return (web, watcher)
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    private static func bridge(_ web: WKWebView, host: String = "") async throws {
        let source = try #require(ExtensionPopup.closeBridge(scheme: "file", host: host, token: token, handler: handler))
        _ = try await web.evaluateJavaScript(source + "; true")
    }

    @Test func webKitRefusesScriptCloseOnceANativePageHasHistory() async throws {
        let (fresh, freshWatcher) = try await Self.page(routed: false)
        _ = try await fresh.evaluateJavaScript("window.close(); true")
        try await Self.settle()
        #expect(freshWatcher.closed == 1)

        let (routed, routedWatcher) = try await Self.page(routed: true)
        _ = try await routed.evaluateJavaScript("window.close(); true")
        try await Self.settle()
        #expect(routedWatcher.closed == 0)
        #expect(try await routed.evaluateJavaScript("window.closed") as? Bool == false)
    }

    @Test func theBridgeCarriesEveryFormOfTheTopWindowsClose() async throws {
        let (web, watcher) = try await Self.page(routed: true)
        try await Self.bridge(web)
        _ = try await web.evaluateJavaScript("window.close(); true")
        _ = try await web.evaluateJavaScript("self.close(); true")
        _ = try await web.evaluateJavaScript("(function () { 'use strict'; close(); })(); true")
        // Bitwarden's BrowserApi.closePopup(win) calls win.close().
        _ = try await web.evaluateJavaScript("((win) => win.close())(window); true")
        try await Self.settle()
        #expect(watcher.posted == Array(repeating: Self.token, count: 4))
        // The native side closes the popup, not WebKit.
        #expect(watcher.closed == 0)
    }

    @Test func aFrameOrAnotherOriginKeepsWebKitsClose() async throws {
        let (web, watcher) = try await Self.page(routed: true)
        try await Self.bridge(web)
        _ = try await web.evaluateJavaScript("frames[0].close(); window.close.call(frames[0]); true")
        try await Self.settle()
        #expect(watcher.posted.isEmpty)
        #expect(watcher.closed == 0)

        let (other, otherWatcher) = try await Self.page(routed: true)
        try await Self.bridge(other, host: "another.test")
        #expect(try await other.evaluateJavaScript("String(window.close).includes('[native code]')") as? Bool == true)
        _ = try await other.evaluateJavaScript("window.close(); true")
        try await Self.settle()
        #expect(otherWatcher.posted.isEmpty)
    }

    @Test func theBridgeSerializesWhatItIsGiven() throws {
        let source = try #require(ExtensionPopup.closeBridge(scheme: "webkit-extension", host: "a\"b", token: "t'\\"))
        #expect(source.contains(#"["webkit-extension:","a\"b","t'\\","yabExtensionPopupClose"]"#))
    }

    @Test func onlyThePopupsCurrentDocumentMayClose() {
        let base = URL(string: "webkit-extension://abc/")
        let host = "abc", scheme = "webkit-extension"
        #expect(ExtensionPopup.acceptsClose(body: "t", token: "t", mainFrame: true, scheme: scheme, host: host, base: base))
        // A replaced document has no token, or another one.
        #expect(!ExtensionPopup.acceptsClose(body: "t", token: nil, mainFrame: true, scheme: scheme, host: host, base: base))
        #expect(!ExtensionPopup.acceptsClose(body: "old", token: "t", mainFrame: true, scheme: scheme, host: host, base: base))
        #expect(!ExtensionPopup.acceptsClose(body: 1, token: "t", mainFrame: true, scheme: scheme, host: host, base: base))
        #expect(!ExtensionPopup.acceptsClose(body: "t", token: "t", mainFrame: false, scheme: scheme, host: host, base: base))
        #expect(!ExtensionPopup.acceptsClose(body: "t", token: "t", mainFrame: true, scheme: "https", host: host, base: base))
        #expect(!ExtensionPopup.acceptsClose(body: "t", token: "t", mainFrame: true, scheme: scheme, host: "other", base: base))
        #expect(!ExtensionPopup.acceptsClose(body: "t", token: "t", mainFrame: true, scheme: scheme, host: host, base: nil))
    }
}
