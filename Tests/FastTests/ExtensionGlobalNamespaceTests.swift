import Foundation
import JavaScriptCore
import Testing
@testable import Fast

@MainActor
struct ExtensionGlobalNamespaceTests {
    private func browserOverride(for id: String) throws -> [String: Any] {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // WebKit finds a page's extension APIs"))
        let end = try #require(script.range(of: "  // On a web page", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        let source = """
        (() => {
          const root = globalThis;
          const chrome = { runtime: { id: \(String(data: try JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), encoding: .utf8)!) } };
          Object.defineProperty(root, 'chrome', { value: chrome, configurable: true });
          Object.defineProperty(root, 'browser', { value: chrome, configurable: true });
        \(script[start.lowerBound..<end.lowerBound])
          let error = null;
          try { root.__defineGetter__('browser', () => ({ ownPolyfill: true })); }
          catch (failure) { error = String(failure); }
          return JSON.stringify({ error, ownPolyfill: !!root.browser?.ownPolyfill,
            browserConfigurable: Object.getOwnPropertyDescriptor(root, 'browser')?.configurable,
            chromeConfigurable: Object.getOwnPropertyDescriptor(root, 'chrome')?.configurable });
        })()
        """
        let value = try #require(context.evaluateScript(source)?.toString())
        try #require(context.exception == nil)
        return try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }


    @Test func singleFileMayInstallItsBrowserGetterWithoutUnfixingChrome() throws {
        let result = try browserOverride(for: "mpiodijhokgodhhofbcjdecpffjipkle")
        #expect(result["error"] is NSNull)
        #expect(result["ownPolyfill"] as? Bool == true)
        #expect(result["chromeConfigurable"] as? Bool == false)
    }

    @Test func otherExtensionsKeepTheProtectedBrowserGlobal() throws {
        let result = try browserOverride(for: "nkbihfbeogaeaoehlefnkodbefgpgknn")
        #expect((result["error"] as? String)?.contains("TypeError") == true)
        #expect(result["ownPolyfill"] as? Bool == false)
        #expect(result["browserConfigurable"] as? Bool == false)
    }

}
