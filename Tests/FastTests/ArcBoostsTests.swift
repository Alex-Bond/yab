import Foundation
import Testing
@testable import Fast

// Arc's boosts as Yab boosts (ArcBoosts, register #447), from folders laid
// out as Arc writes them.
struct ArcBoostsTests {
    static func folder(css: String, js: String = "", scope: String = "twitter.com", enabled: Bool = true,
                       matches: [String] = ["*://*.twitter.com/*"]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arc-boost-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": "My twitter.com Style Boost", "description": "", "version": "0.0.1", "manifest_version": 3,
                                       "content_scripts": [["matches": matches, "css": ["styles.css"], "js": ["content.js"]]], "permissions": []]
        let config: [String: Any] = ["pinned": false, "id": "cca9efaa-191f-4392-a96b-99db84d19186", "scope": scope,
                                     "components": ["contentScript": ["path": "content.js", "enabled": true],
                                                    "contentStylesheet": ["path": "styles.css", "enabled": true]],
                                     "extensionEnabled": enabled, "name": "My twitter.com Style Boost"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: config).write(to: folder.appendingPathComponent("boost.config.json"))
        try css.write(to: folder.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
        try js.write(to: folder.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func aStyleBoostComesAsALookForTheSiteWhereItLivesNow() throws {
        let css = "\\[data-testid=\"tweetText\"] {\n  line-height: 150% !important;\n}\n.r-1 { background: url(https://x.example/a.png); }\nbody { background-color: #0f0f0f !important; }"
        let found = try #require(ArcBoosts.read(Self.folder(css: css)))
        #expect(found.id == "arc-twitter-com-cca9efaa")
        #expect(found.sites == ["twitter.com", "www.twitter.com", "x.com", "www.x.com"])
        #expect(found.rung == .look)
        #expect(found.enabled)
        #expect(found.dropped == 1)
        let style = try #require(found.files["style.css"])
        #expect(style.hasPrefix("[data-testid=\"tweetText\"]"))
        #expect(!style.contains("url("))
        let package = try BoostPackage.read(id: found.id, files: found.files, sites: found.sites)
        #expect(package.matches(URL(string: "https://x.com/home")!))
        #expect(!package.matches(URL(string: "https://example.com/")!))
    }

    @Test func aScriptMakesItAPageBoostAndOffStaysOff() throws {
        let found = try #require(ArcBoosts.read(Self.folder(css: "", js: "document.body.dataset.arc = 'ran';", enabled: false)))
        #expect(found.rung == .page)
        #expect(!found.enabled)
        #expect(found.files["content.js"] != nil)
        #expect(found.files["style.css"] == nil)
    }

    @Test func unreadableCodeIsLeftOutAndAnEmptyBoostIsNot() throws {
        let kept = try #require(ArcBoosts.read(Self.folder(css: ".a { color: red; }", js: "eval('1')")))
        #expect(kept.rung == .look)
        #expect(kept.scriptLeft)
        #expect(ArcBoosts.read(try Self.folder(css: "  \n", js: "\n")) == nil)
    }

    @Test func sitesAreExactAndEverySiteStaysEverySite() {
        #expect(ArcBoosts.sites(scope: "www.github.com", matches: []) == ["github.com", "www.github.com"])
        #expect(ArcBoosts.sites(scope: nil, matches: ["<all_urls>"]) == ["<all_urls>"])
        #expect(ArcBoosts.sites(scope: "not a host", matches: []).isEmpty)
    }
}
