import AppKit
import Testing
import WebKit
@testable import Fast

/// Bitwarden 2026.9.3 compiles `using` into disposal helpers. Their symbols
/// must exist before the extension evaluates classes that declare methods
/// under those symbols, otherwise defining the symbols later is too late.
@MainActor
@Suite(.serialized)
struct ExtensionResourceTests {
    @Test func preparedPageDefinesSymbolsBeforeExtensionCode() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-resource-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Resource test","version":"1.0"}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><head><script src=resource.js></script></head><body>Resource fixture</body></html>"
            .write(to: folder.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try Self.resource.write(to: folder.appendingPathComponent("resource.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        context.baseURL = URL(string: "chrome-extension://resource-test/")!
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: configuration)
        try controller.load(context)
        defer { try? controller.unload(context) }
        let config = try #require(context.webViewConfiguration)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        web.load(URLRequest(url: context.baseURL.appendingPathComponent("popup.html")))
        var result: String?
        for _ in 0..<100 {
            result = (try? await web.evaluateJavaScript("JSON.stringify(globalThis.resourceResult ?? null)")) as? String
            if result != nil, result != "null" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(result == #"{"sync":1,"async":1,"distinct":true,"stable":true,"descriptors":true}"#)
    }

    private static let resource = #"""
    (async () => {
      try {
        // The same ordering as tslib's __addDisposableResource: this check
        // is reached before looking up the method on an owned crypto handle.
        if (!Symbol.dispose) throw new TypeError("Symbol.dispose is not defined.");
        if (!Symbol.asyncDispose) throw new TypeError("Symbol.asyncDispose is not defined.");
        const before = Symbol.dispose;
        let sync = 0, async = 0;
        class Handle {
          [Symbol.dispose]() { sync++; }
          async [Symbol.asyncDispose]() { await Promise.resolve(); async++; }
        }
        const a = new Handle(), b = new Handle();
        a[Symbol.dispose].call(a);
        await b[Symbol.asyncDispose].call(b);
        resourceResult = {sync,async,distinct:Symbol.dispose !== Symbol.asyncDispose,
          stable:before === Symbol.dispose,descriptors:['dispose','asyncDispose'].every(k => {
            const d = Object.getOwnPropertyDescriptor(Symbol,k);
            return d && !d.enumerable && !d.configurable && !d.writable;
          })};
      } catch (e) { resourceResult = {error:String(e.message)}; }
    })();
    """#
}
