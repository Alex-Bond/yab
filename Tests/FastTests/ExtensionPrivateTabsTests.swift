import AppKit
import Testing
import WebKit
@testable import Fast

/// "Allow in private tabs" (Settings › Extensions): a private tab carries the
/// extension controller, and its extensions act there only when their
/// contexts may reach private data (Extensions.allowPrivate). Before, the
/// setting gave private tabs the controller and no extension did anything in
/// them: no content script, no dark page, no ad blocked, no wallet.
@MainActor
@Suite(.serialized)
struct ExtensionPrivateTabsTests {
    /// A content script that marks every page it runs in, in a private view
    /// (a non-persistent store, as a private tab's), with the context's
    /// access to private data as given.
    private func marks(private allowed: Bool) async throws -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-private-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Private test","version":"1.0","content_scripts":[{"matches":["<all_urls>"],"js":["mark.js"],"run_at":"document_end"}]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "document.documentElement.dataset.marked = 'yes';"
            .write(to: folder.appendingPathComponent("mark.js"), atomically: true, encoding: .utf8)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
        Extensions.allowPrivate(context, allowed)
        try controller.load(context)
        defer { try? controller.unload(context) }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.webExtensionController = controller
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        view.loadHTMLString("<html><body>private</body></html>", baseURL: URL(string: "https://example.com/"))
        // Loaded, then a moment for a content script that would run.
        for _ in 0..<100 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        for _ in 0..<40 {
            if try await view.evaluateJavaScript("document.documentElement.dataset.marked || ''") as? String == "yes" { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func allowedReachesPrivatePages() async throws {
        #expect(try await marks(private: true))
    }

    @Test func notAllowedStaysOut() async throws {
        #expect(try await marks(private: false) == false)
    }

    @Test func allowPrivateSetsTheContext() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-private-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Private test","version":"1.0"}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        #expect(context.hasAccessToPrivateData == false)
        Extensions.allowPrivate(context, true)
        #expect(context.hasAccessToPrivateData)
        Extensions.allowPrivate(context, false)
        #expect(context.hasAccessToPrivateData == false)
    }
}
