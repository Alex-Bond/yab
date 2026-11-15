import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct BoostEditorTests {
    @Test func olderSavedLooksAndUnsupportedValuesAreSafe() throws {
        let legacy = try JSONDecoder().decode(BoostEditorLook.self, from: Data(#"{"font":3,"amount":0.4}"#.utf8))
        #expect(legacy.font == 3 && legacy.textCase == 0 && legacy.size == 1)
        let invalid = try JSONDecoder().decode(BoostEditorLook.self, from: Data(#"{"font":999,"textCase":-2,"mode":"sepia","hue":-50,"amount":4,"size":200,"spacing":-1,"photos":20}"#.utf8))
        #expect(invalid.font == 7 && invalid.textCase == 0 && invalid.mode.isEmpty)
        #expect(invalid.hue == 0 && invalid.amount == 1 && invalid.size == 1.6)
        #expect(invalid.spacing == 0.5 && invalid.photos == 1.5)
    }

    @Test func savingInvalidControlsDoesNotBreakOtherProfiles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BoostEditorLooks(file: root.appendingPathComponent("looks.json"))
        var look = BoostEditorLook(); look.font = -50; look.amount = .infinity; look.size = .nan
        look.css = "h1 { color: red; }"
        store.set(look, host: "example.test", profile: nil); store.flush()
        let saved = BoostEditorLooks(file: root.appendingPathComponent("looks.json")).look(host: "example.test", profile: nil)
        #expect(saved.font == 0 && saved.amount == 0 && saved.size == 1)
        #expect(saved.css == look.css)
        #expect(store.look(host: "example.test", profile: UUID()) == BoostEditorLook())
    }

    @Test func exactHostsAndProfilesKeepIndependentLooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("looks.json")
        let store = BoostEditorLooks(file: file), profile = UUID()
        var custom = BoostEditorLook(); custom.amount = 0.7; custom.css = "h1 { color: red; }"
        store.set(custom, host: "www.example.test", profile: profile)
        #expect(store.look(host: "example.test", profile: profile) == BoostEditorLook())
        #expect(store.look(host: "www.example.test", profile: nil) == BoostEditorLook())
        #expect(store.look(host: "www.example.test", profile: UUID()) == BoostEditorLook())
        store.flush()
        #expect(BoostEditorLooks(file: file).look(host: "www.example.test", profile: profile) == custom)
        custom.enabled = false; store.set(custom, host: "www.example.test", profile: profile); store.flush()
        #expect(!BoostEditorLooks(file: file).look(host: "www.example.test", profile: profile).enabled)
        store.set(BoostEditorLook(), host: "www.example.test", profile: profile); store.flush()
        #expect(BoostEditorLooks(file: file).look(host: "www.example.test", profile: profile) == BoostEditorLook())
        #expect(BoostEditorLook.host(URL(string: "https://WWW.example.test/path")) == "www.example.test")
        #expect(BoostEditorLook.host(URL(string: "file:///tmp/a.html")) == nil)
        #expect(BoostEditorLook.host(URL(string: "yab://store")) == nil)
    }

    @Test func incompleteCSSRetainsTheLastWorkingVersion() {
        for css in ["", "p { color: red; }", #"p::after { content: '} \"'; }"#, #"p::after { content: 'a\'b'; }"#, "/* { */ p { color: red; }", "@media (min-width: 200px) { p { color: red; } }"] {
            #expect(BoostEditorLook.completeCSS(css), "\(css)")
        }
        for css in ["p { color: red;", "p { color: red; }}", "/* unfinished", "p { content: 'unfinished; }", "p { width: calc(1px; }"] {
            #expect(!BoostEditorLook.completeCSS(css), "\(css)")
        }
    }

    @Test func injectionGuardsExactHostAndSkipsPrivateAndDisabledLooks() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BoostEditorLooks(file: root.appendingPathComponent("looks.json"))
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: "https://www.example.test/article")!, title: "Example")
        var look = BoostEditorLook(); look.amount = 0.4
        store.set(look, host: "www.example.test", profile: AddonProfiles.of(tab))
        let script = try #require(store.script(for: tab, host: "www.example.test"))
        #expect(script.source.contains("location.hostname.toLowerCase() === \"www.example.test\""))
        #expect(store.script(for: tab, host: "example.test") == nil)
        let privateTab = Tab(shy: true, bench: true)
        privateTab.restore(url: tab.address!, title: "Private")
        #expect(store.script(for: privateTab, host: "www.example.test") == nil)
        look.enabled = false; store.set(look, host: "www.example.test", profile: AddonProfiles.of(tab))
        #expect(store.script(for: tab, host: "www.example.test") == nil)
        store.flush()
    }

    @Test func liveWebKitRuntimePreservesOriginalAndHandlesInterruptions() async throws {
        _ = NSApplication.shared
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let sourceRoot = fixtures.deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: sourceRoot.appendingPathComponent("Resources/PageScripts/boost-editor.js"), encoding: .utf8)
        let html = try String(contentsOf: fixtures.appendingPathComponent("boost-editor.html"), encoding: .utf8)
        let checks = try String(contentsOf: fixtures.appendingPathComponent("boost-editor-checks.js"), encoding: .utf8)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 800), configuration: configuration)
        defer { web.stopLoading() }
        web.loadHTMLString(html, baseURL: URL(string: "https://fixture.example.test/"))
        var ready = false
        for _ in 0..<100 {
            ready = (try? await BoostJavaScript.evaluate("document.readyState==='complete'&&!!document.querySelector('#third')", on: web)) as? Bool == true
            if ready { break }; try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready)
        _ = try await BoostJavaScript.evaluate(script, on: web)
        let result = try #require(try await BoostJavaScript.call("return await (\(checks))", on: web) as? [String: Any])
        #expect(result["passed"] as? Bool == true, "\(result)")
        #expect((result["checks"] as? Int ?? 0) >= 30)
    }
}
