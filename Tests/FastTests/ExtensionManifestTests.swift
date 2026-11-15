import Foundation
import Testing
import WebKit
@testable import Fast

/// What `prepare` mends in a store manifest that Chrome takes as it is and
/// WebKit lists as an error (Rabby Wallet's `externally_connectable`).
@MainActor
@Suite(.serialized)
struct ExtensionManifestTests {
    @Test func emptyExternallyConnectableIsTakenOut() {
        for entry: Any in [["ids": [String]()], ["matches": [String]()], [String: Any](), ["ids": [""]], ["matches": ["<all_urls>"]], "nonsense"] {
            var manifest: [String: Any] = ["externally_connectable": entry]
            ExtensionShims.mendExternallyConnectable(&manifest)
            #expect(manifest["externally_connectable"] == nil, "\(entry)")
        }
    }

    /// A store extension's row warns of what went wrong between it and Yab,
    /// not of what its own code threw (feedback #140); a folder's shows all.
    @Test func ownErrorsAreKeptButNotWarnedOf() {
        let extensions = Extensions.shared
        let id = "test-warnings-\(UUID().uuidString.prefix(8))"
        extensions.noteError("unhandled: WASM is not initialized", for: id, own: true)
        extensions.noteError("had to restart: its worker stopped answering", for: id)
        let store = Installed(id: id, name: "x", version: "1", enabled: true, fromStore: true, permissions: [])
        var folder = store
        folder.fromStore = false
        #expect(extensions.warnings(store) == ["had to restart: its worker stopped answering"])
        #expect(extensions.warnings(folder).count == 2)
        #expect(extensions.errors[id]?.count == 2)
    }

    /// An empty script or stylesheet in a package gets a line break: macOS
    /// 15's WebKit threw on the main thread injecting one (crash #97,
    /// #98). Anything else stays as shipped.
    @Test func emptyScriptsGetALineBreak() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("yab-empty-\(UUID())")
        try files.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        for name in ["a.js", "sub/b.css", "c.MJS", "d.json", "e.html"] { try Data().write(to: folder.appendingPathComponent(name)) }
        try Data("x()".utf8).write(to: folder.appendingPathComponent("f.js"))
        try files.createSymbolicLink(at: folder.appendingPathComponent("g.js"), withDestinationURL: folder.appendingPathComponent("d.json"))
        ExtensionShims.fillEmptyScripts(in: folder)
        let read = { (name: String) in try Data(contentsOf: folder.appendingPathComponent(name)) }
        #expect(try read("a.js") == Data("\n".utf8))
        #expect(try read("sub/b.css") == Data("\n".utf8))
        #expect(try read("c.MJS") == Data("\n".utf8))
        #expect(try read("d.json").isEmpty)
        #expect(try read("e.html").isEmpty)
        #expect(try read("f.js") == Data("x()".utf8))
        #expect(try files.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("g.js").path).hasSuffix("d.json"))
    }

    @Test func emptyContentScriptsGo() {
        var empty: [String: Any] = ["content_scripts": [Any]()]
        ExtensionShims.mendEmptyContentScripts(&empty)
        #expect(empty["content_scripts"] == nil)
        var some: [String: Any] = ["content_scripts": [["matches": ["<all_urls>"], "js": ["a.js"]]]]
        ExtensionShims.mendEmptyContentScripts(&some)
        #expect((some["content_scripts"] as? [Any])?.count == 1)
    }

    /// LINE's sandbox page compiles WebAssembly, which Chrome's default
    /// policy allows and WebKit's does not (#395): an MV3 package with
    /// sandbox pages or a .wasm and no policy of its own gets Chrome's,
    /// WebKit takes it, and nothing else changes.
    @Test func wasmPackagesGetChromesPolicy() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("yab-nowasm-\(UUID())")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        var plain: [String: Any] = ["manifest_version": 3]
        ExtensionShims.mendWasmPolicy(&plain, in: empty)
        #expect(plain["content_security_policy"] == nil)
        var own: [String: Any] = ["manifest_version": 3, "sandbox": ["pages": ["s.html"]],
                                  "content_security_policy": ["extension_pages": "script-src 'self'"]]
        ExtensionShims.mendWasmPolicy(&own, in: empty)
        #expect((own["content_security_policy"] as? [String: Any])?["extension_pages"] as? String == "script-src 'self'")
        var two: [String: Any] = ["manifest_version": 2, "sandbox": ["pages": ["s.html"]]]
        ExtensionShims.mendWasmPolicy(&two, in: empty)
        #expect(two["content_security_policy"] == nil)

        for (name, extra) in [("sandbox", ["sandbox": ["pages": ["s.html"]]] as [String: Any]), ("wasm", [:])] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-wasm-manifest-\(name)-\(UUID())")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("lib"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var original: [String: Any] = ["manifest_version": 3, "name": "Wasm test", "description": "Test", "version": "1.0"]
            original.merge(extra) { $1 }
            try JSONSerialization.data(withJSONObject: original).write(to: folder.appendingPathComponent("manifest.json"))
            try "<!doctype html>".write(to: folder.appendingPathComponent("s.html"), atomically: true, encoding: .utf8)
            if name == "wasm" { try Data([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]).write(to: folder.appendingPathComponent("lib/m.wasm")) }
            try ExtensionShims.prepare(folder)
            let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            let prepared = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((prepared["content_security_policy"] as? [String: Any])?["extension_pages"] as? String == ExtensionShims.chromePagesPolicy, "\(name)")
            let extensionPackage = try await WKWebExtension(resourceBaseURL: folder)
            #expect(extensionPackage.errors.isEmpty, "\(name): \(extensionPackage.errors.map(\.localizedDescription))")
        }
    }

    /// Safari 18's WebKit reads no keyword in an MV3 script-src, so
    /// Bitwarden's 'wasm-unsafe-eval' was dropped and it said WebAssembly is
    /// not supported (#566): there its sources move to script-src-elem, and
    /// a WebKit that takes the keyword gets the package's policy back.
    @Test func safari18GetsWasmWithoutScriptSrc() throws {
        let bitwarden = "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"
        #expect(ExtensionShims.wasmPolicyForSafari18(bitwarden)
                == "script-src-elem 'self'; script-src-attr 'none'; worker-src 'self'; object-src 'self';")
        #expect(ExtensionShims.wasmPolicyForSafari18(ExtensionShims.chromePagesPolicy)
                == "script-src-elem 'self'; script-src-attr 'none'; worker-src 'self'; object-src 'self';")
        #expect(ExtensionShims.wasmPolicyForSafari18("script-src 'self'; object-src 'self'") == nil)
        #expect(ExtensionShims.wasmPolicyForSafari18("default-src 'self'; script-src 'self' 'wasm-unsafe-eval'") == nil)
        #expect(ExtensionShims.wasmPolicyForSafari18("script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:")
                == "script-src-elem 'self'; script-src-attr 'none'; worker-src 'self' blob:;")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-safari18-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let given: [String: Any] = ["extension_pages": bitwarden, "sandbox": "sandbox allow-scripts; script-src 'self'"]
        var manifest: [String: Any] = ["manifest_version": 3, "content_security_policy": given]
        ExtensionShims.mendWasmPolicy(&manifest, in: folder, dropsWasmKeyword: true)
        let mended = try #require(manifest["content_security_policy"] as? [String: Any])
        #expect(mended["extension_pages"] as? String == ExtensionShims.wasmPolicyForSafari18(bitwarden))
        #expect(mended["sandbox"] as? String == "sandbox allow-scripts; script-src 'self'")
        ExtensionShims.mendWasmPolicy(&manifest, in: folder, dropsWasmKeyword: true)
        #expect((manifest["content_security_policy"] as? [String: Any])?["extension_pages"] as? String == ExtensionShims.wasmPolicyForSafari18(bitwarden))
        ExtensionShims.mendWasmPolicy(&manifest, in: folder, dropsWasmKeyword: false)
        #expect((manifest["content_security_policy"] as? [String: Any])?["extension_pages"] as? String == bitwarden)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExtensionShims.givenPolicyFile).path))

        // No policy of its own: Chrome's on Safari 26, said for Safari 18
        // there, and none again once nothing calls for one.
        try Data([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]).write(to: folder.appendingPathComponent("m.wasm"))
        var bare: [String: Any] = ["manifest_version": 3]
        ExtensionShims.mendWasmPolicy(&bare, in: folder, dropsWasmKeyword: true)
        #expect((bare["content_security_policy"] as? [String: Any])?["extension_pages"] as? String
                == ExtensionShims.wasmPolicyForSafari18(ExtensionShims.chromePagesPolicy))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("m.wasm"))
        ExtensionShims.mendWasmPolicy(&bare, in: folder, dropsWasmKeyword: false)
        #expect(bare["content_security_policy"] == nil)
    }

    @Test func usableExternallyConnectableStays() throws {
        var ids: [String: Any] = ["externally_connectable": ["ids": ["gighmmpiobklfepjocnamgkkbiglidom"]]]
        ExtensionShims.mendExternallyConnectable(&ids)
        #expect((ids["externally_connectable"] as? [String: Any])?["ids"] as? [String] == ["gighmmpiobklfepjocnamgkkbiglidom"])

        var matches: [String: Any] = ["externally_connectable": ["matches": ["https://*.grammarly.com/*", "<all_urls>"]]]
        ExtensionShims.mendExternallyConnectable(&matches)
        #expect((matches["externally_connectable"] as? [String: Any])?["matches"] as? [String] == ["https://*.grammarly.com/*"])

        var none: [String: Any] = ["name": "x"]
        ExtensionShims.mendExternallyConnectable(&none)
        #expect(none["externally_connectable"] == nil && none["name"] as? String == "x")
    }

    @Test func aiprmWildcardPortsLoadWithoutErrors() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-aiprm-manifest-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let patterns = ["https://*.aiprm.com:*/*", "https://*.aiprmtest1.com:*/*"]
        let original: [String: Any] = ["manifest_version": 3, "name": "AIPRM pattern test", "description": "Test", "version": "1.0",
                                       "externally_connectable": ["matches": patterns]]
        try JSONSerialization.data(withJSONObject: original).write(to: folder.appendingPathComponent("manifest.json"))
        try "prior-manifest-revision".write(to: folder.appendingPathComponent(ExtensionShims.stamp), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder)
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let prepared = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require(prepared["externally_connectable"] as? [String: Any])
        #expect(entry["matches"] as? [String] == ["https://*.aiprm.com/*", "https://*.aiprmtest1.com/*"])
        let extensionPackage = try await WKWebExtension(resourceBaseURL: folder)
        #expect(extensionPackage.errors.isEmpty, "\(extensionPackage.errors.map(\.localizedDescription))")
    }

    @Test func chromeActionCommandsLoadWithoutErrors() async throws {
        let examples: [[String: Any]] = [
            ["_execute_action": [:], "save_page": ["description": "Save page", "suggested_key": ["default": "Ctrl+Shift+S"]]],
            ["_execute_browser_action": ["suggested_key": ["mac": "Alt+Shift+M"]],
             "_execute_action": ["suggested_key": ["default": "Alt+Shift+M", "mac": "Alt+Shift+M"]]],
        ]
        for commands in examples {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-commands-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let original: [String: Any] = ["manifest_version": 3, "name": "Commands test", "description": "Test",
                                           "version": "1.0", "commands": commands]
            try JSONSerialization.data(withJSONObject: original).write(to: folder.appendingPathComponent("manifest.json"))
            try ExtensionShims.prepare(folder, fresh: true)
            let prepared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
            let fixed = try #require(prepared["commands"] as? [String: Any])
            #expect(fixed["_execute_browser_action"] == nil)
            if (commands["_execute_action"] as? [String: Any])?.isEmpty == true {
                #expect(fixed["_execute_action"] == nil)
                #expect(fixed["save_page"] != nil)
            } else {
                #expect((fixed["_execute_action"] as? [String: Any])?["description"] as? String == "Commands test")
            }
            let extensionPackage = try await WKWebExtension(resourceBaseURL: folder)
            #expect(extensionPackage.errors.isEmpty, "\(extensionPackage.errors.map(\.localizedDescription))")
        }
    }

    @Test func dualBackgroundPrefersServiceWorker() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-background-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "importScripts('fallback.js')".write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        try "const fallback = true".write(to: folder.appendingPathComponent("fallback.js"), atomically: true, encoding: .utf8)
        let original: [String: Any] = ["manifest_version": 3, "name": "Background test", "description": "Test",
                                       "version": "1.0", "background": ["service_worker": "worker.js", "scripts": ["fallback.js"]]]
        try JSONSerialization.data(withJSONObject: original).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        let prepared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let background = try #require(prepared["background"] as? [String: Any])
        #expect(background["preferred_environment"] as? [String] == ["service_worker", "document"])
        #expect(background["scripts"] as? [String] == [ExtensionShims.file, "fallback.js"])
        let extensionPackage = try await WKWebExtension(resourceBaseURL: folder)
        #expect(extensionPackage.errors.isEmpty, "\(extensionPackage.errors.map(\.localizedDescription))")
    }

    /// Rabby Wallet 0.94.11's entry, through `prepare` and WebKit: no error.
    @Test func rabbysManifestLoadsWithoutErrors() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-manifest-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Manifest test","description":"Test","version":"1.0","externally_connectable":{"ids":[]}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let before = try await WKWebExtension(resourceBaseURL: folder)
        #expect(before.errors.contains { $0.localizedDescription.contains("externally_connectable") })
        try ExtensionShims.prepare(folder, fresh: true)
        let after = try await WKWebExtension(resourceBaseURL: folder)
        #expect(after.errors.isEmpty, "\(after.errors.map(\.localizedDescription))")
    }

    /// Eagle 3.1.26's resources, open to "file://*/*" beside every site, and
    /// one open to files alone: no error after, and the sites kept.
    @Test func eaglesAccessibleResourcesLoadWithoutErrors() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-war-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "<html></html>".write(to: folder.appendingPathComponent("dialog.html"), atomically: true, encoding: .utf8)
        try #"{"manifest_version":3,"name":"Resources test","description":"Test","version":"1.0","web_accessible_resources":[{"resources":["dialog.html"],"matches":["https://*/*","http://*/*","file://*/*","<all_urls>"]},{"resources":["dialog.html"],"matches":["file://*/*"]}]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        // The error before is WebKit's on macOS 26 (Eagle's card, #109);
        // macOS 27's WebKit takes the entry. None after, on either.
        try ExtensionShims.prepare(folder, fresh: true)
        let after = try await WKWebExtension(resourceBaseURL: folder)
        #expect(after.errors.isEmpty, "\(after.errors.map(\.localizedDescription))")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let entries = try #require(manifest["web_accessible_resources"] as? [[String: Any]])
        #expect(entries.first?["matches"] as? [String] == ["https://*/*", "http://*/*", "<all_urls>"])
        // The one open to files alone is gone.
        #expect(entries.count == 1)
    }

    /// Eagle 3.1.28's background test (env.js), which threw in WebKit's
    /// worker: the comparison reads globalThis.window, once.
    @Test func backgroundPageTestDoesNotNeedWindow() {
        let eagle = #"e=browser&&browser.runtime&&browser.runtime.getBackgroundPage&&browser.runtime.getBackgroundPage()===window,"function"==typeof browser?.runtime?.getBackgroundPage||e"#
        let mended = ExtensionShims.mendWindowCompare(eagle)
        #expect(mended.contains("getBackgroundPage()===globalThis.window,"))
        #expect(!mended.contains("===window"))
        #expect(ExtensionShims.mendWindowCompare(mended) == mended)
        #expect(ExtensionShims.mendWindowCompare("chrome.extension.getBackgroundPage() !== window)") == "chrome.extension.getBackgroundPage() !== globalThis.window)")
        // Anything else of the window's stays as it is.
        for kept in ["getBackgroundPage()===window.top", "getBackgroundPage()===windowed", "getBackgroundPage===window"] {
            #expect(ExtensionShims.mendWindowCompare(kept) == kept)
        }
    }

    @Test func vimiumsFileOnlyCSSDoesNotBlockPageScripts() async throws {
        var mixed: [String: Any] = ["content_scripts": [
            ["matches": ["file:///*", "https://*/*"], "css": ["page.css"]],
            ["matches": ["file:///*"], "js": ["page.js"]],
        ]]
        ExtensionShims.mendFileOnlyContentCSS(&mixed)
        let mixedScripts = try #require(mixed["content_scripts"] as? [[String: Any]])
        #expect(mixedScripts.count == 2)
        #expect(mixedScripts[0]["matches"] as? [String] == ["https://*/*"])
        #expect(mixedScripts[1]["matches"] as? [String] == ["file:///*"])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-vimium-manifest-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "body { color: red }".write(to: folder.appendingPathComponent("page.css"), atomically: true, encoding: .utf8)
        try "body { color: blue }".write(to: folder.appendingPathComponent("file.css"), atomically: true, encoding: .utf8)
        try "document.documentElement.dataset.vimiumTest = 'loaded'".write(to: folder.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        let entries: [[String: Any]] = [
            ["matches": ["<all_urls>"], "js": ["page.js"], "css": ["page.css"]],
            ["matches": ["file:///", "file:///*/"], "css": ["file.css"]],
        ]
        let original: [String: Any] = ["manifest_version": 3, "name": "Vimium pattern test",
                                       "description": "Test", "version": "1.0", "content_scripts": entries]
        try JSONSerialization.data(withJSONObject: original).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        let prepared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        // The shim's own entry (ExtensionShims.shimOnce) aside.
        let scripts = try #require(prepared["content_scripts"] as? [[String: Any]]).filter { ($0["js"] as? [String]) != [ExtensionShims.content] }
        #expect(scripts.count == 1)
        #expect(scripts[0]["matches"] as? [String] == ["<all_urls>"])
        #expect((scripts[0]["js"] as? [String])?.contains("page.js") == true)
        let after = try await WKWebExtension(resourceBaseURL: folder)
        #expect(after.errors.isEmpty, "\(after.errors.map(\.localizedDescription))")
    }

    /// The shim goes where the extension's own entries go, frame for frame:
    /// Capital One Shopping's all-frames entry is for its own sites, so ad
    /// frames elsewhere get no world of its; Guidde's all-frames entry
    /// over every site takes its top-frame ones too.
    @Test func shimEntriesFollowEachEntrysFrames() async throws {
        let capitalOne: [[String: Any]] = [
            ["matches": ["<all_urls>"], "js": ["pageController.js"], "run_at": "document_start"],
            ["matches": ["https://capitaloneshopping.com/*"], "js": ["wikibuy.js"], "all_frames": true],
            ["matches": ["*://*.amazon.com/*"], "js": ["priceComparison.js"]],
        ]
        let shims = ExtensionShims.shimEntries(for: capitalOne)
        #expect(shims.count == 2)
        let framed = try #require(shims.first { $0["all_frames"] as? Bool == true })
        #expect(framed["matches"] as? [String] == ["https://capitaloneshopping.com/*"])
        let top = try #require(shims.first { $0["all_frames"] == nil })
        #expect(top["matches"] as? [String] == ["<all_urls>", "*://*.amazon.com/*"])
        #expect(shims.allSatisfy { $0["js"] as? [String] == [ExtensionShims.content] && $0["run_at"] as? String == "document_start" })

        let guidde: [[String: Any]] = [
            ["matches": ["<all_urls>"], "js": ["broadcastCS.js"], "exclude_matches": ["https://go.bluevolt.com/scormplayer*"]],
            ["matches": ["<all_urls>"], "js": ["iframeCS.js"], "all_frames": true, "match_about_blank": true, "exclude_matches": [String]()],
            ["matches": ["<all_urls>"], "js": ["record.js"], "exclude_matches": ["https://go.bluevolt.com/scormplayer*"]],
        ]
        let one = ExtensionShims.shimEntries(for: guidde)
        #expect(one.count == 1)
        #expect(one.first?["matches"] as? [String] == ["<all_urls>"])
        #expect(one.first?["all_frames"] as? Bool == true && one.first?["match_about_blank"] as? Bool == true)
        #expect(one.first?["exclude_matches"] == nil)

        // A wider reach that leaves sites out doesn't take the narrower's
        // frames; a reach whose entries all leave the same out keeps it.
        let excluded: [[String: Any]] = [
            ["matches": ["<all_urls>"], "js": ["a.js"], "all_frames": true, "exclude_matches": ["https://x.example/*"]],
            ["matches": ["https://x.example/*"], "js": ["b.js"]],
        ]
        let both = ExtensionShims.shimEntries(for: excluded)
        #expect(both.count == 2)
        #expect(both.first?["exclude_matches"] as? [String] == ["https://x.example/*"])
        #expect(both.last?["matches"] as? [String] == ["https://x.example/*"])

        // Through prepare and WebKit: no error, the extension's entries after the shim's.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shim-scope-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["pageController.js", "wikibuy.js", "priceComparison.js"] {
            try "document.documentElement.dataset.ran = 1".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let original: [String: Any] = ["manifest_version": 3, "name": "Shim scope test", "description": "Test", "version": "1.0",
                                       "content_scripts": capitalOne]
        try JSONSerialization.data(withJSONObject: original).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        // Prepared again (a newer Yab): its earlier shim entries are replaced, not kept beside.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(ExtensionShims.stamp))
        try ExtensionShims.prepare(folder)
        let prepared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let entries = try #require(prepared["content_scripts"] as? [[String: Any]])
        #expect(entries.count == 5)
        #expect(entries.prefix(2).allSatisfy { $0["js"] as? [String] == [ExtensionShims.content] })
        #expect(entries.dropFirst(2).allSatisfy { !(($0["js"] as? [String]) ?? []).contains(ExtensionShims.content) })
        let extensionPackage = try await WKWebExtension(resourceBaseURL: folder)
        #expect(extensionPackage.errors.isEmpty, "\(extensionPackage.errors.map(\.localizedDescription))")
    }
}
