import AppKit
import Testing
import WebKit
@testable import Fast

struct AppearanceTests {
    @Test func zoomControlsUseTenPercentagePointsWithoutCompounding() {
        var value = 1.0
        for expected in [1.1, 1.2, 1.3] {
            value = PageAppearance.steppedZoom(value, increasing: true)
            #expect(abs(value - expected) < 0.000_001)
        }
        for expected in [1.2, 1.1, 1.0] {
            value = PageAppearance.steppedZoom(value, increasing: false)
            #expect(abs(value - expected) < 0.000_001)
        }
    }

    @Test func zoomStepsPreserveCustomOriginAndExistingBounds() {
        #expect(abs(PageAppearance.steppedZoom(1.25, increasing: true) - 1.35) < 0.000_001)
        #expect(abs(PageAppearance.steppedZoom(1.25, increasing: false) - 1.15) < 0.000_001)
        #expect(PageAppearance.steppedZoom(3, increasing: true) == 3)
        #expect(PageAppearance.steppedZoom(0.4, increasing: false) == 0.4)
        #expect(PageAppearance.steppedZoom(2.95, increasing: true) == 3)
        #expect(PageAppearance.steppedZoom(0.45, increasing: false) == 0.4)
    }

    @Test func defaultZoomAndSiteOverridesStaySeparate() throws {
        let suite = "yab.appearance-tests." + UUID().uuidString
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(1.25, forKey: "pages.zoom")
        store.set(0.9, forKey: "zoom.example.test")
        #expect(PageAppearance.zoom(host: "example.test", privatePage: false, in: store) == 0.9)
        #expect(PageAppearance.zoom(host: "other.test", privatePage: false, in: store) == 1.25)
        #expect(PageAppearance.zoom(host: "example.test", privatePage: true, in: store) == 1.25)
        store.removeObject(forKey: "zoom.example.test")
        #expect(PageAppearance.zoom(host: "example.test", privatePage: false, in: store) == 1.25)
        store.set(99.0, forKey: "pages.zoom")
        #expect(PageAppearance.defaultZoom(in: store) == 3)
    }

    @MainActor @Test func oldSpaceThemesDecodeAndGradientsRoundTrip() throws {
        let old = Data(#"{"swatch":"custom","color":"8DB6E6","grain":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SpacePaint.self, from: old)
        #expect(decoded.colors.isEmpty)
        #expect(decoded.grain == Grain.standard)
        let gradient = SpacePaint(swatch: .custom, color: NSColor(hex: "8DB6E6")!, grain: 0.4,
                                  colors: ["B6A6E6", "EEA2C4"])
        let restored = try JSONDecoder().decode(SpacePaint.self, from: JSONEncoder().encode(gradient))
        #expect(restored == gradient)
        #expect(restored.gradient(dark: true).count == 2)
        // Arc's own shape since request #464 (ArcThemeTests.theme).
        let arc = ArcSidebar.theme(ArcThemeTests.theme([(1, 0, 0), (0, 0, 1)]))
        #expect(arc.color == "FF0000")
        #expect(arc.colors == ["0000FF"])
    }

    @Test func oldSessionsDecodeAndCustomIconsRoundTrip() throws {
        let old = Data(#"{"url":"https://example.test/","title":"Example","pin":"E"}"#.utf8)
        var entry = try JSONDecoder().decode(Session.Entry.self, from: old)
        #expect(entry.customMark == nil && entry.folderMark == nil)
        entry.customMark = "🌱"
        entry.folderMark = "image:test.png"
        let restored = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(entry))
        #expect(restored.customMark == "🌱")
        #expect(restored.folderMark == "image:test.png")
    }

    @MainActor @Test func pageDefaultsRespectAuthorStylesAndCanBeReset() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        web.loadHTMLString("""
        <style>#authored { font: 11px Helvetica; }</style>
        <p id=plain>Default type</p><p id=authored>Site's type</p><pre id=code>Code</pre>
        <p id=serif style="font-family:serif">Serif type</p>
        """, baseURL: URL(string: "https://appearance.example.test/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('#plain')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        var fonts = PageFonts()
        fonts.size = 24
        fonts.standard = "Georgia"
        fonts.serif = "Palatino"
        fonts.fixed = "Menlo"
        try await web.evaluateJavaScript(PageAppearance.script(fonts))
        let styled = try #require(try await web.evaluateJavaScript("""
        ['plain','authored','code'].map(id => {
          const s = getComputedStyle(document.getElementById(id));
          return { size:s.fontSize, font:s.fontFamily };
        })
        """) as? [[String: String]])
        #expect(styled[0]["size"] == "24px")
        #expect(styled[0]["font"]?.contains("Georgia") == true)
        #expect(styled[1]["size"] == "11px")
        #expect(styled[1]["font"]?.contains("Helvetica") == true)
        #expect(styled[2]["font"]?.contains("Menlo") == true)
        // The page's own "serif" is the engine's to draw (PageFamilies), and
        // the script leaves the element as the page wrote it.
        let serif = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('serif')).fontFamily") as? String
        #expect(serif == "serif")
        #expect(try await web.evaluateJavaScript("document.getElementById('serif').getAttribute('style')") as? String == "font-family:serif")
        try await web.evaluateJavaScript(PageAppearance.script(PageFonts()))
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.getElementById('plain')).fontSize") as? String == "16px")
        let sentinel = WKUserScript(source: "window.kept = true", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        web.configuration.userContentController.addUserScript(sentinel)
        PageAppearance.install(fonts, in: web.configuration.userContentController)
        #expect(web.configuration.userContentController.userScripts.count == 2)
        // No fonts of one's own: no script at all, the page's own kept.
        PageAppearance.install(PageFonts(), in: web.configuration.userContentController)
        #expect(web.configuration.userContentController.userScripts.count == 1)
    }

    // The other app icons go light or dark with the Mac, as the Dock does,
    // whatever Theme Yab's own windows have.
    @MainActor @Test func appIconsFollowTheMacNotTheTheme() {
        #expect(AppIconStyle.dark(interfaceStyle: "Dark"))
        #expect(!AppIconStyle.dark(interfaceStyle: nil))
        #expect(!AppIconStyle.dark(interfaceStyle: "Light"))
        let theme = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = theme }
        let mac = AppIconStyle.systemDark
        NSApplication.shared.appearance = NSAppearance(named: mac ? .aqua : .darkAqua)
        #expect(AppIconStyle.systemDark == mac)
    }
}
