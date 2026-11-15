import Foundation
import SQLite3
import Testing
@testable import Fast

/// No persisted import choice or keychain ACL is permission to inspect a
/// credential store. The same fixture becomes readable for a fresh import.
@Suite(.serialized)
struct CredentialBoundaryTests {
    private func fixture() throws -> ImportFixture {
        let fixture = ImportFixture()
        try fixture.json("Default/Preferences", [:])
        try fixture.json("Local State", ["profile": ["info_cache": ["Default": ["name": "Private name"]]]])
        for name in ["Login Data", "Login Data For Account"] {
            let db = try fixture.database("Default/" + name, """
                CREATE TABLE logins(origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER, date_last_used INTEGER);
                INSERT INTO logins VALUES('https://credential.test','person',X'00',0,0);
                """)
            sqlite3_close(db)
        }
        let wallet = try fixture.database("Default/Web Data", "CREATE TABLE local_addresses(id TEXT); INSERT INTO local_addresses VALUES('one');")
        sqlite3_close(wallet)
        let cookies = try fixture.database("Default/Network/Cookies", "CREATE TABLE cookies(host_key TEXT,has_expires INTEGER,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER); INSERT INTO cookies VALUES('.credential.test',0,0,1,1);")
        sqlite3_close(cookies)
        return fixture
    }

    @Test func discoveryAndCountsDoNotReadCredentials() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        var source = Chromium.known[1]
        source.dataRoot = fixture.root
        Chromium.standInKeys.withLock { $0[fixture.root.path] = "previously-allowed-key" }
        defer { Chromium.standInKeys.withLock { $0[fixture.root.path] = nil } }
        #expect(throws: Chromium.Trouble.self) { try Chromium.read(source, quiet: true) }
        #expect(throws: Chromium.Trouble.self) { try Chromium.cookiesByProfile(in: source) }
        #expect(try Chromium.wallet(source, quiet: true).addresses.isEmpty)
        #expect(source.profiles.map(\.lastPathComponent) == ["Default"])
        #expect(source.files.isEmpty)
        #expect(source.lastUsed == nil)
        #expect(BringStamp.stamps(source).isEmpty)
        let tally = BringTally.read(source, Set(BringPart.allCases))
        #expect(tally.passwords == nil && tally.cookies == nil && tally.cards == nil)
        #expect(Chromium.loginCount(source) == 0)
        #expect(Chromium.walletCount(source).addresses == 0)
        #expect(Chromium.cookieCount(source) == 0)
        #expect(Chromium.cookieTally(source).live == 0)
        #expect(TabImport.profileNames(in: source) == ["Default": "Default"])
        #expect(try TabImport.places(in: source).isEmpty)
        #expect(DiaTabsDB.places(source, ask: false) == nil)
        #expect(Chromium.safeStorage(source, quiet: true) == nil)
    }

    @Test func importCapabilityIsLocalToTheSelectedOperation() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        var source = Chromium.known[1]
        source.dataRoot = fixture.root
        let importing = source.authorizingImport()
        #expect(!source.credentialAccess)
        #expect(Chromium.loginCount(importing) == 1)
        #expect(Chromium.walletCount(importing).addresses == 1)
        #expect(Chromium.cookieCount(importing) == 1)
        #expect(TabImport.profileNames(in: importing) == ["Default": "Private name"])
        #expect(!BringStamp.stamps(importing).isEmpty)
        var redirected = importing
        redirected.dataRoot = fixture.root.appendingPathComponent("another-browser")
        #expect(!redirected.credentialAccess)
        #expect(Chromium.loginCount(source) == 0)
        #expect(BringStamp.stamps(source).isEmpty)
    }

    @MainActor @Test func openingBringInKeepsCountsUnknown() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        var source = Chromium.known[1]
        source.dataRoot = fixture.root
        let bringing = Bringing()
        bringing.chosen = source
        #expect(bringing.current.passwords == nil)
        #expect(bringing.current.cards == nil)
        #expect(bringing.current.cookies == nil)
        #expect(bringing.current.tabPlaces == nil)
    }

    @MainActor @Test func bringReadsCountsBeforeAnswerAndDoesNotGrantLaterDiscovery() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try fixture.write("Default/Last Session", ChromiumSessionTests.session)
        var source = Chromium.known[1]
        source.dataRoot = fixture.root
        Chromium.standInKeys.withLock { $0[fixture.root.path] = "fixture-key" }
        defer { Chromium.standInKeys.withLock { $0[fixture.root.path] = nil } }
        let bringing = Bringing()
        bringing.chosen = source
        let browser = Browser()
        #expect(bringing.current.passwords == nil)
        let answer = await withCheckedContinuation { continuation in
            bringing.bring(into: browser) { answer in
                continuation.resume(returning: answer)
                // Stop after reading, before saving credentials or installing extensions.
                return false
            }
        }
        #expect(answer == .allowed)
        #expect(bringing.current.passwords == 1)
        #expect(bringing.current.cookies == 1)
        #expect(bringing.current.addresses == 1)
        #expect(bringing.current.tabPlaces?.isEmpty == false)
        #expect(Chromium.loginCount(source) == 0)
        #expect(Chromium.safeStorage(source, quiet: true) == nil)
    }

}
