import Foundation
import Testing
@testable import Fast

struct PasswordSaveDecisionTests {
    private struct Apple: ManagerAdapter {
        let provider = PasswordManagers.apple
        let depth = ManagerVault.Depth.vault
        var rows: [Login]
        var unavailable = false
        func state() async -> ManagerVault.State { .open }
        func logins(for host: String) async throws -> [ManagerVault.Login] {
            if unavailable { throw ManagerVault.Failure.locked }
            return rows.map { .init(provider: provider, item: $0.password, title: $0.user,
                                    user: $0.user, urls: [$0.host]) }
        }
        func secret(_ login: ManagerVault.Login) async throws -> ManagerVault.Secret {
            .init(user: login.user, password: login.item)
        }
    }

    @MainActor @Test func identicalPairInEitherOrBothStoresDoesNotAsk() async {
        for stores in 1...3 {
            let login = Login(host: "github.com", user: UUID().uuidString, password: "fixture")
            let local = stores & 1 != 0 ? [login] : []
            let apple = Apple(rows: stores & 2 != 0 ? [login] : [])
            #expect(await PasswordSaveDecision.check(login, known: local, apple: apple) == .none)
        }
    }

    @MainActor @Test func subdomainAndHostCaseUseTheSameSite() async {
        let kept = Login(host: "www.github.com", user: UUID().uuidString, password: "fixture")
        var submitted = kept
        submitted.host = "GITHUB.COM"
        #expect(await PasswordSaveDecision.check(submitted, known: [kept], apple: nil) == .none)
        #expect(await PasswordSaveDecision.check(submitted, known: [], apple: Apple(rows: [kept])) == .none)
    }

    @MainActor @Test func changedPasswordIsUpdateInEitherStore() async {
        for stores in 1...3 {
            let old = Login(host: "github.com", user: UUID().uuidString, password: "old")
            var submitted = old
            submitted.password = "changed"
            #expect(await PasswordSaveDecision.check(submitted, known: stores & 1 != 0 ? [old] : [],
                                                     apple: Apple(rows: stores & 2 != 0 ? [old] : [])) == .update)
        }
    }

    @MainActor @Test func successfulSaveThenResubmitAndChangedPassword() async {
        let login = Login(host: "github.com", user: UUID().uuidString, password: "fixture")
        #expect(await PasswordSaveDecision.check(login, known: [], apple: Apple(rows: [])) == .save)
        PasswordSaveDecision.remember(host: login.host, user: login.user, password: login.password)
        // Even if Apple's name list has not caught up with the successful write.
        #expect(await PasswordSaveDecision.check(login, known: [], apple: Apple(rows: [])) == .none)
        var changed = login
        changed.password = "new"
        #expect(await PasswordSaveDecision.check(changed, known: [], apple: Apple(rows: [])) == .update)
        #expect(await PasswordSaveDecision.check(login, known: [login], apple: nil) == .none)
    }

    @MainActor @Test func unavailableStoreIsNotMistakenForEmptyAndOtherAccountsDoNotMatch() async {
        let login = Login(host: "github.com", user: UUID().uuidString, password: "fixture")
        #expect(await PasswordSaveDecision.check(login, known: [], apple: Apple(rows: [], unavailable: true)) == .none)
        var other = login
        other.user += "other"
        #expect(await PasswordSaveDecision.check(login, known: [other], apple: Apple(rows: [other])) == .save)
        other = login
        other.host = "unrelated.test"
        #expect(await PasswordSaveDecision.check(login, known: [other], apple: Apple(rows: [other])) == .save)
    }
}


extension PasswordSaveDecisionTests {
    @MainActor @Test func passwordsAreComparedAsBytes() async {
        let kept = Login(host: "github.com", user: UUID().uuidString, password: "\u{e9}")
        var submitted = kept
        submitted.password = "e\u{301}"
        #expect(await PasswordSaveDecision.check(submitted, known: [kept], apple: nil) == .update)
    }
}


extension PasswordSaveDecisionTests {
    @MainActor @Test func resubmissionWaitsForAllWritesEvenWhenOneFailed() async {
        let login = Login(host: "github.com", user: UUID().uuidString, password: "fixture")
        PasswordSaveDecision.beginSave(login)
        PasswordSaveDecision.beginSave(login)
        var finished = false
        var started = false
        let reader = Task { @MainActor in
            started = true
            await PasswordSaveDecision.waitForSave(login)
            finished = true
        }
        while !started { await Task.yield() }
        #expect(!finished)
        PasswordSaveDecision.endSave(login)
        await Task.yield()
        #expect(!finished)
        // Failure and success both release the reader. A failed save is
        // never recorded as an exact credential confirmation.
        PasswordSaveDecision.endSave(login)
        await reader.value
        #expect(finished)
        #expect(await PasswordSaveDecision.check(login, known: [], apple: nil) == .save)
    }
}
