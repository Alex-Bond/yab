import Foundation
import Testing
@testable import Fast

struct ChromiumSwitchCookiesTests {
    private func cookie(_ value: String) -> ChromiumDRMCookie {
        ChromiumDRMCookie(HTTPCookie(properties: [.name: "session", .value: value, .domain: "switch.test", .path: "/",
            .discard: "TRUE", .sameSitePolicy: "lax"])!)
    }

    @Test func restartRetainsBothDirectionsOfSignOut() throws {
        let saved = cookie("synthetic-account")
        let map = [saved.key: saved]
        let ledger = ChromiumSwitchCookieLedger(webKit: ChromiumSwitchCookieLedger.fingerprint(map),
                                                chromium: ChromiumSwitchCookieLedger.fingerprint(map))
        let restarted = try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: JSONEncoder().encode(ledger))
        let webKitSignOut = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: map, previous: restarted)
        #expect(webKitSignOut.toWebKit.isEmpty)
        #expect(webKitSignOut.toChromium.count == 1 && webKitSignOut.toChromium[0].cookie == nil)
        let chromiumSignOut = ChromiumDRMCookieMerge.plan(webKit: map, chromium: [:], previous: restarted)
        #expect(chromiumSignOut.toChromium.isEmpty)
        #expect(chromiumSignOut.toWebKit.count == 1 && chromiumSignOut.toWebKit[0].cookie == nil)
    }

    @Test func restartCopiesEditsAndKeepsTheExistingConflictPolicy() {
        let saved = cookie("before"), edited = cookie("after"), remote = cookie("concurrent")
        let hashes = ChromiumSwitchCookieLedger.fingerprint([saved.key: saved])
        let ledger = ChromiumSwitchCookieLedger(webKit: hashes, chromium: hashes)
        let plan = ChromiumDRMCookieMerge.plan(webKit: [saved.key: edited], chromium: [saved.key: remote], previous: ledger)
        #expect(plan.toWebKit.isEmpty)
        #expect(plan.toChromium.count == 1 && plan.toChromium[0].cookie == edited)
        let remoteOnly = ChromiumDRMCookieMerge.plan(webKit: [saved.key: saved], chromium: [saved.key: edited], previous: ledger)
        #expect(remoteOnly.toChromium.isEmpty)
        #expect(remoteOnly.toWebKit.count == 1 && remoteOnly.toWebKit[0].cookie == edited)
    }

    @Test func savedLedgerContainsNoCookieValuesAndIsPrivate() throws {
        let saved = cookie("synthetic-secret-not-for-ledger")
        let hashes = ChromiumSwitchCookieLedger.fingerprint([saved.key: saved])
        let ledger = ChromiumSwitchCookieLedger(webKit: hashes, chromium: hashes)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("cookie-ledger.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ledger.save(to: file)
        let bytes = try Data(contentsOf: file)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(saved.value))
        #expect(try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: bytes) == ledger)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
