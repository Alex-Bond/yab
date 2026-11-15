import Testing
@testable import Fast

/// The actual completion owner handed to evaluateInYab, without a page,
/// profile, browser or AppKit fixture. TuneWatch's binding is source checked.
@MainActor @Suite(.serialized)
struct TuneTransportLifetimeTests {
    @Test func falseFallsBackOnlyOnce() {
        let owner = TuneTransport()
        var calls = 0
        let answer = owner.answer { calls += 1 }
        answer(false)
        answer(false)
        #expect(calls == 1)
    }

    @Test func nilRetainsTheExistingErrorFallback() {
        let owner = TuneTransport()
        var calls = 0
        let answer = owner.answer { calls += 1 }
        answer(nil)
        answer(false)
        #expect(calls == 1)
    }

    @Test func knownPlayerConsumesWithoutNativeFallback() {
        let owner = TuneTransport()
        var calls = 0
        let answer = owner.answer { calls += 1 }
        answer(true)
        answer(false)
        #expect(calls == 0)
    }

    @Test(arguments: [false, true])
    func newestRequestOwnsFallbackInEitherArrivalOrder(newFirst: Bool) {
        let owner = TuneTransport()
        var calls: [String] = []
        let old = owner.answer { calls.append("play") }
        let current = owner.answer { calls.append("pause") }
        if newFirst {
            current(false)
            old(false)
        } else {
            old(false)
            #expect(calls.isEmpty)
            current(false)
        }
        #expect(calls == ["pause"])
    }

    @Test func invalidationRejectsOldWorkAndAdmitsFreshWork() {
        let owner = TuneTransport()
        var calls: [String] = []
        let old = owner.answer { calls.append("old session") }
        owner.invalidate()
        old(nil)
        #expect(calls.isEmpty)
        let current = owner.answer { calls.append("current session") }
        old(false)
        current(false)
        #expect(calls == ["current session"])
    }

    @Test func repeatedInvalidationDoesNotBlockTheNextRequest() {
        let owner = TuneTransport()
        var calls = 0
        owner.invalidate()
        owner.invalidate()
        let answer = owner.answer { calls += 1 }
        answer(false)
        #expect(calls == 1)
    }

    @Test func fallbackMayStartANewRequestReentrantly() {
        let owner = TuneTransport()
        var calls: [String] = []
        var next: ((Any?) -> Void)?
        let first = owner.answer {
            calls.append("first")
            next = owner.answer { calls.append("next") }
        }
        first(false)
        // Repeating the old answer must not consume its new successor.
        first(false)
        next?(false)
        next?(false)
        #expect(calls == ["first", "next"])
    }

    @Test func pendingAnswerDoesNotRetainItsOwner() {
        var owner: TuneTransport? = TuneTransport()
        weak var weakOwner = owner
        var calls = 0
        let answer = owner!.answer { calls += 1 }
        owner = nil
        #expect(weakOwner == nil)
        answer(false)
        #expect(calls == 0)
    }

    @Test func independentOwnersDoNotCancelEachOther() {
        let first = TuneTransport(), second = TuneTransport()
        var calls: [String] = []
        let a = first.answer { calls.append("first") }
        let b = second.answer { calls.append("second") }
        first.invalidate()
        a(false)
        b(false)
        #expect(calls == ["second"])
        let c = first.answer { calls.append("fresh first") }
        c(false)
        #expect(calls == ["second", "fresh first"])
    }

    @Test func knownCurrentPlayerDoesNotReviveAnOldFallback() {
        let owner = TuneTransport()
        var calls: [String] = []
        let old = owner.answer { calls.append("old") }
        let current = owner.answer { calls.append("current") }
        current(true)
        old(false)
        #expect(calls.isEmpty)
    }
}
