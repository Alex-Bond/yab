import Foundation
import Testing
@testable import Fast

struct HangsTests {
    @Test func delayedObserverDoesNotInflateMainLatency() {
        let ping = Hangs.Ping(at: 100, cpu: 3)
        #expect(ping.reply == nil)
        ping.complete(at: 100.02, cpu: 3.004, phase: "open")
        // The observing thread resumes 900 ms later. Its time is not an input
        // to the main latency, CPU or phase recorded by the callback.
        let observedAt = 100.92
        let reply = ping.reply!
        #expect(abs(reply.latency - 0.02) < 0.000001)
        #expect(abs(reply.working - 0.004) < 0.000001)
        #expect(abs(observedAt - reply.answered - 0.9) < 0.000001)
        #expect(reply.phase == "open")
    }

    @Test func realStallKeepsItsFullDurationAndCPU() {
        let ping = Hangs.Ping(at: 100, cpu: 2)
        ping.complete(at: 100.25, cpu: 2.15, phase: "select")
        #expect(abs(ping.reply!.latency - 0.25) < 0.000001)
        #expect(abs(ping.reply!.working - 0.15) < 0.000001)
        #expect(ping.reply!.latency >= Hangs.threshold)
    }

    @Test func replyCannotBeOverwrittenByALaterPhase() {
        let ping = Hangs.Ping(at: 1, cpu: 1)
        ping.complete(at: 1.2, cpu: 1.1, phase: "first")
        ping.complete(at: 2, cpu: 2, phase: "later")
        #expect(ping.reply!.phase == "first")
        #expect(abs(ping.reply!.latency - 0.2) < 0.000001)
    }
}
