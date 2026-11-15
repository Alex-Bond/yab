import AppKit
import Testing
@testable import Fast

/// Feedback 505: distinguish a close that did not arrive, one skipped
/// because the model was already closed, and one still waiting for motion.
/// No real sleep, windows, pages, user accounts or chat contents are used.
@MainActor
@Suite(.serialized)
struct ChatCloseDiagnosticsTests {
    @Test func everyPhaseAndStateHasAnUnambiguousBoundedCode() throws {
        let log = FeedbackDiagnostics(clock: { 10 })
        for phase in FeedbackDiagnostics.ChatClosePhase.allCases {
            for moving in [false, true] {
                for open in [false, true] { log.chatClose(phase, open: open, moving: moving) }
            }
        }
        let events = log.events()
        #expect(events.count == 20)
        #expect(events.map(\.code) == (0...19).map(Optional.some))
        let encoded = try JSONEncoder().encode(events)
        let rows = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(rows.allSatisfy { Set($0.keys) == ["ageSeconds", "kind", "code"] })
        #expect(rows.allSatisfy { $0["kind"] as? String == "chatClose" })
        #expect(events.allSatisfy { $0.domain == nil && $0.extensionID == nil && $0.reason == nil })
    }

    @Test func closeSequenceCanDistinguishAStuckMotionFromAMissingIntent() {
        var now: TimeInterval = 0
        let log = FeedbackDiagnostics(clock: { now })
        log.chatClose(.intent, open: true, moving: false)
        log.chatClose(.applied, open: false, moving: true)
        now = 4
        // A second click or shortcut while its presentation is still there.
        log.chatClose(.intent, open: false, moving: true)
        log.chatClose(.skipped, open: false, moving: true)
        #expect(log.events().map(\.code) == [1, 10, 2, 6])
        #expect(log.events().map(\.ageSeconds) == [4, 4, 0, 0])
        log.chatClose(.completed, open: false, moving: false)
        #expect(log.events().last?.code == 12)
        now = 305
        #expect(log.events().isEmpty)
    }

    @Test func newEventsCanFallBackWithoutLosingExistingDiagnostics() throws {
        let log = FeedbackDiagnostics(clock: { 10 })
        log.record(.tabClosed)
        log.chatClose(.applied, open: false, moving: true)
        log.record(.systemWoke)
        let snapshots = log.snapshots(stallLog: "", lag: Lag(clock: { 10 }), state: FeedbackDiagnostics.State())
        #expect(snapshots.count == 2)
        let first = try #require(snapshots.first)
        #expect(first.contains("\"chatClose\"") && first.contains("\"systemWoke\""))
        let fallback = try #require(snapshots.last)
        #expect(fallback.contains("\"tabClosed\""))
        #expect(!fallback.contains("\"chatClose\"") && !fallback.contains("\"systemWoke\""))
    }

    @Test func injectedWakeLeavesOnlyATypedMarker() throws {
        let center = NotificationCenter()
        let log = FeedbackDiagnostics(clock: { 10 })
        let hush = SleepHush(center: center, diagnostics: log)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(log.events().isEmpty)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(hush.hushes == 2)
        let events = log.events()
        #expect(events.count == 1 && events.first?.kind == .systemWoke)
        let rows = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(events)) as? [[String: Any]])
        #expect(rows.first.map { Set($0.keys) == ["ageSeconds", "kind"] } == true)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.post(name: name, object: nil)
        }
        #expect(log.events().count == 1)
    }
}
