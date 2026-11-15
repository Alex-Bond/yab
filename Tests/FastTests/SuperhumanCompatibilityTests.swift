import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct SuperhumanCompatibilityTests {
    private func page(agent: String? = nil) async throws -> WKWebView {
        _ = NSApplication.shared
        let tab = Tab()
        defer { tab.close() }
        let ordinary = PageScripts.list(for: tab, .init(host: "example.test", css: ""))
        let mail = PageScripts.list(for: tab, .init(host: "mail.superhuman.com", css: ""))
        let sources = [PageScript.load("chrome-like", vars: ["MAJOR": String(SiteAgent.version())]),
                       PageScript.load("legacy-file-system")]
        let compatibility = mail.filter { sources.contains($0.source) }
        #expect(!ordinary.contains { sources.contains($0.source) })
        try #require(compatibility.count == 2, "Mail needs its browser identity and real FileSystem implementation")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        compatibility.forEach(configuration.userContentController.addUserScript)
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = agent ?? SiteAgent.agent(for: URL(string: "https://mail.superhuman.com/"))
        web.loadHTMLString("""
        <html><body><script>
        window.initialGate = {
          chrome: !!(window.webkitRequestFileSystem && window.chrome),
          version: navigator.appVersion.match(/Chrome\\/([0-9]+)/)?.[1] || '',
          installed: document.documentElement.classList.contains('superhumanIsInstalled')
        };
        </script></body></html>
        """, baseURL: URL(string: "https://mail.superhuman.com/"))
        let ready = try await Loaded.until(15, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("!!window.initialGate")) as? Bool == true
        }
        try #require(ready)
        return web
    }

    @Test func browserChecksPassBeforeSiteScriptsWithoutInventingAnInstallation() async throws {
        let web = try await page()
        let gate = try #require(try await web.evaluateJavaScript("window.initialGate") as? [String: Any])
        #expect(gate["chrome"] as? Bool == true)
        #expect(gate["version"] as? String == String(SiteAgent.version()))
        #expect(gate["installed"] as? Bool == false)
    }

    @Test func mailtoRegistrationDoesNotThrowOnMount() async throws {
        let web = try await page()
        let result = try await web.evaluateJavaScript("""
        navigator.registerProtocolHandler("mailto", "https://mail.superhuman.com/~compose/%s", "Superhuman");
        navigator.unregisterProtocolHandler("mailto", "https://mail.superhuman.com/~compose/%s");
        true
        """)
        #expect(result as? Bool == true)
    }

    @Test func deviceOverrideKeepsItsBrowserIdentity() async throws {
        let override = "CompatibilityDevice/1.0"
        let web = try await page(agent: override)
        #expect(!SiteAgent.apply(web, for: URL(string: "https://mail.superhuman.com/")!))
        #expect(try await web.evaluateJavaScript("navigator.userAgent") as? String == override)
        #expect(try await web.evaluateJavaScript("!!window.__yabChromeLike") as? Bool == false)
    }

    @Test func fileSystemWritesReadsResolvesAndRefusesAnotherOrigin() async throws {
        let web = try await page()
        let result = try await web.callAsyncJavaScript("""
        const call = f => new Promise((ok, no) => f(ok, no));
        const fs = await call((ok, no) => webkitRequestFileSystem(PERSISTENT, 1024, ok, no));
        const entry = await call((ok, no) => fs.root.getFile('compatibility.txt', {create:true, exclusive:true}, ok, no));
        try {
          const writer = await call((ok, no) => entry.createWriter(ok, no));
          await new Promise((ok, no) => {
            writer.onwriteend = () => writer.error ? no(writer.error) : ok();
            writer.write(new Blob(['mail storage'], {type:'text/plain'}));
          });
          const resolved = await call((ok, no) => webkitResolveLocalFileSystemURL(entry.toURL(), ok, no));
          const file = await call((ok, no) => resolved.file(ok, no));
          const fetched = await fetch(entry.toURL()).then(r => r.text());
          let denied = false;
          await call((ok, no) => webkitResolveLocalFileSystemURL('filesystem:https://other.test/persistent/compatibility.txt', ok, no))
            .catch(e => { denied = e.name === 'SecurityError'; });
          return (await file.text()) === 'mail storage' && fetched === 'mail storage' && denied;
        } finally { await call((ok, no) => entry.remove(ok, no)); }
        """, arguments: [:], in: nil, contentWorld: .page)
        #expect(result as? Bool == true)
    }
}
