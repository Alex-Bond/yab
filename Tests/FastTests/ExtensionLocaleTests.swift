import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
struct ExtensionLocaleTests {
    /// Chrome answers "" for an empty name too (crxMouse's gesture editor, row 1072).
    @Test func iCloudStyleLocalizationCalls() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-locale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Locale test","version":"1.0","default_locale":"en"}"#.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try #"{"extName":{"message":"iCloud Passwords"},"divPINMessage_macos":{"message":"Enter the code shown on your Mac."}}"#.write(to: folder.appendingPathComponent("_locales/en/messages.json"), atomically: true, encoding: .utf8)
        try "<html><head></head><body>Ready</body></html>".write(to: folder.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        context.baseURL = URL(string: "chrome-extension://locale-test/")!
        context.hasAccessToPrivateData = true
        let extensionConfig = WKWebExtensionController.Configuration.nonPersistent()
        extensionConfig.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: extensionConfig)
        try controller.load(context)
        defer { try? controller.unload(context) }
        let config = try #require(context.webViewConfiguration)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        web.load(URLRequest(url: context.baseURL.appendingPathComponent("popup.html")))
        var ready = false
        for _ in 0..<100 {
            ready = (try? await web.evaluateJavaScript("!!globalThis.chrome?.i18n && document.readyState === 'complete'")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ready)
        guard ready else { return }
        let result = try await web.evaluateJavaScript(#"JSON.stringify([['extName'], ['divPINMessage_macos', null], ['divPINMessage_macos', null, null], ['']].map(args => { try { return chrome.i18n.getMessage(...args); } catch (e) { return String(e); } }))"#) as? String
        #expect(result == #"["iCloud Passwords","Enter the code shown on your Mac.","Enter the code shown on your Mac.",""]"#)
    }
}
