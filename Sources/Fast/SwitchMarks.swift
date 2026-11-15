import AppKit
import QuartzCore

/// A switch timed, on a test run, for the bench's `switchmarks`: the first
/// commit after it, and the one with its row lit in the column.
@MainActor
enum SwitchMarks {
    static var last: [String: Double] = [:]
    private static var began: CFTimeInterval?

    /// The tab picked, till its row in the column has been lit.
    private static var picked: UUID?

    static func start(_ tab: UUID) {
        guard Store.testing else { return }
        let t0 = CACurrentMediaTime()
        began = t0
        picked = tab
        last = [:]
        afterCommit { last["pass_ms"] = ms(since: t0) }
    }

    /// The column laid with `active` lit (ColumnPages.sync).
    static func lit(_ active: UUID?) {
        guard let t0 = began, let picked, picked == active else { return }
        self.picked = nil
        afterCommit { last["lit_ms"] = ms(since: t0) }
    }

    private static func ms(since t0: CFTimeInterval) -> Double {
        ((CACurrentMediaTime() - t0) * 10000).rounded() / 10
    }

    private static func afterCommit(_ note: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001) { _, _ in
            MainActor.assumeIsolated { note() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
