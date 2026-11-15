import AppKit
import Testing
import WebKit
@testable import Fast

struct ChromiumDRMScriptLifetimeTests {
    @Test @MainActor func catalogRebuildAndDetachDoNotMultiplyNativeExtensionScripts() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("yab-drm-script-lifetime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"IPC script lifetime regression","version":"1.0","content_scripts":[{"matches":["https://example.test/*"],"js":["content.js"],"run_at":"document_start"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let source = "globalThis.ipcExtensionRuns = (globalThis.ipcExtensionRuns || 0) + 1;"
        try Data(source.utf8).write(to: folder.appendingPathComponent("content.js"))

        let extensionConfiguration = WKWebExtensionController.Configuration.nonPersistent()
        extensionConfiguration.defaultWebsiteDataStore = .nonPersistent()
        let extensions = WKWebExtensionController(configuration: extensionConfiguration)
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: webExtension)
        context.hasAccessToPrivateData = true // The fixture's website store is ephemeral.
        context.setPermissionStatus(.grantedExplicitly,
                                    for: try WKWebExtension.MatchPattern(string: "https://example.test/*"))
        try extensions.load(context)
        defer { try? extensions.unload(context) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = extensionConfiguration.defaultWebsiteDataStore
        configuration.webExtensionController = extensions
        let web = WKWebView(frame: .zero, configuration: configuration)
        let controller = web.configuration.userContentController
        // Let WebKit attach the extension to this view, without visiting a site.
        for _ in 0..<100 {
            if !controller.userScripts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // WKNSArray reflects later changes to WebKit's backing array.
        let injected = controller.userScripts.map { $0 }
        try #require(!injected.isEmpty, "The fixture must contain actual WebKit extension scripts")
        controller.removeAllUserScripts()
        try #require(controller.userScripts.count == injected.count,
                     "WebKit keeps extension scripts when application scripts are cleared")

        // Same source as an extension, but a separate application script:
        // deduplication must use identity, not discard matching source text.
        let sentinel = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(sentinel)
        var previous: [WKUserScript] = []
        for round in 0..<64 {
            // prepare(catalog changed), followed by detach, uses this same
            // production removal path. Native extension scripts remain owned
            // by WebKit while the bridge's scripts must disappear.
            ChromiumDRMExtensions.removeScripts(previous, from: controller, removingMarked: true)
            let bridge = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            controller.addUserScript(bridge)
            previous = [bridge]
            let scripts = controller.userScripts.map { $0 }
            try #require(scripts.count == injected.count + 2, "Catalog rebuild \(round) grew the script list")
            #expect(scripts.filter { $0 === sentinel }.count == 1)
            #expect(scripts.filter { $0 === bridge }.count == 1)
            for script in injected { #expect(scripts.filter { $0 === script }.count == 1) }
            ChromiumDRMExtensions.removeScripts(previous, from: controller)
            #expect(controller.userScripts.count == injected.count + 1)
        }
        // Rebuild still purges an orphaned application bridge script by its
        // legacy marker, but must not read/re-add the native survivors.
        let orphan = WKUserScript(source: "/*yab-chromium-extension*/orphan", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(orphan)
        ChromiumDRMExtensions.removeScripts([], from: controller, removingMarked: true)
        #expect(!controller.userScripts.contains { $0 === orphan })
        #expect(controller.userScripts.count == injected.count + 1)
        // Two same-source application scripts are distinct and both survive
        // when neither belongs to the retiring bridge.
        let twin = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(twin)
        ChromiumDRMExtensions.removeScripts([], from: controller)
        #expect(controller.userScripts.filter { $0 === sentinel || $0 === twin }.count == 2)
        // EngineSwitchDocument removes its transient script by passing the
        // retained controller snapshot through PageScripts.fit. The list can
        // therefore contain native extension scripts, unlike ordinary arming.
        for round in 0..<64 {
            let handoff = WKUserScript(source: "/* handoff \(round) */", injectionTime: .atDocumentStart, forMainFrameOnly: true)
            PageScripts.fit(controller, controller.userScripts.map { $0 } + [handoff])
            PageScripts.fit(controller, controller.userScripts.filter { $0 !== handoff })
            try #require(controller.userScripts.count == injected.count + 2,
                         "Engine-switch cleanup \(round) grew the script list")
            #expect(!controller.userScripts.contains { $0 === handoff })
            for script in injected { #expect(controller.userScripts.filter { $0 === script }.count == 1) }
        }
        // The release line also installs a global duplicate-identity guard.
        // Install it explicitly so this assertion is independent of whether
        // WebKitIPCBoundaryTests ran first in the shared regression batch.
        // The original unguarded negative control is retained in the native
        // before/after evidence under docs/evidence/webkit-ipc-1103.
        WebKitIPCBoundary.install()
        controller.removeAllUserScripts()
        injected.forEach(controller.addUserScript)
        #expect(controller.userScripts.count == injected.count)
        for script in injected { #expect(controller.userScripts.filter { $0 === script }.count == 1) }

        withExtendedLifetime(web) {}
    }
}
