import Foundation
import Testing
@testable import Fast

/// Value-only production classifications and selection. No Browser, Vault
/// operation, Store, application, profile load or network is constructed.
struct PasswordFilteredReturnTests {
    private let ids = ["a", "b", "c"]

    private var known: PasswordListWarnings {
        PasswordListWarnings(groups: ["a": "group", "b": "group", "c": "group"],
                             shared: ["a": 2, "b": 2, "c": 2], weak: ["a", "b", "c"],
                             leaked: ["a": 1, "b": 2, "c": 3])
    }

    private func rows(_ ids: [String], _ warnings: PasswordListWarnings, filter: Int) -> [String] {
        // Membership is the helper used by the actual loginItems filters.
        ids.filter { warnings.contains($0, filter: filter) }.map { "login." + $0 }
    }

    @Test(arguments: [3, 4, 5])
    func cancelReturnsToTheSelectedWarningRowAndPicks(filter: Int) {
        let before = rows(ids, known, filter: filter)
        let selection = PasswordListSelection(ids: before, spot: 1, picks: ["login.b", "login.c"])
        let seeded = known.retained(in: Set(ids))
        let restored = selection.restored(in: rows(ids, seeded, filter: filter))
        #expect(before[restored.spot] == "login.b")
        #expect(restored.picks == ["login.b", "login.c"])
        // The former restore computed this against empty classifications.
        #expect(rows(ids, PasswordListWarnings(), filter: filter).isEmpty)
    }

    @Test(arguments: [3, 4, 5])
    func forgettingTheMiddleRowChoosesItsSurvivingSuccessor(filter: Int) {
        let selection = PasswordListSelection(ids: rows(ids, known, filter: filter), spot: 1,
                                              picks: ["login.b", "login.c"])
        let remaining = ["a", "c"]
        let seeded = known.retained(in: Set(remaining))
        let visible = rows(remaining, seeded, filter: filter)
        let restored = selection.restored(in: visible)
        #expect(visible == ["login.a", "login.c"])
        #expect(visible[restored.spot] == "login.c")
        #expect(restored.picks == ["login.c"])
        #expect(seeded.groups["b"] == nil && seeded.shared["b"] == nil)
        #expect(!seeded.weak.contains("b") && seeded.leaked["b"] == nil)
    }

    @Test func deletingTheOtherLoginOfAPairRemovesItsSurvivorFromReused() {
        let all = ["a", "b", "d", "e"]
        let warnings = PasswordListWarnings(groups: ["a": "one", "b": "one", "d": "two", "e": "two"],
                                           shared: ["a": 1, "b": 1, "d": 1, "e": 1])
        let selection = PasswordListSelection(ids: rows(all, warnings, filter: 4), spot: 1,
                                              picks: ["login.b", "login.d"])
        let remaining = ["a", "d", "e"]
        let seeded = warnings.retained(in: Set(remaining))
        let visible = rows(remaining, seeded, filter: 4)
        let restored = selection.restored(in: visible)
        #expect(visible == ["login.d", "login.e"])
        #expect(visible[restored.spot] == "login.d")
        #expect(restored.picks == ["login.d"])
        #expect(seeded.shared == ["d": 1, "e": 1])
        #expect(seeded.groups["a"] == "one")
    }

    @Test func deletingEveryFilteredLoginLeavesAnEmptySelection() {
        let warnings = PasswordListWarnings(leaked: ["b": 3, "c": 7])
        let selection = PasswordListSelection(ids: rows(ids, warnings, filter: 3), spot: 1,
                                              picks: ["login.b", "login.c"])
        let seeded = warnings.retained(in: ["a"])
        let restored = selection.restored(in: rows(["a"], seeded, filter: 3))
        #expect(seeded.leaked.isEmpty)
        #expect(restored.spot == 0 && restored.picks.isEmpty)
    }

    @Test(arguments: [3, 4, 5])
    func aFreshResultPreservesTheCurrentRowAfterTheUserMoves(filter: Int) {
        // The original return chose b; the user moved to c before analysis.
        let current = PasswordListSelection(ids: rows(ids, known, filter: filter), spot: 2,
                                            picks: ["login.c"])
        let fresh = PasswordListWarnings(groups: ["b": "new", "c": "new", "d": "new"],
                                         shared: ["b": 2, "c": 2, "d": 2], weak: ["b", "c", "d"],
                                         leaked: ["b": 4, "c": 5, "d": 6])
            .retained(in: ["a", "b", "c", "d"])
        let visible = rows(["a", "b", "c", "d"], fresh, filter: filter)
        let restored = current.restored(in: visible)
        #expect(visible == ["login.b", "login.c", "login.d"])
        #expect(visible[restored.spot] == "login.c")
        #expect(restored.picks == ["login.c"])
    }

    @Test func equalSizedWarningReplacementsInvalidateTheRealStockVersion() {
        // PlaceStock defaults are empty values, including Profile(); no load.
        var stock = PlaceStock()
        let reading = UUID()
        stock.passwordAnalysis = reading
        stock.site = "unrelated.invalid"
        stock.codes = ["code-control"]
        known.apply(to: &stock)
        let firstVersion = stock.version
        let first = PasswordListWarnings(stock: stock)
        let fresh = PasswordListWarnings(groups: ["b": "new", "c": "new", "d": "new"],
                                         shared: ["b": 2, "c": 2, "d": 2], weak: ["b", "c", "d"],
                                         leaked: ["b": 4, "c": 5, "d": 6])
        fresh.apply(to: &stock)
        let second = PasswordListWarnings(stock: stock)
        #expect(first.weak.count == second.weak.count && first.shared.count == second.shared.count)
        #expect(first.leaked.count == second.leaked.count)
        #expect(first.contains("a", filter: 5) && !second.contains("a", filter: 5))
        #expect(!first.contains("d", filter: 3) && second.contains("d", filter: 3))
        #expect(stock.version == firstVersion + 1)
        #expect(stock.passwordAnalysis == reading)
        #expect(stock.site == "unrelated.invalid" && stock.codes == ["code-control"])
    }

    @Test func aRefreshRemovingTheLastWarningSelectsThePreviousSurvivor() {
        let selection = PasswordListSelection(ids: rows(ids, known, filter: 5), spot: 2,
                                              picks: ["login.b", "login.c"])
        let fresh = PasswordListWarnings(weak: ["a", "b"])
        let visible = rows(ids, fresh, filter: 5)
        let restored = selection.restored(in: visible)
        #expect(visible[restored.spot] == "login.b")
        #expect(restored.picks == ["login.b"])
    }

    @Test func retentionIsIdempotentAndRetainsLeakCounts() {
        let once = known.retained(in: ["a", "c"])
        let twice = once.retained(in: ["a", "c"])
        #expect(once.groups == twice.groups && once.shared == twice.shared)
        #expect(once.weak == twice.weak && once.leaked == twice.leaked)
        #expect(twice.leaked == ["a": 1, "c": 3])
        #expect(twice.shared == ["a": 1, "c": 1])
    }
}
