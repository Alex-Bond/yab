import Testing
@testable import Fast

struct PasswordListSelectionTests {
    private let ids = ["a", "b", "c", "d", "e", "f", "g"]

    @Test func forgettingARowSelectsTheNextLogin() {
        for spot in ids.indices.dropLast() {
            var remaining = ids
            remaining.remove(at: spot)
            let selection = PasswordListSelection(ids: ids, spot: spot, picks: [])
            let restored = selection.restored(in: remaining)
            #expect(remaining[restored.spot] == ids[spot + 1])
            #expect(restored.picks.isEmpty)
        }
    }

    @Test func forgettingTheLastRowSelectsThePreviousLogin() {
        let selection = PasswordListSelection(ids: ids, spot: 6, picks: ["g"])
        let restored = selection.restored(in: Array(ids.dropLast()))
        #expect(restored.spot == 5)
        #expect(restored.picks.isEmpty)
    }

    @Test func bulkForgetUsesTheNextSurvivorRatherThanTheOldIndex() {
        let selection = PasswordListSelection(ids: ids, spot: 4, picks: ["b", "c", "e"])
        let remaining = ["a", "d", "f", "g"]
        let restored = selection.restored(in: remaining)
        #expect(remaining[restored.spot] == "f")
        #expect(restored.picks.isEmpty)
    }

    @Test func bulkForgetAtTheEndSelectsTheNearestPreviousSurvivor() {
        let selection = PasswordListSelection(ids: ids, spot: 5, picks: ["b", "f", "g"])
        let remaining = ["a", "c", "d", "e"]
        let restored = selection.restored(in: remaining)
        #expect(remaining[restored.spot] == "e")
        #expect(restored.picks.isEmpty)
    }

    @Test func cancelOrAFailedDeleteKeepsTheSelectedLoginAndSurvivingPicks() {
        let selection = PasswordListSelection(ids: ids, spot: 3, picks: ["b", "d"])
        let unchanged = selection.restored(in: ids)
        #expect(unchanged.spot == 3)
        #expect(unchanged.picks == ["b", "d"])
        let changed = selection.restored(in: ["new", "a", "d", "e"])
        #expect(changed.spot == 2)
        #expect(changed.picks == ["d"])
    }

    @Test func filteredRowsKeepTheirVisibleOrderWhenTheListIsReadAgain() {
        let selection = PasswordListSelection(ids: ["b", "d", "f"], spot: 1, picks: [])
        let restored = selection.restored(in: ["new", "f", "b"])
        #expect(restored.spot == 1)
    }

    @Test func repeatedForgetCanEmptyTheList() {
        var remaining = ids
        var spot = 2
        while !remaining.isEmpty {
            let selection = PasswordListSelection(ids: remaining, spot: spot, picks: [remaining[spot]])
            remaining.remove(at: spot)
            let restored = selection.restored(in: remaining)
            spot = restored.spot
            #expect(restored.picks.isEmpty)
            #expect(remaining.isEmpty ? spot == 0 : remaining.indices.contains(spot))
        }
    }

    @Test func emptyOrStaleSelectionStaysWithinTheRefreshedList() {
        #expect(PasswordListSelection(ids: [], spot: 0, picks: []).restored(in: []).spot == 0)
        #expect(PasswordListSelection(ids: ids, spot: 99, picks: []).restored(in: ["a"]).spot == 0)
        #expect(PasswordListSelection(ids: ids, spot: -1, picks: []).restored(in: ["a"]).spot == 0)
        #expect(PasswordListSelection(ids: ids, spot: 3, picks: []).restored(in: ["new"]).spot == 0)
    }
}
