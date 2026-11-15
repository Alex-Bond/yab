import Foundation
import Testing
@testable import Fast

/// chrome.contentSettings onto Yab's per-site answers
/// (ExtensionContentSettings.swift): a pattern names one site or none, and
/// a setting set is read back from the store Site Controls reads.
@MainActor
@Suite(.serialized)
struct ExtensionContentSettingsTests {
    @Test func aPatternNamesOneSiteOrNone() {
        #expect(ExtensionContentSettings.site("https://example.com/*")?.origin == "https://example.com:443")
        #expect(ExtensionContentSettings.site("http://127.0.0.1:8080/*")?.origin == "http://127.0.0.1:8080")
        #expect(ExtensionContentSettings.site("*://example.com/*")?.host == "example.com")
        #expect(ExtensionContentSettings.site("*://*.example.com/*") == nil)
        #expect(ExtensionContentSettings.site("<all_urls>") == nil)
    }

    @Test func cameraSetIsReadBackAndClearedOnlyForItsSetter() throws {
        let url = try #require(URL(string: "https://settings-test.example/page"))
        let key = Browser.captureKey(try #require(Browser.origin(of: url)), .camera)
        defer { Store.settings.removeObject(forKey: key); Store.settings.removeObject(forKey: "extensions.contentSettings.test-ext") }
        #expect(ExtensionContentSettings.value("camera", for: url) == "ask")
        _ = try ExtensionContentSettings.run("contentSettings.camera.set", [["primaryPattern": "https://settings-test.example/*", "setting": "block"]], extensionID: "test-ext")
        #expect(Store.settings.object(forKey: key) as? Bool == false)
        #expect(ExtensionContentSettings.value("camera", for: url) == "block")
        _ = try ExtensionContentSettings.run("contentSettings.camera.clear", [[String: Any]()], extensionID: "test-ext")
        #expect(ExtensionContentSettings.value("camera", for: url) == "ask")
    }

    /// automaticDownloads is Site Controls' Automatic downloads: the answer
    /// a site was given about more files than a click asked for.
    @Test func automaticDownloadsIsSiteControlsAnswer() throws {
        let url = try #require(URL(string: "https://downloads-test.example/page"))
        defer {
            SiteDownloads.forgetMany("downloads-test.example")
            Store.settings.removeObject(forKey: "extensions.contentSettings.test-ext")
        }
        #expect(ExtensionContentSettings.value("automaticDownloads", for: url) == "ask")
        _ = try ExtensionContentSettings.run("contentSettings.automaticDownloads.set",
                                             [["primaryPattern": "https://downloads-test.example/*", "setting": "block"]], extensionID: "test-ext")
        #expect(SiteDownloads.many(for: "downloads-test.example") == false)
        #expect(ExtensionContentSettings.value("automaticDownloads", for: url) == "block")
        _ = try ExtensionContentSettings.run("contentSettings.automaticDownloads.set",
                                             [["primaryPattern": "https://downloads-test.example/*", "setting": "allow"]], extensionID: "test-ext")
        #expect(SiteDownloads.many(for: "downloads-test.example") == true)
        _ = try ExtensionContentSettings.run("contentSettings.automaticDownloads.clear", [[String: Any]()], extensionID: "test-ext")
        #expect(SiteDownloads.many(for: "downloads-test.example") == nil)
        #expect(ExtensionContentSettings.value("automaticDownloads", for: url) == "ask")
    }

    @Test func whatYabHasNoSwitchForIsSaidSo() {
        #expect(throws: (any Error).self) {
            try ExtensionContentSettings.run("contentSettings.javascript.set", [["primaryPattern": "https://a.example/*", "setting": "block"]], extensionID: "test-ext")
        }
        #expect(throws: (any Error).self) {
            try ExtensionContentSettings.run("contentSettings.popups.set", [["primaryPattern": "https://a.example/*", "setting": "ask"]], extensionID: "test-ext")
        }
    }
}
