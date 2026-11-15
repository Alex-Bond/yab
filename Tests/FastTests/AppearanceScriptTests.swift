import AppKit
import Testing
import WebKit
@testable import Fast

struct AppearanceScriptTests {
    @Test @MainActor func extensionScriptsDoNotMultiplyWhenAppearanceChanges() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("yab-appearance-extension-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Appearance regression","version":"1.0","content_scripts":[{"matches":["https://example.test/*"],"js":["content.js"],"run_at":"document_start"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let source = "globalThis.appearanceExtensionRuns = (globalThis.appearanceExtensionRuns || 0) + 1;"
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
        for size in 9...40 {
            var fonts = PageFonts()
            fonts.size = size
            PageAppearance.install(fonts, in: controller)
            let scripts = controller.userScripts
            // 16 is the default: no fonts of one's own, no script for them.
            try #require(scripts.count == injected.count + (size == 16 ? 1 : 2),
                         "Repeated updates must not accumulate extension scripts")
            #expect(scripts.contains { $0 === sentinel })
            for script in injected {
                #expect(scripts.filter { $0 === script }.count == 1)
            }
            let appearance = scripts.filter { $0.source.hasPrefix(PageAppearance.marker) }
            #expect(appearance.count == (size == 16 ? 0 : 1))
            // The script embeds a JSON dictionary whose key order can vary.
            if size != 16 {
                #expect(appearance.first?.source.contains("font-size: \(size)px") == true)
            }
        }
        withExtendedLifetime(web) {}
    }
}
