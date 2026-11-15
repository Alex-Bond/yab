import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ClipboardTimerTests {
    @Test func foundationCallbackPollsSynchronouslyOnMain() async {
        // Enter from a Foundation/Dispatch callback, outside a Swift actor
        // job, as __NSFireTimer does in reports #906 through #1073.
        let ticks = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                AppKitMainThread.sync {
                    var ticks = 0
                    let timer = Clips.makeTimer(every: 1) {
                        #expect(Thread.isMainThread)
                        ticks += 1
                    }
                    defer { timer.invalidate() }
                    #expect(timer.timeInterval == 1)
                    #expect(timer.tolerance == 0.3)
                    timer.fire()
                    #expect(ticks == 1)
                    timer.fire()
                    continuation.resume(returning: ticks)
                }
            }
        }
        #expect(ticks == 2)
    }

    @Test func acceleratedPollingKeepsItsMinimumInterval() {
        let timer = Clips.makeTimer(every: 0) {}
        defer { timer.invalidate() }
        #expect(timer.timeInterval == 0.005)
    }
}
