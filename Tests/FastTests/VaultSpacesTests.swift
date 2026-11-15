import Foundation
import Security
import Testing
import SyncKit
@testable import Fast

/// Logins and the Space they were saved in (#260b): each new one tagged
/// with its Space, the list under a sign-in box this Space's first and
/// another Space's after, dimmed, under "Other Spaces". Nothing hidden, an
/// untagged login shared, and the tag riding along in sync. No keychain is
/// touched: the attributes a save writes and the rows a list call returns
/// are checked as dictionaries.
@MainActor
struct VaultSpacesTests {
    init() { SyncShapes.register() }

    private let home = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let work = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var names: [UUID: String] { [home: "🏠 Home", work: "💼 Work"] }

    private func login(_ user: String, _ space: UUID?, used: Double, host: String = "example.com") -> Login {
        Login(host: host, user: user, password: "pw-" + user, used: Date(timeIntervalSince1970: used), space: space)
    }

    // MARK: tagging

    @Test func aNewLoginIsTaggedWithItsSpaceAndAnUpdateKeepsTheTag() {
        let data = Data("hunter2".utf8)
        let fresh = Vault.written(data, used: nil, clear: false, space: work, synced: false)
        #expect(fresh.add[Vault.spaceKey] as? String == work.uuidString)
        // Signed in to from another Space, or touched when used: the item
        // stays the Space it was saved in.
        #expect(fresh.update[Vault.spaceKey] == nil)
        // A record from another Mac carries its Space onto the item here.
        let synced = Vault.written(data, used: nil, clear: false, space: work, synced: true)
        #expect(synced.update[Vault.spaceKey] as? String == work.uuidString)
        // No Space: nothing written, an item from before stays shared.
        let shared = Vault.written(data, used: Date(), clear: true, space: nil, synced: true)
        #expect(shared.add[Vault.spaceKey] == nil && shared.update[Vault.spaceKey] == nil)
        #expect(shared.update[kSecAttrComment as String] != nil)
    }

    @Test func theTagIsNotPartOfTheItemsIdentity() {
        // The description is an ordinary attribute of an internet password:
        // tagging one never makes a second item beside it.
        #expect(Vault.spaceKey == kSecAttrDescription as String)
        #expect(Vault.spaceKey != kSecAttrServer as String && Vault.spaceKey != kSecAttrAccount as String
            && Vault.spaceKey != kSecAttrSecurityDomain as String && Vault.spaceKey != kSecAttrProtocol as String)
    }

    @Test func listedRowsReadTheTagAndUntaggedOnesAreShared() {
        let rows: [[String: Any]] = [
            [kSecAttrServer as String: "example.com", kSecAttrAccount as String: "ann", Vault.spaceKey: work.uuidString],
            [kSecAttrServer as String: "example.com", kSecAttrAccount as String: "bob"],
            // Something else's description, never taken for a Space.
            [kSecAttrServer as String: "example.com", kSecAttrAccount as String: "cat", Vault.spaceKey: "Web form password"],
        ]
        let listed = Vault.listed(from: rows)
        #expect(listed.map(\.user) == ["ann", "bob", "cat"])
        #expect(listed.map(\.space) == [work, nil, nil])
    }

    // MARK: ordering

    @Test func thisSpacesLoginsComeFirstAndTheOthersAfterDimmed() {
        let logins = [
            login("work@example.com", work, used: 40),
            login("shared@example.com", nil, used: 30),
            login("home@example.com", home, used: 20),
            // A Space this Mac doesn't have: another Mac's, or deleted.
            login("gone@example.com", UUID(), used: 10),
        ]
        let rows = SuggestRows.build(.init(yab: logins, host: "example.com", here: home, spaces: names))
        #expect(rows.map(\.title) == ["shared@example.com", "home@example.com", "gone@example.com", "work@example.com", "All Passwords"])
        #expect(rows.map(\.away) == [nil, nil, nil, "💼 Work", nil])
        let away = rows[3]
        #expect(away.detail == "💼 Work · example.com")
        #expect(away.group != rows[0].group && away.pickable)
        // Return takes this Space's first one.
        #expect(rows.firstIndex(where: \.pickable) == 0)
    }

    @Test func nothingIsHiddenAndAnotherSpacesLoneLoginIsStillOffered() {
        let rows = SuggestRows.build(.init(yab: [login("work@example.com", work, used: 1)], host: "example.com", here: home, spaces: names))
        #expect(rows.count == 1)
        #expect(rows[0].quick && rows[0].away == "💼 Work")
    }

    @Test func untaggedLoginsAreSharedAndNoSpaceMeansNoneIsAway() {
        let shared = login("shared@example.com", nil, used: 1)
        #expect(SuggestRows.away(shared, here: home, spaces: names) == nil)
        #expect(SuggestRows.away(shared, here: work, spaces: names) == nil)
        // Mail's Space or Spaces off: every login is this one's.
        #expect(SuggestRows.away(login("w", work, used: 1), here: nil, spaces: names) == nil)
        #expect(SuggestRows.away(login("w", work, used: 1), here: home, spaces: names) == "💼 Work")
    }

    @Test func theSameNameKeptInTwoSpacesIsThisSpacesOneRow() {
        let logins = [login("me@example.com", work, used: 9), login("me@example.com", home, used: 1, host: "accounts.example.com")]
        let rows = SuggestRows.build(.init(yab: logins, host: "example.com", here: home, spaces: names))
        let accounts = rows.filter { if case .yab = $0.kind { return true }; return false }
        #expect(accounts.count == 1)
        #expect(accounts.first?.away == nil && accounts.first?.host == "accounts.example.com")
    }

    @Test func hereFirstKeepsEachGroupsOrder() {
        let logins = [login("w1", work, used: 4), login("h1", home, used: 3), login("w2", work, used: 2), login("s", nil, used: 1)]
        #expect(SuggestRows.hereFirst(logins, here: home, spaces: names).map(\.user) == ["h1", "s", "w1", "w2"])
        #expect(SuggestRows.hereFirst(logins, here: nil, spaces: names).map(\.user) == ["w1", "h1", "w2", "s"])
    }

    @Test func anotherSpacesLoginsComeAfterAManagersBeside() {
        let managed = ManagerVault.Login(provider: "bitwarden", item: "b1", title: "Example", user: "vault@example.com", urls: ["https://example.com"])
        let rows = SuggestRows.build(.init(yab: [login("work@example.com", work, used: 2), login("home@example.com", home, used: 1)],
                                           managers: [.init(provider: "bitwarden", logins: [managed])], host: "example.com",
                                           here: home, spaces: names))
        #expect(rows.map(\.title).prefix(3) == ["home@example.com", "vault@example.com", "work@example.com"])
        #expect(rows[2].detail == "💼 Work · Saved in Yab")
    }

    // MARK: sync

    @Test func theTagRidesAlongInSyncAndAnOlderRecordLeavesItAlone() throws {
        let id = "example.com\u{1}me@example.com"
        let key = SyncKit.Record.Key(collection: SyncWallet.login, id: id)
        let seal = Seal.make()
        let listed = Vault.Listed(host: "example.com", user: "me@example.com", used: nil, modified: nil, clear: false, space: work)
        var fields = SyncWallet.fields(listed, password: "pw")
        #expect(fields["space"] == .string(work.uuidString))
        fields["secret"] = .string(try seal.hide(Data("pw".utf8), in: key))

        // A to B: the Space comes out the other side.
        let a = try Journal(path: nil, device: "a"), b = try Journal(path: nil, device: "b")
        try a.reconcile(SyncWallet.login, [id: fields])
        let written = try #require(a.record(key))
        _ = try b.receive([(record: written, version: 1)])
        let there = try #require(b.record(key))
        #expect(SyncWallet.space(of: there) == work)
        #expect(SyncWallet.same(SyncWallet.fields(listed, password: "pw"), there, key, seal))

        // An untagged login sends no Space at all.
        let plain = SyncWallet.fields(Vault.Listed(host: "example.com", user: "me@example.com", used: nil, modified: nil, clear: false), password: "pw")
        #expect(plain["space"]?.isNull ?? true)

        // A Mac from before wrote the record again, without the Space: the
        // one kept here reads as the same, so the two never trade turns.
        var older = fields
        older["space"] = nil
        let c = try Journal(path: nil, device: "c")
        try c.reconcile(SyncWallet.login, [id: older])
        let old = try #require(c.record(key))
        #expect(SyncWallet.space(of: old) == nil)
        #expect(SyncWallet.same(SyncWallet.fields(listed, password: "pw"), old, key, seal))
        // A different Space is a change.
        let moved = Vault.Listed(host: "example.com", user: "me@example.com", used: nil, modified: nil, clear: false, space: home)
        #expect(!SyncWallet.same(SyncWallet.fields(moved, password: "pw"), there, key, seal))
    }
}
