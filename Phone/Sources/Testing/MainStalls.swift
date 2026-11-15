import Foundation
import UIKit

/// How long the main thread stays busy without sleeping, in debug builds that
/// ask for it (YAB_STALLS_OUT=<file>): iOS's watchdog kills an app whose main
/// thread doesn't answer a scene update in 10 s or an exit in 5 s (crashes
/// 43, 44, 53, 62, 63, 67, 86). Each busy stretch past 100 ms is one line of
/// JSON, with the lifecycle step it happened in and how many times the
/// counted places ran during it:
///
///     {"busy_ms":812.4,"phase":"background","counts":{"pageHost":3,"viewport":7}}
///
/// A stretch that never ends is caught by a watcher thread: after 2 s it
/// writes a "stuck" line with the counts so far, so a loop (counts climbing)
/// tells itself apart from one long call (counts still).
final class MainStalls: @unchecked Sendable {
    static let shared: MainStalls? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["YAB_STALLS_OUT"], !path.isEmpty else { return nil }
        return MainStalls(URL(fileURLWithPath: path))
        #else
        return nil
        #endif
    }()

    /// One more run of a counted place, on any thread.
    @inline(__always)
    static func count(_ name: StaticString) {
        #if DEBUG
        shared?.add("\(name)")
        #endif
    }

    private let file: URL
    private let lock = NSLock()
    private var began: CFAbsoluteTime?
    private var phase = "launch"
    private var counts: [String: Int] = [:]
    private var stuckWritten = false
    private var observers: [CFRunLoopObserver] = []

    private init(_ file: URL) {
        self.file = file
        FileManager.default.createFile(atPath: file.path, contents: nil)
    }

    /// From the app delegate, on the main thread, before the first scene.
    @MainActor
    func start() {
        let main = CFRunLoopGetMain()
        // First after waking, last before sleeping: everything between is the
        // main thread's busy stretch, the frame's layout and commit included.
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
            self?.wake()
        }
        let sleeps = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
            self?.sleep()
        }
        for observer in [woke, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(main, observer, .commonModes)
            observers.append(observer)
        }
        wake()
        let center = NotificationCenter.default
        let steps: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "resign"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willTerminateNotification, "terminate"),
        ]
        for (name, step) in steps {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.enter(step) }
        }
        let watcher = Thread { [weak self] in
            while let self {
                Thread.sleep(forTimeInterval: 0.25)
                self.check()
            }
        }
        watcher.name = "yab.main-stalls"
        watcher.start()
    }

    private func add(_ name: String) {
        lock.lock(); counts[name, default: 0] += 1; lock.unlock()
    }

    private func enter(_ step: String) {
        lock.lock(); phase = step; lock.unlock()
        write(["event": "phase", "phase": step])
    }

    private func wake() {
        lock.lock()
        began = CFAbsoluteTimeGetCurrent()
        counts = [:]
        stuckWritten = false
        lock.unlock()
    }

    private func sleep() {
        lock.lock()
        let start = began, step = phase, seen = counts
        began = nil
        lock.unlock()
        guard let start else { return }
        let busy = (CFAbsoluteTimeGetCurrent() - start) * 1000
        guard busy > 100 else { return }
        write(["event": "busy", "busy_ms": (busy * 10).rounded() / 10, "phase": step, "counts": seen])
    }

    private func check() {
        lock.lock()
        guard let start = began, !stuckWritten, CFAbsoluteTimeGetCurrent() - start > 2 else { lock.unlock(); return }
        stuckWritten = true
        let step = phase, seen = counts
        lock.unlock()
        write(["event": "stuck", "busy_ms": ((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded(),
               "phase": step, "counts": seen])
    }

    private func write(_ line: [String: Any]) {
        var line = line
        // The wall clock, which the simulator shares with the Mac's UI test.
        line["at"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
