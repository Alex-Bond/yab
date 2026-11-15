import AppKit
import Testing
@testable import Fast

// The downloads' bar on the Dock icon (DockProgress.swift, register 1006).
@MainActor
struct DockProgressTests {
    typealias Bytes = DockProgress.Bytes

    @Test func nothingUnderWayIsNoBar() {
        #expect(DockProgress.fraction([]) == nil)
    }

    @Test func bytesOfAllDownloadsTogether() {
        // 10 of 100 and 90 of 300: 100 of 400, not the mean of 10% and 30%.
        #expect(DockProgress.fraction([Bytes(got: 10, total: 100), Bytes(got: 90, total: 300)]) == 0.25)
    }

    @Test func unknownSizesLeaveTheSumAndStillShowTheBar() {
        #expect(DockProgress.fraction([Bytes(got: 50, total: 100), Bytes(got: 5_000, total: -1)]) == 0.5)
        #expect(DockProgress.fraction([Bytes(got: 5_000, total: -1), Bytes(got: 0, total: 0)]) == 0)
    }

    @Test func neverAheadAndNeverPastFull() {
        // 199.9 of 200 halves is still short of full.
        #expect(DockProgress.fraction([Bytes(got: 9_999, total: 10_000)]) == 0.995)
        #expect(DockProgress.fraction([Bytes(got: 400, total: 100)]) == 1)
        #expect(DockProgress.fraction([Bytes(got: -5, total: 100)]) == 0)
    }

    @Test func windowsAddUpAndTheBarGoesWithTheLast() {
        _ = NSApplication.shared
        let dock = DockProgress.shared
        // Two live windows: freed at once, two objects can share an address.
        let windows = (NSObject(), NSObject())
        let first = ObjectIdentifier(windows.0), second = ObjectIdentifier(windows.1)
        let badge = NSApp.dockTile.badgeLabel
        NSApp.dockTile.badgeLabel = "3"
        defer {
            dock.report(first, [])
            dock.report(second, [])
            NSApp.dockTile.badgeLabel = badge
            withExtendedLifetime(windows) {}
        }
        dock.report(first, [Bytes(got: 30, total: 100)])
        #expect(dock.shown == 0.3)
        #expect(NSApp.dockTile.contentView is DockProgressView)
        dock.report(second, [Bytes(got: 70, total: 100)])
        #expect(dock.shown == 0.5)
        dock.report(first, [])
        #expect(dock.shown == 0.7)
        dock.report(second, [])
        #expect(dock.shown == nil)
        #expect(NSApp.dockTile.contentView == nil)
        // Mail's badge is the Dock's own label: the bar never touches it.
        #expect(NSApp.dockTile.badgeLabel == "3")
    }

    @Test func trackSitsInsideTheTile() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)
        let track = DockProgressView.track(in: bounds)
        #expect(bounds.contains(track))
        #expect(abs(track.midX - bounds.midX) <= 0.5)
    }
}
