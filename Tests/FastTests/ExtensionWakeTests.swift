import AppKit
import Testing
import WebKit
@testable import Fast

/// Tabs told to extensions a moment later and in one go, and extension pages
/// started without the fonts installed on the Mac (Extensions.swift): every
/// sleeping password manager woken by a new tab used to hold the main thread
/// for 6-10 s.
@MainActor
@Suite(.serialized)
struct ExtensionWakeTests {
    @Test func switchesInARowAreOneSwitch() {
        var news = TabNews<Int>()
        news.activated(from: 1, to: 2)
        news.activated(from: 2, to: 3)
        #expect(news.switched?.from == 1)
        #expect(news.switched?.to == 3)
    }

    @Test func aSwitchBackIsNoSwitch() {
        var news = TabNews<Int>()
        news.activated(from: 1, to: 2)
        news.activated(from: 2, to: 1)
        #expect(news.switched == nil)
        // The first tab of a window, from none.
        news.activated(from: nil, to: 4)
        #expect(news.switched?.from == nil)
        #expect(news.switched?.to == 4)
    }

    @Test func changesGatherPerTab() {
        var news = TabNews<Int>()
        news.rowChanged()
        news.changed(1, .URL)
        news.changed(1, .loading)
        news.changed(1, .title)
        news.changed(2, .pinned)
        #expect(news.row)
        #expect(news.changes[1] == [.URL, .loading, .title])
        #expect(news.changes[2] == .pinned)
    }

    @Test func soonEnoughForEvents() {
        // Short enough that an extension hears of the tab within the frame
        // or few after it, long enough for the tab's own frame first.
        guard case .milliseconds(let ms) = TabNews<Int>.delay else { Issue.record("delay not in ms"); return }
        #expect(ms >= 16 && ms <= 250)
    }

    @Test func extensionPagesGoWithoutInstalledFonts() async throws {
        let preferences = WKPreferences()
        #expect(Extensions.allowsInstalledFonts(preferences) == true)
        Extensions.withoutInstalledFonts(preferences)
        #expect(Extensions.allowsInstalledFonts(preferences) == false)

        // And every view WebKit makes for an extension inherits it: its
        // worker, popup and pages are made from the controller's configuration.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-wake-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Wake test","version":"1.0"}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        Extensions.withoutInstalledFonts(views.preferences)
        configuration.webViewConfiguration = views
        let controller = WKWebExtensionController(configuration: configuration)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        defer { try? controller.unload(context) }
        let page = try #require(context.webViewConfiguration)
        #expect(Extensions.allowsInstalledFonts(page.preferences) == false)
    }
}
