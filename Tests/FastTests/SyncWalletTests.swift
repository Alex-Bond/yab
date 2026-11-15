import Foundation
import Testing
import SyncKit
@testable import Fast

/// Passwords and cards between Macs (SyncWallet.swift): when the keychain's
/// item and its record say different things, which one is newer. The
/// keychain keeps whole seconds; records keep milliseconds.
@MainActor
struct SyncWalletTests {
    init() { SyncShapes.register() }

    private let id = "pw.test\u{1}me@check.test"

    private func login(_ device: String, at wall: Int64) -> Record {
        Record(collection: SyncWallet.login, id: id,
               fields: ["host": .string("pw.test"), "user": .string("me@check.test"), "secret": .string("box")],
               stamps: ["host": Stamp(wall: wall, device: device), "user": Stamp(wall: wall, device: device),
                        "secret": Stamp(wall: wall, device: device)])
    }

    private func second(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func aPasswordChangedHereInTheSecondItsRecordWasWrittenGoesUp() {
        // A wrote the login's record at 10.700 s and the password was changed
        // at 10.900 s: the keychain says 10 s. It used to read as older than
        // the record, and the keychain took the old password back
        // (evals/sync/check.py, "a changed password reaches B").
        let mine = login("a", at: 10_700)
        #expect(!SyncWallet.recordIsNewer(mine, than: second(10), here: "a"))
        // The read that wrote the record began before the change and reached
        // the journal after it: still the keychain's.
        #expect(!SyncWallet.recordIsNewer(login("a", at: 11_020), than: second(10), here: "a"))
        #expect(!SyncWallet.recordIsNewer(mine, than: nil, here: "a"))
    }

    @Test func aRecordChangedElsewhereAfterTheItemComesIntoTheKeychain() {
        let theirs = login("b", at: 12_300)
        #expect(SyncWallet.recordIsNewer(theirs, than: second(11), here: "a"))
        #expect(SyncWallet.recordIsNewer(theirs, than: nil, here: "a"))
        // Changed here after B's change: the item goes up.
        #expect(!SyncWallet.recordIsNewer(theirs, than: second(13), here: "a"))
        // A change of this Mac's own later in the record doesn't make B's
        // older change the newer one.
        var both = theirs
        both.stamps["used"] = Stamp(wall: 14_000, device: "a")
        #expect(!SyncWallet.recordIsNewer(both, than: second(13), here: "a"))
    }

    @Test func theJournalsStampsSayWhichMacChangedItLast() throws {
        let a = try Journal(path: nil, device: "a"), b = try Journal(path: nil, device: "b")
        let fields: [String: Value] = ["host": .string("pw.test"), "user": .string("me@check.test"), "secret": .string("box")]
        try a.reconcile(SyncWallet.login, [id: fields])
        let written = try #require(a.record(.init(collection: SyncWallet.login, id: id)))
        let wall = Double(try #require(written.latest).wall) / 1000
        // The keychain's date for a change made in the same second, after.
        #expect(!SyncWallet.recordIsNewer(written, than: second(wall.rounded(.down)), here: "a"))
        // On B, the same record is A's, and newer than an item B changed
        // before it.
        _ = try b.receive([(record: written, version: 1)])
        let there = try #require(b.record(.init(collection: SyncWallet.login, id: id)))
        #expect(SyncWallet.recordIsNewer(there, than: second(wall.rounded(.down) - 1), here: "b"))
        #expect(!SyncWallet.recordIsNewer(there, than: second(wall.rounded(.down) + 1), here: "b"))
    }

    @Test func aChangeWrittenInLateDoesNotBeatTheNextOne() {
        // A changed the password at 11.900 s and again at 12.400 s; busy B
        // wrote the first into its keychain only at 13.2 s, so the keychain
        // says 13. By the dates B's item was the newer: B passed the next
        // record over and sent the older password back to A
        // (evals/sync/check.py, "a change B writes in late").
        let next = login("a", at: 12_400)
        #expect(!SyncWallet.recordIsNewer(next, than: second(13), here: "b"))
        #expect(SyncWallet.keychainIsNewer(than: next, modified: second(13), synced: nil))
        // Still as sync wrote it in from the record of 11.900 s, it is as
        // old as that record: the next one comes in.
        #expect(SyncWallet.recordIsNewer(next, than: second(13), here: "b", synced: 11_900))
        #expect(!SyncWallet.keychainIsNewer(than: next, modified: second(13), synced: 11_900))
        // The record it came from, or an older one arriving late, doesn't.
        #expect(!SyncWallet.recordIsNewer(login("a", at: 11_900), than: second(13), here: "b", synced: 11_900))
        #expect(SyncWallet.keychainIsNewer(than: login("c", at: 11_500), modified: second(13), synced: 11_900))
        // Nothing in the keychain: the record is written in.
        #expect(!SyncWallet.keychainIsNewer(than: next, modified: nil, synced: 11_900))
    }

    @Test func aKeychainWriteIsMarkedOnlyOnceItIsIn() {
        // Marked before the write, a read that took the mark in between
        // read the old password, dated the second before; a change in that
        // same second was never read again.
        let item = "login/vault-\(UUID().uuidString)\u{1}me@check.test"
        var during = Set<String>()
        Vault.writing(item) {
            during = Vault.changedItems()
            return true
        }
        #expect(!during.contains(item))
        #expect(Vault.changedItems().contains(item))
        Vault.removing(item) { during = Vault.changedItems() }
        #expect(!during.contains(item))
        #expect(Vault.changedItems().contains(item))
    }

    @Test func syncsMarkLastsTillTheItemChangesHere() {
        let item = "login/vault-\(UUID().uuidString)\u{1}me@check.test"
        Vault.writing(item, from: 11_900) { true }
        #expect(Vault.synced(item) == 11_900)
        // Read again after a read thrown away: still as sync wrote it.
        Vault.again(item)
        #expect(Vault.synced(item) == 11_900)
        // A change made here: its date is when it changed.
        Vault.writing(item) { true }
        #expect(Vault.synced(item) == nil)
        // A write that didn't go in leaves no mark.
        Vault.writing(item, from: 12_000) { false }
        #expect(Vault.synced(item) == nil)
        // A change made here between sync's write and its mark.
        Vault.writing(item, from: 12_400) {
            Vault.writing(item) { true }
            return true
        }
        #expect(Vault.synced(item) == nil)
        Vault.writing(item, from: 12_500) { true }
        Vault.removing(item) {}
        #expect(Vault.synced(item) == nil)
    }

    @Test func twoMacsEditingInOneSecondKeepTheActualOrder() throws {
        let item = "login/precise-\(UUID())"
        let before = Date()
        Vault.writing(item) { true }
        let actual = try #require(Vault.modified(item, fallback: second(before.timeIntervalSince1970.rounded(.down))))
        #expect(actual >= before)
        let early = login("b", at: Int64(actual.timeIntervalSince1970 * 1000) - 100)
        #expect(!SyncWallet.recordIsNewer(early, than: actual, here: "a"))
        #expect(SyncWallet.keychainIsNewer(than: early, modified: actual, synced: nil))
        let late = login("b", at: Int64(actual.timeIntervalSince1970 * 1000) + 100)
        #expect(SyncWallet.recordIsNewer(late, than: actual, here: "a"))
        #expect(!SyncWallet.keychainIsNewer(than: late, modified: actual, synced: nil))
        // Taking the remote winner clears the local date; a failed write does not.
        Vault.writing(item) { false }
        #expect(Vault.modified(item, fallback: nil) == actual)
        Vault.writing(item, from: late.latest?.wall) { true }
        #expect(Vault.modified(item, fallback: second(10)) == second(10))
    }

    @Test func anUnpublishedLocalEditSurvivesAnArrivingRecordAndAnOlderRead() throws {
        let item = "login/unpublished-\(UUID())"
        Vault.writing(item) { true }
        let first = Vault.localChanges()
        #expect(first[item] != nil)
        Vault.writing(item) { true }
        Vault.published(first)
        #expect(Vault.localChanges()[item] != nil, "a stale read cannot acknowledge a newer edit")
        Vault.published(Vault.localChanges())
        #expect(Vault.localChanges()[item] == nil)
    }

    @Test func aRemoteRemovalIsNotAnUnpublishedLocalEdit() {
        let item = "login/removed-\(UUID())"
        Vault.writing(item) { true }
        Vault.removing(item, from: 12_500) {}
        #expect(Vault.synced(item) == 12_500)
        #expect(Vault.localChanges()[item] == nil)
        #expect(Vault.modified(item, fallback: nil) == nil)
        Vault.removing(item, from: 12_600) {
            Vault.writing(item) { true }
        }
        #expect(Vault.synced(item) == nil)
        #expect(Vault.localChanges()[item] != nil)
    }

    @Test func joiningAnAccountKeepsThePreciseDateWithoutProtectingOldEdits() {
        let item = "login/before-join-\(UUID())"
        Vault.writing(item) { true }
        let date = Vault.modified(item, fallback: nil)
        Vault.beginSync()
        #expect(Vault.localChanges()[item] == nil)
        #expect(Vault.modified(item, fallback: nil) == date)
    }
}
