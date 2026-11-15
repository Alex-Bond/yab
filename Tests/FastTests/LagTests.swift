import AppKit
import Darwin
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct LagTests {
    @Test func ringKeepsTheNewestInOrder() {
        var ring = Lag.Ring<Int>(capacity: 4)
        #expect(ring.elements.isEmpty)
        for value in 1...3 { ring.add(value) }
        #expect(ring.elements == [1, 2, 3])
        for value in 4...10 { ring.add(value) }
        #expect(ring.elements == [7, 8, 9, 10])
        #expect(ring.count == 4)
    }

    @Test func hitchesAndTimingsLastFiveMinutesAndStayBounded() {
        var now: TimeInterval = 1000
        let lag = Lag(clock: { now })
        for _ in 0..<300 { lag.hitch(0.25) }
        for _ in 0..<300 { lag.timing(.tabSwitch, seconds: 0.04) }
        #expect(lag.hitches().count == 128)
        #expect(lag.timings().count == 256)
        #expect(lag.hitches().first == Lag.Hitch(ageSeconds: 0, durationMs: 250))
        #expect(lag.timings().first == Lag.Timing(ageSeconds: 0, kind: .tabSwitch, ms: 40))
        now += 300
        #expect(lag.hitches().count == 128)
        now += 1
        #expect(lag.hitches().isEmpty)
        #expect(lag.timings().isEmpty)
        lag.timing(.paint, seconds: .nan)
        lag.timing(.paint, seconds: -1)
        #expect(lag.timings().isEmpty)
    }

    @Test func anActionIsTimedToTheNextSleep() throws {
        let lag = Lag(clock: Lag.uptime)
        lag.begin(.closeTab)
        let start = try #require(lag.pending).start
        // A second begun before the sleep keeps the first's start.
        lag.begin(.tabSwitch)
        #expect(lag.pending?.kind == .closeTab)
        lag.settle(at: start + UInt64(0.08 / Watchdog.ticks))
        #expect(lag.pending == nil)
        let timing = try #require(lag.timings().last)
        #expect(timing.kind == .closeTab)
        #expect((79...81).contains(timing.ms))
    }

    /// Every step of the main loop runs this; it must stay a few loads and
    /// stores, nothing like the timer churn Watchdog's comment warns of.
    @Test func aStepStaysCheap() {
        let steps = 1_000_000
        let start = mach_absolute_time()
        for index in 0..<steps { Watchdog.step(going: index & 1 == 1) }
        let ns = Double(mach_absolute_time() - start) * Watchdog.ticks * 1e9 / Double(steps)
        print("watchdog step: \(String(format: "%.1f", ns)) ns")
        #expect(ns < 250)
    }

    @Test func aFullReportFitsTheSiteAndCarriesEveryNewField() throws {
        let lag = Lag(clock: { 50 })
        for index in 0..<200 { lag.hitch(0.1 + Double(index) / 1000) }
        for index in 0..<300 { lag.timing(Lag.Kind.allCases[index % Lag.Kind.allCases.count], seconds: 12.345) }
        let log = FeedbackDiagnostics(clock: { 10 })
        for reason in FeedbackDiagnostics.SleepReason.allCases { log.slept(reason) }
        log.reloadedAfterTermination(reason: .memory)
        for _ in 0..<250 {
            log.record(.webProcessTerminated, code: -2_147_483_648, extensionID: String(repeating: "a", count: 32), reason: .crashLimit)
        }
        let stalls = (0..<200).map { _ in ["ageSeconds": 300, "durationMs": 86_400_000] as [String: Any] }
        var state = FeedbackDiagnostics.State()
        state.screens = (0..<16).map { _ in ["x": -131072, "y": -131072, "width": 65536, "height": 65536, "scale": 2.0, "maxFPS": 120] }
        state.extensions = (0..<50).map { _ in ["id": String(repeating: "p", count: 32), "version": String(repeating: "9", count: 32), "enabled": true] }
        state.system = ["model": "Mac15,8", "memoryGB": 16, "cores": 12, "lowPower": false, "thermal": "nominal"]
        state.memory = FeedbackDiagnostics.Memory(
            sample: MemoryCeiling.Sample(at: 5, yabFootprintBytes: 1 << 30, webProcessCount: 100,
                                         footprints: Array(repeating: 2 << 30, count: 100)),
            sleepsTabs: true, configuredSleepAfterSeconds: 14_400, sleepAfterSeconds: 3600, lowPower: true, thrift: true)
        let text = try #require(log.snapshot(of: log.events(), stalls: stalls, lag: lag, state: state))
        #expect(text.utf8.count <= FeedbackDiagnostics.most)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(payload["schemaVersion"] as? Int == 2)
        #expect((payload["hitches"] as? [Any])?.isEmpty == false)
        #expect((payload["timings"] as? [Any])?.isEmpty == false)
        #expect((payload["extensions"] as? [Any])?.count == 50)
        #expect((payload["system"] as? [String: Any])?["model"] as? String == "Mac15,8")
        let memory = try #require(payload["memory"] as? [String: Any])
        #expect(memory["webProcessCount"] as? Int == 100)
        #expect((memory["largestWebProcessFootprintsBytes"] as? [UInt64])?.count == 3)
        #expect((memory["sleepsSinceLaunch"] as? [String: Any])?["count"] as? Int == FeedbackDiagnostics.SleepReason.allCases.count)
        #expect((memory["reloadsSinceLaunch"] as? [String: Any])?["count"] as? Int == 1)
        #expect(((payload["state"] as? [String: Any])?["screens"] as? [[String: Any]])?.first?["maxFPS"] as? Int == 120)
    }

    @Test func tooMuchDropsTheOldestUntilItFits() throws {
        let lag = Lag(clock: { 50 })
        let log = FeedbackDiagnostics(clock: { 10 })
        let events = (0..<3000).map {
            FeedbackDiagnostics.Event(ageSeconds: $0 % 300, kind: .navigationFailed, code: $0,
                                      domain: "NSURLErrorDomain", extensionID: nil, reason: nil)
        }
        let text = try #require(log.snapshot(of: events, stalls: [], lag: lag, state: .init()))
        #expect(text.utf8.count <= FeedbackDiagnostics.most)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let kept = try #require(payload["events"] as? [[String: Any]])
        #expect(kept.count < 3000 && kept.count > 100)
        #expect(kept.last?["code"] as? Int == 2999)
    }

    @Test func modelAndVersionsAreStrict() {
        #expect(FeedbackDiagnostics.version("7.11.7") == "7.11.7")
        #expect(FeedbackDiagnostics.version("1.0 beta") == "unknown")
        let model = FeedbackDiagnostics.model()
        #expect(model == "unknown" || model.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ",") })
    }
}
