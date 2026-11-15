import Testing
@testable import Fast

// What the floating video says while it waits on the network: nothing for
// a short wait, the spinner once it lasts, words once long, the failure.
struct FloatHoldTests {
    typealias Hold = Floater.Hold

    @Test func aShortWaitShowsNothing() {
        var hold = Hold()
        hold.read(held: true, error: 0, at: 10)
        #expect(hold.look(at: 10.3) == .none)
        #expect(abs(hold.confirm(at: 10)! - 0.4) < 1e-9)
        hold.read(held: false, error: 0, at: 10.3)
        #expect(hold.look(at: 11) == .none)
        #expect(hold.since == nil)
    }

    @Test func aWaitThatLastsSpins() {
        var hold = Hold()
        hold.read(held: true, error: 0, at: 10)
        hold.read(held: true, error: 0, at: 10.45)
        #expect(hold.look(at: 10.45) == .waiting)
        #expect(hold.confirm(at: 10.45) == nil)
        hold.read(held: true, error: 0, at: 18.5)
        #expect(hold.look(at: 18.5) == .slow)
        hold.read(held: true, error: 0, at: 40.5)
        #expect(hold.look(at: 40.5) == .failed(.stuck))
    }

    // One reading found it held, the wait ended before the next: the time
    // passing alone never shows the spinner.
    @Test func timeAloneNeverShowsIt() {
        var hold = Hold()
        hold.read(held: true, error: 0, at: 10)
        #expect(hold.look(at: 12) == .none)
    }

    @Test func aSeekShowsSooner() {
        var hold = Hold()
        hold.seeked(at: 5)
        #expect(hold.look(at: 5.3) == .none)
        #expect(hold.confirm(at: 5.1)! < 0.21)
        hold.read(held: true, error: 0, at: 5.32)
        #expect(hold.look(at: 5.32) == .waiting)
        hold.read(held: false, error: 0, at: 6)
        #expect(hold.look(at: 6) == .none)
    }

    @Test func errorsSayWhy() {
        var hold = Hold()
        hold.read(held: false, error: 2, at: 1)
        #expect(hold.look(at: 1) == .failed(.network))
        hold.read(held: false, error: 3, at: 2)
        #expect(hold.look(at: 2) == .failed(.decode))
        hold.read(held: true, error: 4, at: 3)
        #expect(hold.look(at: 3) == .failed(.format))
        // Stopped by the page itself is no failure.
        hold.read(held: false, error: 1, at: 4)
        #expect(hold.look(at: 4) == .none)
    }

    @Test func tryingAgainSpinsAtOnce() {
        var hold = Hold()
        hold.read(held: false, error: 2, at: 1)
        hold.retried(at: 2)
        #expect(hold.look(at: 2) == .waiting)
        hold.read(held: false, error: 0, at: 2.5)
        #expect(hold.look(at: 2.5) == .none)
    }

    @Test func readsWhatThePageFetched() {
        let head = Floater.Playhead([0.5, true, 60, 120, 1, 1280, 720, false, false, false, -1, 0, false, 40, 95, 2])
        #expect(head?.loaded?.from == 40)
        #expect(head?.loaded?.to == 95)
        #expect(head?.error == 2)
        #expect(head?.waiting == true)
        let old = Floater.Playhead([0.5, true, 60, 120, 1, 1280, 720, true, false])
        #expect(old?.loaded == nil)
        #expect(old?.error == 0)
    }
}
