import Foundation
import Testing
@testable import Fast

struct EngineStorageCarryTests {
    @Test func anOriginIsSchemeHostAndPort() {
        #expect(EngineStorageCarry.origin(of: URL(string: "HTTPS://App.Example.com/path?q=1#x")!) == "https://app.example.com")
        #expect(EngineStorageCarry.origin(of: URL(string: "http://localhost:8080/")!) == "http://localhost:8080")
        #expect(EngineStorageCarry.origin(of: URL(string: "about:blank")!) == nil)
        #expect(EngineStorageCarry.origin(of: URL(string: "yab://mail")!) == nil)
        #expect(EngineStorageCarry.origin(of: URL(string: "chrome-extension://abc/page.html")!) == nil)
    }

    @Test func webKitsRecordsAreNamedByRegistrableDomainOrHost() {
        let known: Set = ["example.co.uk", "127.0.0.1", "localhost"]
        #expect(EngineStorageCarry.listed("app.example.co.uk", in: known))
        #expect(EngineStorageCarry.listed("example.co.uk", in: known))
        #expect(EngineStorageCarry.listed("127.0.0.1", in: known))
        #expect(EngineStorageCarry.listed("a.b.localhost", in: known))
        #expect(!EngineStorageCarry.listed("notexample.co.uk", in: known))
        #expect(!EngineStorageCarry.listed("example.com", in: known))
    }

    @Test func theEngineThatUsedAnOriginLastIsTheSource() {
        // The same engine again: nothing to carry.
        #expect(EngineStorageCarry.source(last: .chromium, opening: .chromium, webKitHasIt: true) == nil)
        #expect(EngineStorageCarry.source(last: .webKit, opening: .webKit, webKitHasIt: false) == nil)
        // The other engine used it last, whatever WebKit's records say.
        #expect(EngineStorageCarry.source(last: .webKit, opening: .chromium, webKitHasIt: false) == .webKit)
        #expect(EngineStorageCarry.source(last: .chromium, opening: .webKit, webKitHasIt: true) == .chromium)
        // Never seen here: the past is WebKit's, if it holds anything.
        #expect(EngineStorageCarry.source(last: nil, opening: .chromium, webKitHasIt: true) == .webKit)
        #expect(EngineStorageCarry.source(last: nil, opening: .chromium, webKitHasIt: false) == nil)
        #expect(EngineStorageCarry.source(last: nil, opening: .webKit, webKitHasIt: true) == nil)
    }

    /// The ledger file names no origin: one written before is changed on
    /// reading, and the same origin finds its row again by its key.
    @Test func theLedgerNamesNoOrigin() throws {
        let (salt, rows) = EngineStorageCarry.rows(["https://mail.example.test": "chromium", "http://localhost:8080": "webKit"])
        #expect(!salt.isEmpty)
        #expect(rows.count == 2)
        #expect(!rows.keys.contains { $0.contains("example") || $0.contains("localhost") })
        #expect(rows[EngineStorageCarry.key("https://mail.example.test", salt: salt)] == "chromium")
        // Read again from what was saved: the same rows, the same salt.
        let again = EngineStorageCarry.rows(rows.merging(["salt": salt]) { row, _ in row })
        #expect(again.salt == salt && again.rows == rows)
        // Another ledger's salt names the same origin differently.
        #expect(EngineStorageCarry.key("https://mail.example.test", salt: "a") != EngineStorageCarry.key("https://mail.example.test", salt: "b"))
    }

    /// A space whose own id was taken has its folder under another: its
    /// ledgers are named by both, and a sweep by one id twice missed them.
    @Test func aLedgerIsNamedByThePhysicalFolderAndTheLogicalStore() {
        let logical = UUID(), physical = UUID()
        let named = EngineStorageCarry.ledger(profile: physical.uuidString, store: logical)
        #expect(named != EngineStorageCarry.ledger(profile: logical.uuidString, store: logical))
        #expect(named != EngineStorageCarry.ledger(profile: physical.uuidString, store: physical))
        #expect(named.lastPathComponent.hasSuffix(".storage.json"))
    }

    /// Signed out on WebKit while a Chromium page of the site stayed open with
    /// the old account: another Chromium page of it must not make Chromium the
    /// newer side, or the next WebKit page would get the old account back.
    @Test func aPageOpenOnTheDestinationLeavesTheLedgerAsItWas() {
        #expect(EngineStorageCarry.step(last: .webKit, opening: .chromium, webKitHasIt: true, openThere: true) == .leave)
        #expect(EngineStorageCarry.step(last: .chromium, opening: .webKit, webKitHasIt: true, openThere: true) == .leave)
        #expect(EngineStorageCarry.step(last: nil, opening: .chromium, webKitHasIt: true, openThere: true) == .leave)
        // Nothing open there: carried.
        #expect(EngineStorageCarry.step(last: .webKit, opening: .chromium, webKitHasIt: false, openThere: false) == .carry(from: .webKit))
        // Nothing to carry from anywhere: the engine opening it is where it lives.
        #expect(EngineStorageCarry.step(last: nil, opening: .chromium, webKitHasIt: false, openThere: true) == .remember)
        #expect(EngineStorageCarry.step(last: nil, opening: .webKit, webKitHasIt: true, openThere: false) == .remember)
    }
}
