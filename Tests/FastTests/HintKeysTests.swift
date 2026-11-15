import Testing
@testable import Fast

// On the new tab's empty field, the visibly chosen Now row takes ⌫ as Done and
// ⌥↩ as Later Today; anything typed, a place, or another kind of row, and
// the keys are the field's.
struct HintKeysTests {
    static func setup(_ id: String) -> Bool { id == "start" }

    @Test func aFoundRowTakesItsKeys() {
        #expect(Browser.hintKeyed(typed: "", bare: true, chosen: .hint("found"), setup: Self.setup))
    }

    @Test func typedWordsKeepTheKeys() {
        #expect(!Browser.hintKeyed(typed: "a", bare: true, chosen: .hint("found"), setup: Self.setup))
    }

    @Test func aPlaceOrListKeepsTheKeys() {
        #expect(!Browser.hintKeyed(typed: "", bare: false, chosen: .hint("found"), setup: Self.setup))
    }

    @Test func nothingChosenOrAnotherRow() {
        #expect(!Browser.hintKeyed(typed: "", bare: true, chosen: nil, setup: Self.setup))
        #expect(!Browser.hintKeyed(typed: "", bare: true, chosen: .open, setup: Self.setup))
    }

    @MainActor @Test func rowKeysFollowTheVisibleChoice() {
        let query = Query()
        #expect(query.current == nil)
        query.lead = 0
        #expect(query.current == 0)
        query.picked = 1
        #expect(query.current == 1)
        query.pointed = 2
        #expect(query.current == 2)
        query.pointed = nil
        #expect(query.current == 1)
    }

    @Test func gettingStartedHasNoDoneOrLater() {
        #expect(!Browser.hintKeyed(typed: "", bare: true, chosen: .hint("start"), setup: Self.setup))
    }

    @Test func filesNotificationTakesDoneOnlyInTheEmptyRootField() {
        #expect(Browser.hintKeyed(typed: "", bare: true, chosen: .place(.downloads), setup: Self.setup))
        #expect(!Browser.hintKeyed(typed: "files", bare: true, chosen: .place(.downloads), setup: Self.setup))
        #expect(!Browser.hintKeyed(typed: "", bare: false, chosen: .place(.downloads), setup: Self.setup))
        #expect(!Browser.hintKeyed(typed: "", bare: true, chosen: .place(.history), setup: Self.setup))
    }
}
