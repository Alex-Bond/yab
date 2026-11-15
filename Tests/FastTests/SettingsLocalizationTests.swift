import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fast

/// Exercises shipped English resources without changing system preferences.
struct SettingsLocalizationTests {
    private static var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization")
    }

    private func english() throws -> Bundle {
        try #require(Bundle(url: Self.resources.appendingPathComponent("en.lproj")))
    }

    @Test func onlyEnglishSettingsResourcesShip() throws {
        let languages = try FileManager.default.contentsOfDirectory(atPath: Self.resources.path)
            .filter { $0.hasSuffix(".lproj") }
        #expect(languages == ["en.lproj"])
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("en.lproj/Settings.strings"))
        let table = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        #expect(table.count >= 300)
        for (key, value) in table {
            #expect(value == key, "The English table preserves literal text: \(key)")
        }
        for page in SettingsPage.allCases {
            #expect(table[page.englishTitle] == page.englishTitle)
        }
    }

    @Test func realBundleLookupAndMissingKeyFallback() throws {
        let en = try english()
        #expect(SettingsWords.text("Search", bundle: en) == "Search")
        #expect(SettingsWords.text("Unknown setting", bundle: en) == "Unknown setting")
        #expect(SettingsWords.text("", bundle: en).isEmpty)
        #expect(SettingsWords.text("Claude", bundle: en) == "Claude")
        #expect(SettingsWords.format("Opens %@", ["Spaces"], bundle: en) == "Opens Spaces")
        #expect(SettingsWords.format("Suggest searches from %@", ["Google"], bundle: en) == "Suggest searches from Google")
        #expect(SettingsWords.format("Yab %@ is available", ["0.99.0"], bundle: en) == "Yab 0.99.0 is available")
        #expect(SettingsWords.format("%ld cards", [3], bundle: en) == "3 cards")
    }

    @MainActor @Test func sharedSettingsRenderingKeepsEnglishLabels() throws {
        _ = NSApplication.shared
        let en = try english()
        let row = SettingsRow("Search with", detail: "Default browser", bundle: en) { Text("Google") }
        #expect(row.title == "Search with" && row.detail == "Default browser")
        let person = SettingsRow(verbatim: "Search", detail: "Default browser", bundle: en) { Text("fixture") }
        #expect(person.title == "Search" && person.detail == "Default browser")
        #expect(SettingsNote("Every page you've opened, from the first one", bundle: en).text == "Every page you've opened, from the first one")
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 100)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }

    @MainActor @Test func englishSearchKeepsSettingIDsAndAliases() throws {
        let en = try english()
        let item = SettingsItem(id: "search-engine", page: .search, title: "Search with", words: "search engine google")
        #expect(item.score("Search with", bundle: en) != nil)
        #expect(item.score("google", bundle: en) != nil)
        #expect(item.id == "search-engine" && item.page.rawValue == "search")
        #expect(SettingsPage.privacy.found("Privacy", bundle: en) != nil)
        #expect(SettingsResult.search("Search", bundle: en).rows.contains(.page(.search)))
    }

    @Test func nativeBundleFallsBackToEnglishForOtherLanguagePreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-settings-english-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        let target = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.yab.settings.english", "CFBundlePackageType": "BNDL",
                                   "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: Self.resources.appendingPathComponent("en.lproj"),
                                        to: target.appendingPathComponent("en.lproj"))
        let bundle = try #require(Bundle(url: root))
        // Foundation can list a language from both metadata and its directory.
        #expect(Set(bundle.localizations) == ["en"])
        for preference in ["ja", "es"] {
            #expect(Set(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [preference])) == ["en"])
        }
        #expect(SettingsWords.text("Privacy", bundle: bundle) == "Privacy")
        #expect(SettingsWords.text("Unknown setting", bundle: bundle) == "Unknown setting")
    }
}
