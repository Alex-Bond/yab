import Foundation
import Testing
@testable import Fast

/// One ad blocker at a time (docs/ad-blocker-source.md): who blocks a tab,
/// the pause rule Yab gives an extension, reading the extension's own
/// pauses, and what Bring In reads from a blocker's LevelDB storage.
@MainActor
@Suite(.serialized)
struct BlockerSourceTests {
    // MARK: Shield.source

    @Test func extensionBlocksOnlyOnceHandedOver() {
        let shield = Shield.shared
        let before = shield.chosen
        let handsOver = shield.handsOver
        defer {
            shield.handsOver = handsOver
            shield.choose(before)
        }
        shield.handsOver = { _, persistent in persistent }
        shield.choose("ddkjiahejlhfcafbddmgiahcphecmpfh")
        // Chosen, rules not landed: Shield still blocks.
        #expect(shield.source == .builtIn)
        #expect(shield.blocker(persistent: true) == nil)
        shield.landed("ddkjiahejlhfcafbddmgiahcphecmpfh")
        #expect(shield.blocker(persistent: true) == "ddkjiahejlhfcafbddmgiahcphecmpfh")
        // A private tab the extension isn't allowed in keeps Shield.
        #expect(shield.blocker(persistent: false) == nil)
        // Another extension's compile changes nothing.
        shield.landed("gighmmpiobklfepjocnamgkkbiglidom")
        #expect(shield.source == .extension("ddkjiahejlhfcafbddmgiahcphecmpfh"))
        // Its rules failing: Built-in, and the warning.
        shield.fellBack("ddkjiahejlhfcafbddmgiahcphecmpfh", failed: true)
        #expect(shield.source == .builtIn)
        #expect(shield.failed == "ddkjiahejlhfcafbddmgiahcphecmpfh")
        shield.choose(nil)
        #expect(shield.failed == nil)
        #expect(shield.chosen == nil)
    }

    // MARK: several at once

    /// Two blockers arriving together: the card offers the lightest,
    /// whichever finished installing first.
    @Test func offersTheLightestWhateverTheOrder() {
        let ubol = "ddkjiahejlhfcafbddmgiahcphecmpfh", adguard = "bgnkhhnnamicmpeenaelnjfhikgbkllg"
        let adblock = "gighmmpiobklfepjocnamgkkbiglidom"
        #expect(Blockers.preferred([adguard, ubol]) == ubol)
        #expect(Blockers.preferred([ubol, adguard]) == ubol)
        #expect(Blockers.preferred([adblock, adguard]) == adguard)
        #expect(Blockers.preferred([adguard, adblock, ubol]) == ubol)
        // One Yab doesn't know comes after the ones it does, else the first.
        #expect(Blockers.preferred(["aaaabbbbccccddddeeeeffffgggghhhh", adblock]) == adblock)
        #expect(Blockers.preferred(["aaaabbbbccccddddeeeeffffgggghhhh", "hhhhggggffffeeeeddddccccbbbbaaaa"]) == "aaaabbbbccccddddeeeeffffgggghhhh")
        #expect(Blockers.preferred([]) == nil)
    }

    /// The welcome's Bring answered before the blockers came: each takes
    /// that answer as it lands, and then it is gone.
    @Test func welcomeAnswersAhead() {
        let ubol = "ddkjiahejlhfcafbddmgiahcphecmpfh", adguard = "bgnkhhnnamicmpeenaelnjfhikgbkllg"
        Blockers.decideAhead(builtIn: true, among: [adguard, ubol])
        #expect(Blockers.answeredAhead("aaaabbbbccccddddeeeeffffgggghhhh") == nil)
        #expect(Blockers.answeredAhead(ubol) == .builtIn)
        #expect(Blockers.answeredAhead(adguard) == .builtIn)
        #expect(Blockers.answeredAhead(ubol) == nil)
        // Its own kept: the lightest is picked, the other stays off.
        Blockers.decideAhead(builtIn: false, among: [adguard, ubol])
        #expect(Blockers.answeredAhead(adguard) == .keep)
        #expect(Blockers.answeredAhead(ubol) == .pick(ubol))
        #expect(Blockers.answeredAhead(adguard) == nil)
    }

    // MARK: the pause rule

    @Test func pauseRuleShape() {
        let rule = Blockers.pauseRule("theverge.com")
        let id = rule["id"] as? Int ?? 0
        #expect(id >= Blockers.firstRule && id < Blockers.firstRule + Blockers.rules)
        #expect(id == Blockers.ruleID("theverge.com"))
        #expect(id != Blockers.ruleID("example.com"))
        #expect((rule["action"] as? [String: Any])?["type"] as? String == "allowAllRequests")
        let condition = rule["condition"] as? [String: Any] ?? [:]
        #expect(condition["requestDomains"] as? [String] == ["theverge.com"])
        #expect(condition["resourceTypes"] as? [String] == ["main_frame", "sub_frame"])
        #expect((rule["priority"] as? Int ?? 0) >= 1)
        // Its own rule is read back as off for that site.
        #expect(Blockers.allowedHosts(rule) == ["theverge.com"])
    }

    @Test func readsTheExtensionsOwnPauses() {
        let byDomains: [String: Any] = ["id": 1, "action": ["type": "allowAllRequests"],
                                        "condition": ["requestDomains": ["News.example"], "resourceTypes": ["main_frame"]]]
        let byFilter: [String: Any] = ["id": 2, "action": ["type": "allowAllRequests"],
                                       "condition": ["urlFilter": "||shop.example^", "resourceTypes": ["main_frame"]]]
        let block: [String: Any] = ["id": 3, "action": ["type": "block"], "condition": ["urlFilter": "||ads.example^"]]
        #expect(Blockers.allowedHosts(byDomains) == ["news.example"])
        #expect(Blockers.allowedHosts(byFilter) == ["shop.example"])
        #expect(Blockers.allowedHosts(block).isEmpty)
    }

    @Test func knowsBlockersByIdAndRules() throws {
        #expect(Blockers.isBlocker("ddkjiahejlhfcafbddmgiahcphecmpfh", folder: URL(fileURLWithPath: "/nonexistent")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-blocker-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Big", "version": "1", "permissions": ["declarativeNetRequest"],
                                       "declarative_net_request": ["rule_resources": [["id": "a", "enabled": true, "path": "rules.json"]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let rule = #"{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"x"}}"#
        try ("[" + Array(repeating: rule, count: 10_001).joined(separator: ",") + "]").write(to: folder.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        #expect(Blockers.isBlocker("aaaabbbbccccddddeeeeffffgggghhhh", folder: folder))
        try ("[" + Array(repeating: rule, count: 50).joined(separator: ",") + "]").write(to: folder.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        #expect(!Blockers.isBlocker("aaaabbbbccccddddeeeeffffgggghhhh", folder: folder))
    }

    // MARK: what Bring In reads

    @Test func readsSitesAndHidingFromValues() {
        let kept = BlockerKept.from([
            "netWhitelist": Data(#""chrome-extension-scheme\nhttps://www.Example.com/path\nnews.example\n/regex/""#.utf8),
            "filteringModeDetails": Data(#"{"none":["shop.example"],"optimal":["all-urls"]}"#.utf8),
            "userFilters": Data(#""! mine\nexample.org##.cookie-bar\nsite.example,~sub.site.example##div.promo\n##.generic\nexample.org#@#.ad\n@@||allowed.example^$document\n||tracker.example^\n/banner/*$image""#.utf8),
        ])
        #expect(kept.sites == ["allowed.example", "example.com", "news.example", "shop.example"])
        #expect(kept.hiding == [BlockerKept.Hide(host: "example.org", selector: ".cookie-bar"),
                                BlockerKept.Hide(host: "site.example", selector: "div.promo")])
        #expect(kept.blocking == 2)
        #expect(kept.line == "With its 4 trusted sites and 2 hiding rules.")
    }

    @Test func snappyDecompresses() {
        // "abc", then a copy of 9 from 3 back.
        let input: [UInt8] = [12, 8, 97, 98, 99, 21, 3]
        #expect(Snappy.decompress(input) == Array("abcabcabcabc".utf8))
        #expect(Snappy.decompress([5, 0, 97]) == nil)
    }

    @Test func readsALevelDBFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-leveldb-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A table holding netWhitelist at sequence 1, and "gone" at 2.
        func varint(_ value: Int) -> [UInt8] {
            var value = value, out: [UInt8] = []
            while value >= 0x80 { out.append(UInt8(value & 0x7f | 0x80)); value >>= 7 }
            return out + [UInt8(value)]
        }
        func internalKey(_ key: String, _ sequence: UInt64, _ kind: UInt64) -> [UInt8] {
            let tail = sequence << 8 | kind
            return Array(key.utf8) + (0..<8).map { UInt8(tail >> (8 * UInt64($0)) & 0xff) }
        }
        func block(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
            var out: [UInt8] = []
            for (key, value) in entries { out += varint(0) + varint(key.count) + varint(value.count) + key + value }
            return out + [0, 0, 0, 0] + [1, 0, 0, 0]
        }
        let data = block([(internalKey("gone", 2, 1), Array(#""old""#.utf8)),
                          (internalKey("netWhitelist", 1, 1), Array(#""table.example""#.utf8))])
        var file = data + [0, 0, 0, 0, 0]
        let handle = varint(0) + varint(data.count)
        let index = block([(internalKey("zzz", 9, 1), handle)])
        let indexOffset = file.count
        file += index + [0, 0, 0, 0, 0]
        var footer = varint(0) + varint(0) + varint(indexOffset) + varint(index.count)
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        footer += [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb]
        file += footer
        try Data(file).write(to: folder.appendingPathComponent("000005.ldb"))

        // The log: "gone" deleted at 3, filteringModeDetails put at 4.
        var batch: [UInt8] = (0..<8).map { UInt8(3 >> (8 * $0) & 0xff) } + [2, 0, 0, 0]
        batch += [0] + varint(4) + Array("gone".utf8)
        let value = Array(#"{"none":["log.example"]}"#.utf8)
        batch += [1] + varint(20) + Array("filteringModeDetails".utf8) + varint(value.count) + value
        let record: [UInt8] = [0, 0, 0, 0, UInt8(batch.count & 0xff), UInt8(batch.count >> 8), 1] + batch
        try Data(record).write(to: folder.appendingPathComponent("000006.log"))

        let values = LevelDB.read(folder)
        #expect(values["gone"] == nil)
        #expect(values["netWhitelist"].map { String(decoding: $0, as: UTF8.self) } == #""table.example""#)
        #expect(BlockerKept.from(values).sites == ["log.example", "table.example"])
    }
}
