import Testing
@testable import Fast

/// Requests that waited on the Mac's passkey question: only the newest one
/// still wanted starts once it is answered (#1843).
struct PasskeyWaitsTests {
    @Test func onlyTheNewestStartsTheOthersHearSo() {
        var waits = PasskeyWaits()
        let first = waits.asked(), second = waits.asked(), third = waits.asked()
        #expect(waits.turn(first, token: "a") == .superseded)
        #expect(waits.turn(second, token: "b") == .superseded)
        #expect(waits.turn(third, token: "c") == .start)
    }

    @Test func everyRequestCalledOffIsRememberedNotOnlyTheLast() {
        var waits = PasskeyWaits()
        let first = waits.asked(), second = waits.asked(), third = waits.asked()
        waits.withdraw("a")
        waits.withdraw("b")
        #expect(waits.turn(first, token: "a") == .aborted)
        #expect(waits.turn(second, token: "b") == .aborted)
        #expect(waits.turn(third, token: "c") == .start)
    }

    @Test func aRequestAfterTheAnswerStartsAndAWithdrawalIsSpentOnce() {
        var waits = PasskeyWaits()
        let first = waits.asked()
        waits.withdraw("a")
        #expect(waits.turn(first, token: "a") == .aborted)
        let next = waits.asked()
        #expect(waits.turn(next, token: "a") == .start)
        let untokened = waits.asked()
        #expect(waits.turn(untokened, token: nil) == .start)
    }
}
