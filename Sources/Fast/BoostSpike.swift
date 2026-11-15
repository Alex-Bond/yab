import AppKit
import WebKit

/// Isolated fixture probe. Measures observed style application, not display
/// latency or end-to-end model latency; it never touches an installed extension.
@MainActor
enum BoostSpike {
    static func run(_ url: URL) async throws -> [String: Any] {
        guard Store.testing, url.host == "127.0.0.1", url.scheme == "http" else { throw BoostPackage.Invalid("The spike requires the test's loopback fixture.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boost-spike-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WKWebsiteDataStore.nonPersistent()
        let controllerConfiguration = WKWebExtensionController.Configuration.nonPersistent()
        controllerConfiguration.defaultWebsiteDataStore = store
        let controller = WKWebExtensionController(configuration: controllerConfiguration)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = store; configuration.webExtensionController = controller
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 640), configuration: configuration)
        let host = Host(web: web)
        controller.delegate = host
        controller.didOpenWindow(host)
        controller.didOpenTab(host)
        defer { web.stopLoading(); controller.delegate = nil }
        web.load(URLRequest(url: url))
        for _ in 0..<100 {
            if (try? await BoostJavaScript.evaluate("document.readyState==='complete' && !!document.querySelector('.shorts')", on: web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let hidden = "getComputedStyle(document.querySelector('.shorts')).display==='none'"
        var results: [String: Any] = [:]
        let direct = Date()
        _ = try await BoostJavaScript.evaluate("const style=document.createElement('style');style.id='spike-direct';style.textContent='.shorts{display:none!important}';document.head.append(style);true", on: web, world: Boosts.world("spike"))
        results["directApplied"] = try await BoostJavaScript.evaluate(hidden, on: web)
        results["directObservedMilliseconds"] = Date().timeIntervalSince(direct) * 1000
        _ = try await BoostJavaScript.evaluate("document.getElementById('spike-direct').remove();true", on: web)
        results["directUndo"] = (try await BoostJavaScript.evaluate(hidden, on: web)) as? Bool == false
        let manifest = """
        {"manifest_version":3,"name":"Boost spike","description":"Isolated loopback fixture","version":"1.0","content_scripts":[{"matches":["http://127.0.0.1/*"],"css":["style.css"],"js":["page.js"]}]}
        """
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try ".shorts{display:none!important}".write(to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "document.body.dataset.spike='applied';".write(to: root.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        let began = Date()
        let ext = try await WKWebExtension(resourceBaseURL: root)
        let context = WKWebExtensionContext(for: ext)
        // This controller contains only this probe's fresh loopback document.
        // WebKit identifies nonpersistent data stores as private tabs.
        context.hasAccessToPrivateData = true
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*"))
        try controller.load(context)
        for _ in 0..<40 {
            if (try? await BoostJavaScript.evaluate(hidden, on: web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let applied = (try await BoostJavaScript.evaluate(hidden, on: web)) as? Bool == true
        let mutated = (try await BoostJavaScript.evaluate("document.body.dataset.spike === 'applied'", on: web)) as? Bool == true
        results["extensionAppliedWithoutReload"] = applied
        results["extensionDOMApplied"] = mutated
        results["extensionObservedMilliseconds"] = Date().timeIntervalSince(began) * 1000
        // Test unloading the document where injection was observed. Reloading
        // before this assertion discards the very DOM mutation being measured.
        try controller.unload(context)
        try await Task.sleep(for: .milliseconds(200))
        results["unloadTestIsValid"] = applied && mutated
        results["extensionUndoStyles"] = (try await BoostJavaScript.evaluate(hidden, on: web)) as? Bool == false
        results["extensionUndoDOM"] = (try await BoostJavaScript.evaluate("document.body.dataset.spike === undefined", on: web)) as? Bool == true
        results["extensionErrors"] = ext.errors.map(\.localizedDescription)
        return results
    }
    private final class Host: NSObject, WKWebExtensionControllerDelegate, WKWebExtensionWindow, WKWebExtensionTab {
        let web: WKWebView
        init(web: WKWebView) { self.web = web }
        func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [self] }
        func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
        func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [self] }
        func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { self }
        func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
        func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
        func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
        func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
        func url(for context: WKWebExtensionContext) -> URL? { web.url }
        func isSelected(for context: WKWebExtensionContext) -> Bool { true }
        func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    }

}
