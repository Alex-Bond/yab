import Testing
@testable import Fast

struct AddressBarClickSequenceTests {
    @Test func onlyTheSecondPressOfTheOpeningClickIsTaken() {
        var clicks = AddressBarClickSequence()
        let beforeOpening = clicks.second(at: 10, window: 1, count: 2, interval: 0.5, showing: true)
        #expect(!beforeOpening)
        clicks.opened(at: 10, window: 1)
        let second = clicks.second(at: 10.2, window: 1, count: 2, interval: 0.5, showing: true)
        #expect(second)
        let repeated = clicks.second(at: 10.3, window: 1, count: 2, interval: 0.5, showing: true)
        #expect(!repeated)
    }

    @Test(arguments: [-0.1, 0, 0.2, 0.5, 0.6])
    func theSystemIntervalBoundsTheSecondPress(elapsed: Double) {
        var clicks = AddressBarClickSequence()
        clicks.opened(at: 10, window: 1)
        let second = clicks.second(at: 10 + elapsed, window: 1, count: 2, interval: 0.5, showing: true)
        #expect(second == (elapsed >= 0 && elapsed <= 0.5))
    }

    @Test(arguments: [0, 1, 3, 4])
    func anotherClickCountDoesNotZoom(count: Int) {
        var clicks = AddressBarClickSequence()
        clicks.opened(at: 10, window: 1)
        let anotherCount = clicks.second(at: 10.2, window: 1, count: count, interval: 0.5, showing: true)
        #expect(!anotherCount)
        let afterCancellation = clicks.second(at: 10.3, window: 1, count: 2, interval: 0.5, showing: true)
        #expect(!afterCancellation)
    }

    @Test func anotherWindowCannotCompleteThePair() {
        var clicks = AddressBarClickSequence()
        clicks.opened(at: 10, window: 1)
        let anotherWindow = clicks.second(at: 10.2, window: 2, count: 2, interval: 0.5, showing: true)
        #expect(!anotherWindow)
        let afterCancellation = clicks.second(at: 10.3, window: 1, count: 2, interval: 0.5, showing: true)
        #expect(!afterCancellation)
    }

    @Test func aDismissedFieldCannotCompleteThePair() {
        var clicks = AddressBarClickSequence()
        clicks.opened(at: 10, window: 1)
        let dismissed = clicks.second(at: 10.2, window: 1, count: 2, interval: 0.5, showing: false)
        #expect(!dismissed)
    }

    @Test func aNewOpeningReplacesThePreviousPair() {
        var clicks = AddressBarClickSequence()
        clicks.opened(at: 10, window: 1)
        clicks.opened(at: 20, window: 2)
        let second = clicks.second(at: 20.2, window: 2, count: 2, interval: 0.5, showing: true)
        #expect(second)
    }
}
