import XCTest
@testable import YabPhone

/// What Yab says of an extension before it is added (Extensions/ExtensionCompatibility).
final class ExtensionCompatibilityTests: XCTestCase {
    private let worker: [String: Any] = ["manifest_version": 3, "background": ["service_worker": "bg.js"]]

    func testAWorkerWaitsForApplesBrowserEntitlement() {
        let verdict = ExtensionCompatibility.verdict(id: "x", manifest: worker, entitled: false)
        XCTAssertEqual(verdict.kind, .blocked)
        XCTAssertEqual(verdict.reason, ExtensionCompatibility.waitingForApple)
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "x", manifest: worker, entitled: true).kind, .works)
    }

    func testOneWithNoBackgroundWorksWithoutTheEntitlement() {
        let content: [String: Any] = ["manifest_version": 3, "content_scripts": [["matches": ["<all_urls>"], "js": ["c.js"]]]]
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "x", manifest: content, entitled: false).kind, .works)
    }

    func testWhatAPhoneLacksIsSaid() {
        var native = worker; native["permissions"] = ["storage", "nativeMessaging"]
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "x", manifest: native, entitled: true).kind, .limited)
        var capture = worker; capture["permissions"] = ["tabCapture", "desktopCapture"]
        let verdict = ExtensionCompatibility.verdict(id: "x", manifest: capture, entitled: true)
        XCTAssertEqual(verdict.kind, .limited)
        XCTAssertTrue(verdict.reason.contains("recording the screen"), verdict.reason)
    }

    func testWhatTheProbeFoundOverridesTheManifest() {
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "liecbddmkiiihnedobmlmillhodjkdmb", manifest: worker, entitled: true).kind, .blocked)  // Loom
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", manifest: worker, entitled: true).kind, .works)  // Dark Reader
        // Without Apple's entitlement even one that works waits.
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", manifest: worker, entitled: false).reason,
                       ExtensionCompatibility.waitingForApple)
        XCTAssertEqual(ExtensionCompatibility.known.count, 20)
    }

    func testDeveloperToolsOnlyAndAlwaysOnPagesAreNotOffered() {
        var devtools = worker; devtools["devtools_page"] = "devtools.html"
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "x", manifest: devtools, entitled: true).kind, .blocked)
        let persistent: [String: Any] = ["manifest_version": 2, "background": ["scripts": ["bg.js"], "persistent": true]]
        XCTAssertEqual(ExtensionCompatibility.verdict(id: "x", manifest: persistent, entitled: true).kind, .blocked)
    }
}
