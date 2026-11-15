import Foundation
import Testing
import WebKit
@testable import Fast

/// A big profile's sign-ins poured into WebKit's store (CookiePour, crash
/// #60): every one lands, and the main thread keeps turning while they go.
@MainActor struct CookiePourTests {
    @Test func aBigJarLandsWithoutHoldingTheMainThread() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let count = 4_000
        let made: [String: [HTTPCookie]] = await withCheckedContinuation { got in
            DispatchQueue.global().async {
                CookiePour.convert(["Default": CookiePour.madeUp(count, tag: "pour")]) { got.resume(returning: $0) }
            }
        }
        let cookies = try #require(made["Default"])
        #expect(cookies.count == count)

        var last = ProcessInfo.processInfo.systemUptime, longest: TimeInterval = 0, beats = 0
        let beat = Timer(timeInterval: 0.005, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            longest = max(longest, now - last)
            last = now
            beats += 1
        }
        RunLoop.main.add(beat, forMode: .common)
        let poured: Int = await withCheckedContinuation { done in
            CookiePour.pour(cookies.map { (store, $0) }) { done.resume(returning: $0) }
        }
        beat.invalidate()
        #expect(poured == count)
        // The heartbeat beat on through the pour: the work went in turns.
        #expect(beats > 0)
        // Generous for a busy test Mac; the old way held it for seconds.
        #expect(longest < 0.5, "longest main-thread hold \(Int(longest * 1000)) ms")
        let landed = await store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("-pour.example") }
        #expect(landed.count == count)
    }

    @Test func nothingToPourAnswersAtOnce() async {
        let poured: Int = await withCheckedContinuation { done in
            CookiePour.pour([]) { done.resume(returning: $0) }
        }
        #expect(poured == 0)
    }
}
