import AppKit

/// Complete the cross-engine cookie barrier before entering AppKit's nested
/// terminateLater loop, where main-actor socket continuations can be held.
@MainActor
enum EngineSwitchQuit {
    private static var waiting = false
    private static var prepared = false

    static func deferQuitIfNeeded() -> Bool {
        guard !prepared, ChromiumDRMCookies.hasSessions else { return false }
        guard !waiting else { return true }
        waiting = true
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            prepared = true
            waiting = false
            Links.leaving = true
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
        // A dead helper must not make Quit hang. Request timeouts remain
        // bounded separately; a timed-out quit makes no data-transfer promise.
        let deadline = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated {
                if !finished { DebugLog.note("engine-switch-quit", ["result": "cookie barrier timed out"]) }
                finish()
            }
        }
        RunLoop.main.add(deadline, forMode: .common)
        Task { @MainActor in
            await ChromiumDRMCookies.synchronizeBeforeQuit()
            deadline.invalidate()
            finish()
        }
        return true
    }
}
