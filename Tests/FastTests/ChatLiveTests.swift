import Foundation
import Testing
@testable import Fast

// The live line under a turn at work (ChatLive): what it says is held a
// moment each, so steps that come a few at once and end in a tenth of a
// second never flicker through it; and an answer that comes in one lump
// is written out (WriteOut).
struct ChatLiveTests {
    static let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    static func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// The line from `steps`, sampled every 10 ms: what it said, in order,
    /// and from when.
    static func said(_ steps: [ChatLive.Step], until end: Double) -> [(String?, Double)] {
        var out: [(String?, Double)] = []
        for tick in 0...Int(end * 100) {
            let shown = ChatLive.shown(steps, from: start, at: at(Double(tick) / 100)).shown
            if out.last?.0 != shown.step || out.isEmpty {
                out.append((shown.step, shown.since.timeIntervalSince(start)))
            }
        }
        return out
    }

    @Test func stepsOverInATenthOfASecondEachGetASecond() {
        // As a chat read a post on X: named the task, read the page and
        // looked at it within a third of a second, 8 s in.
        let steps = [
            ChatLive.Step(id: "name", began: Self.at(8.000), ended: Self.at(8.030), quiet: true),
            ChatLive.Step(id: "snapshot", began: Self.at(8.013), ended: Self.at(8.115)),
            ChatLive.Step(id: "screenshot", began: Self.at(8.088), ended: Self.at(8.317)),
        ]
        let said = Self.said(steps, until: 15)
        #expect(said.map(\.0) == [nil, "snapshot", "screenshot", nil])
        // Each a second, the bookkeeping never.
        #expect(abs(said[1].1 - 8.013) < 0.011)
        #expect(abs(said[2].1 - 9.013) < 0.011)
        #expect(abs(said[3].1 - 10.013) < 0.011)
    }

    @Test func aStepGoingOnIsSaidAtOnceAndForAsLongAsItGoes() {
        let steps = [ChatLive.Step(id: "open", began: Self.at(3), ended: nil)]
        let early = ChatLive.shown(steps, from: Self.start, at: Self.at(3.001))
        #expect(early.shown == ChatLive.Shown(step: "open", since: Self.at(3)))
        // Nothing due: it changes only when the agent says something new.
        #expect(early.next == nil)
        #expect(ChatLive.shown(steps, from: Self.start, at: Self.at(40)).shown.step == "open")
    }

    @Test func aNewerStepWaitsForTheOneSaidToStandItsSecond() {
        let steps = [
            ChatLive.Step(id: "click", began: Self.at(2), ended: Self.at(2.2)),
            ChatLive.Step(id: "type", began: Self.at(2.3), ended: nil),
        ]
        let held = ChatLive.shown(steps, from: Self.start, at: Self.at(2.5))
        #expect(held.shown.step == "click")
        // The line is told when to look again: as the click's second is up.
        #expect(held.next == Self.at(3))
        #expect(ChatLive.shown(steps, from: Self.start, at: Self.at(3)).shown == ChatLive.Shown(step: "type", since: Self.at(3)))
    }

    @Test func yabsOwnBookkeepingIsSaidOnlyOnceItHasRunAWhile() {
        let quick = [ChatLive.Step(id: "memory", began: Self.at(1), ended: Self.at(1.2), quiet: true)]
        #expect(Self.said(quick, until: 4).map(\.0) == [nil])
        let long = [ChatLive.Step(id: "wait", began: Self.at(1), ended: Self.at(3), quiet: true)]
        let said = Self.said(long, until: 6)
        #expect(said.map(\.0) == [nil, "wait", nil])
        #expect(abs(said[1].1 - 1.4) < 0.011)
        // Over, it doesn't linger: bookkeeping has no moment after.
        #expect(abs(said[2].1 - 3) < 0.011)
    }

    @Test func manyQuickStepsSkipToTheNewestRatherThanFallBehind() {
        // Ten clicks, 0.2 s apart, each over in 0.1 s.
        let steps = (0..<10).map { ChatLive.Step(id: "c\($0)", began: Self.at(1 + Double($0) * 0.2), ended: Self.at(1.1 + Double($0) * 0.2)) }
        let said = Self.said(steps, until: 8)
        // Never more than a second behind, each said a second at least.
        for (index, pair) in said.enumerated().dropFirst().dropLast() {
            #expect(said[index + 1].1 - pair.1 >= 0.99)
        }
        #expect(said.last?.0 == nil)
        #expect(said.last.map(\.1) ?? 0 < 4.2)
    }

    @Test func aLumpIsWrittenOutInAboutASecondAWordAtATime() {
        let out = WriteOut(from: 0, to: 663, start: Self.start)
        let took = out.end.timeIntervalSince(Self.start)
        #expect(took > 1 && took <= 1.4)
        #expect(out.count(at: Self.start) == 0)
        #expect(out.count(at: Self.at(took / 2)) > 300 && out.count(at: Self.at(took / 2)) < 360)
        #expect(out.count(at: Self.at(10)) == 663)
        // A short lump still reads as written, not slower than 240 a second.
        let short = WriteOut(from: 100, to: 160, start: Self.start)
        #expect(short.end.timeIntervalSince(Self.start) <= 0.25 + 1e-9)
        // A long one doesn't hold the answer back more than 1.4 s.
        #expect(WriteOut(from: 0, to: 6000, start: Self.start).end.timeIntervalSince(Self.start) <= 1.4 + 1e-9)
        // Words come whole.
        let text = "Model NVFP4: a joke for AI engineers"
        #expect(String(text[..<WriteOut.stop(text, at: 7)]) == "Model NVFP4:")
        #expect(String(text[..<WriteOut.stop(text, at: 0)]) == "Model")
        #expect(WriteOut.stop(text, at: 500) == text.endIndex)
    }
}
