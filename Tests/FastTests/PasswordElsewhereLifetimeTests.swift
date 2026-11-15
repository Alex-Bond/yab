import Foundation
import Testing
@testable import Fast

/// Only values: no browser, source reader, keychain, profile files or secrets.
@MainActor
struct PasswordElsewhereLifetimeTests {
    private let oldID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let currentID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    private func login(_ host: String, _ user: String) -> Login {
        Login(host: host, user: user, password: "", used: nil)
    }

    @Test func olderReplyCannotReplaceCompletedNewerRows() throws {
        let old = login("old.invalid", "old-user")
        let fresh = login("new.invalid", "new-user")
        var stock = PlaceStock()
        stock.elsewhereReadID = currentID
        stock.elsewhereAt = Date(timeIntervalSince1970: 200)
        stock.version = 7
        let current = try #require(PasswordElsewhereReply(readID: currentID,
            logins: [(fresh, "New Browser")]).applying(to: stock))

        #expect(PasswordElsewhereReply(readID: oldID,
            logins: [(old, "Old Browser")]).applying(to: current) == nil)
        #expect(current.elsewhere?.map(\.login) == [fresh])
        #expect(current.elsewhere?.map(\.from) == ["New Browser"])
        #expect(current.elsewhereReadID == currentID)
        #expect(current.elsewhereAt == stock.elsewhereAt)
        #expect(current.version == 7)
    }

    @Test(arguments: [false, true])
    func olderReplyCannotFillResetOrNewerPendingStock(startedAgain: Bool) throws {
        var reopened = PlaceStock()
        if startedAgain { reopened.elsewhereReadID = currentID }
        let old = PasswordElsewhereReply(readID: oldID,
            logins: [(login("old.invalid", "old-user"), "Old Browser")])

        #expect(old.applying(to: reopened) == nil)
        #expect(reopened.elsewhere == nil)
        #expect(reopened.elsewhereReadID == (startedAgain ? currentID : nil))
        if startedAgain {
            let fresh = login("new.invalid", "new-user")
            let admitted = try #require(PasswordElsewhereReply(readID: currentID,
                logins: [(fresh, "New Browser")]).applying(to: reopened))
            #expect(admitted.elsewhere?.map(\.login) == [fresh])
        }
    }

    @Test func currentReplyPublishesPayloadAndSourceOrder() throws {
        let first = login("first.invalid", "one")
        let second = login("second.invalid", "two")
        var stock = PlaceStock()
        stock.elsewhereReadID = currentID
        stock.elsewhere = [(login("previous.invalid", "old"), "Previous Browser")]

        let admitted = try #require(PasswordElsewhereReply(readID: currentID,
            logins: [(first, "Browser A"), (second, "Browser B")]).applying(to: stock))
        #expect(admitted.elsewhere?.map(\.login) == [first, second])
        #expect(admitted.elsewhere?.map(\.from) == ["Browser A", "Browser B"])
        #expect(stock.elsewhere?.map(\.from) == ["Previous Browser"])
    }

    @Test func completedEmptyReplyIsDifferentFromPending() throws {
        var stock = PlaceStock()
        stock.elsewhereReadID = currentID
        #expect(stock.elsewhere == nil)

        let admitted = try #require(PasswordElsewhereReply(readID: currentID,
            logins: []).applying(to: stock))
        #expect(admitted.elsewhere != nil)
        #expect(admitted.elsewhere?.isEmpty == true)
    }

    @Test func admittedReplyPreservesCurrentUnrelatedStock() throws {
        var stock = PlaceStock()
        stock.elsewhereReadID = currentID
        stock.elsewhereAt = Date(timeIntervalSince1970: 300)
        stock.logins = [Vault.Entry(host: "kept.invalid", user: "kept-user")]
        stock.codes = ["kept-code"]
        stock.site = "kept.invalid"
        stock.version = 19
        stock.asked = 8
        stock.shared = ["kept-id": 2]
        stock.weak = ["weak-id"]
        stock.leaked = ["leaked-id": 1]
        stock.groups = ["kept-id": "invented-group"]
        stock.profile.company = "Example"

        let fresh = login("new.invalid", "new-user")
        let admitted = try #require(PasswordElsewhereReply(readID: currentID,
            logins: [(fresh, "Browser B")]).applying(to: stock))
        #expect(admitted.elsewhere?.map(\.login) == [fresh])
        #expect(admitted.elsewhereReadID == stock.elsewhereReadID)
        #expect(admitted.elsewhereAt == stock.elsewhereAt)
        #expect(admitted.logins.map(\.id) == stock.logins.map(\.id))
        #expect(admitted.codes == stock.codes)
        #expect(admitted.site == stock.site)
        #expect(admitted.version == stock.version)
        #expect(admitted.asked == stock.asked)
        #expect(admitted.shared == stock.shared)
        #expect(admitted.weak == stock.weak)
        #expect(admitted.leaked == stock.leaked)
        #expect(admitted.groups == stock.groups)
        #expect(admitted.profile == stock.profile)
    }
}
