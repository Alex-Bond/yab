import AppKit
import Testing
import WebKit
@testable import Fast

/// Chrome's externally_connectable for web pages (ExtensionExternal.swift,
/// extension-external-page.js, the shim's external port): a page the
/// extension's matches name gets chrome.runtime.sendMessage and connect,
/// heard in the worker as onMessageExternal and onConnectExternal, as
/// claude.ai signs Claude for Chrome in.
@MainActor
@Suite(.serialized)
struct ExtensionExternalTests {
    static let id = "fcoeoabgfenejglbffodgkkbkcdhcgfn"
    static let matches = ["https://external.test/*"]

    @MainActor
    final class Answers: NSObject, WKWebExtensionControllerDelegate {
        func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
            ["value": NSNull()]
        }
        func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
            if port.applicationIdentifier == ExtensionExternal.portName {
                ExtensionExternal.shared.attach(port, extension: extensionContext.uniqueIdentifier)
            }
        }
    }

    @Test func patternsAndManifest() {
        #expect(ExtensionShims.externalPages(of: ["externally_connectable": ["matches": ["https://claude.ai/*", "<all_urls>"]]]) == ["https://claude.ai/*"])
        #expect(ExtensionShims.externalPages(of: ["externally_connectable": ["ids": ["x"]]]).isEmpty)
        #expect(ExtensionExternal.allows(["https://claude.ai/*"], URL(string: "https://claude.ai/oauth/callback?code=1")!))
        #expect(ExtensionExternal.allows(["https://*.1password.com/*"], URL(string: "https://my.1password.com/")!))
        #expect(!ExtensionExternal.allows(["https://claude.ai/*"], URL(string: "https://evil.example/claude.ai/")!))
        #expect(!ExtensionExternal.allows(["https://claude.ai/*"], URL(string: "http://claude.ai/")!))
    }

    private func page(_ base: String, config: WKWebViewConfiguration) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        web.loadHTMLString("<html><body>External fixture</body></html>", baseURL: URL(string: base)!)
        let loaded = try await Loaded.until(30, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("location.href + ' ' + document.readyState")) as? String == base + " complete"
        }
        try #require(loaded, "\(base) did not load")
        return web
    }

    private func run(_ web: WKWebView, _ js: String) async throws -> Any? {
        try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test func pageTalksToItsExtension() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-external-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        {"manifest_version":3,"name":"External test","version":"1.0","permissions":["storage"],
         "background":{"service_worker":"worker.js"},
         "externally_connectable":{"matches":["https://external.test/*"]}}
        """.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
          if (message && message.type === 'ping') { sendResponse({success: true, exists: true, origin: sender.origin, url: sender.url, frameId: sender.frameId, hasTab: !!sender.tab}); return; }
          if (message && message.type === 'later') { setTimeout(() => sendResponse({later: true}), 200); return true; }
        });
        chrome.runtime.onConnectExternal.addListener((port) => {
          port.onMessage.addListener((m) => {
            if (m === 'bye') { port.disconnect(); return; }
            port.postMessage({echo: m, name: port.name, origin: port.sender.origin});
          });
        });
        """.write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)

        let controller = TestExtensions.controller()
        let answers = Answers()
        controller.delegate = answers
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = Self.id
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        context.baseURL = URL(string: "chrome-extension://\(Self.id)/")!
        for permission in context.webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        try controller.load(context)
        defer { try? controller.unload(context) }

        let hub = ExtensionExternal.shared
        hub.context = { $0 == Self.id ? context : nil }
        hub.wake = { _, then in then() }
        hub.place = { _ in (0, "https://external.test/page") }
        hub.set([Self.id: Self.matches])
        defer { hub.set([:]) }
        // The worker's first start, the shim opening its port: seconds on a
        // Mac busy with a build, past the 10 s a page waits in Yab.
        let patience = hub.patience
        hub.patience = .seconds(120)
        defer { hub.patience = patience }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = Web.userAgentName
        hub.scripts.forEach(config.userContentController.addUserScript)
        config.userContentController.addScriptMessageHandler(ExternalRelay.shared, contentWorld: Web.world, name: ExternalRelay.name)

        let web = try await page("https://external.test/page", config: config)
        // Callback and promise forms; the worker answers with who sent it.
        let ping = try await run(web, "return await chrome.runtime.sendMessage('\(Self.id)', {type: 'ping'})") as? [String: Any]
        #expect(ping?["success"] as? Bool == true && ping?["exists"] as? Bool == true, "\(String(describing: ping))")
        #expect(ping?["origin"] as? String == "https://external.test", "\(String(describing: ping))")
        #expect(ping?["frameId"] as? Int == 0 && ping?["hasTab"] as? Bool == true, "\(String(describing: ping))")
        let callback = try await run(web, """
            return await new Promise((resolve) => chrome.runtime.sendMessage('\(Self.id)', {type: 'later'}, (r) => resolve({r, error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null})));
            """) as? [String: Any]
        #expect((callback?["r"] as? [String: Any])?["later"] as? Bool == true, "\(String(describing: callback))")
        // Nobody answering: Chrome's words, in lastError.
        let silent = try await run(web, """
            return await new Promise((resolve) => chrome.runtime.sendMessage('\(Self.id)', {type: 'nothing'}, (r) => resolve(chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none')));
            """) as? String
        #expect(silent == "The message port closed before a response was received.")
        // An extension that isn't there, or doesn't let this page in.
        let unknown = try await run(web, """
            return await new Promise((resolve) => chrome.runtime.sendMessage('abcdefghijklmnopabcdefghijklmnop', {type: 'ping'}, (r) => resolve(chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none')));
            """) as? String
        #expect(unknown == ExtensionExternal.noReceiver)

        // A port, there and back, and closed by the extension.
        let port = try await run(web, """
            const port = chrome.runtime.connect('\(Self.id)', {name: 'side'});
            const first = await new Promise((resolve) => { port.onMessage.addListener(function once(m) { port.onMessage.removeListener(once); resolve(m); }); port.postMessage('hello'); });
            const closed = await new Promise((resolve) => { port.onDisconnect.addListener(() => resolve(true)); port.postMessage('bye'); setTimeout(() => resolve(false), 30000); });
            return {first, closed};
            """) as? [String: Any]
        let first = port?["first"] as? [String: Any]
        #expect(first?["echo"] as? String == "hello" && first?["name"] as? String == "side" && first?["origin"] as? String == "https://external.test", "\(String(describing: port))")
        #expect(port?["closed"] as? Bool == true, "\(String(describing: port))")

        // A page the extension doesn't name gets nothing.
        let other = try await page("https://other.test/", config: config)
        let bare = try await run(other, "return typeof (window.chrome && chrome.runtime && chrome.runtime.sendMessage)") as? String
        #expect(bare == "undefined")
    }
}
