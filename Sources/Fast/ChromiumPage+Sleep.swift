import AppKit
import YabCoreClient

/// Native lifecycle mirrors. A freeze request is not a discard receipt.
@MainActor
final class ChromiumSleep {
    var discarded = false
    var frozen = false
    var supported = false
}

extension ChromiumPage: PageSleepActivity {
    /// No URL navigation, no replacement browser: Chromium retains its
    /// selected entry, back/forward list and saved document state.
    func discardForSleep() async -> Bool {
        guard remoteID != nil else { return false }
        do {
            let receipt = try await navigationRequest("tab.discard")
            guard receipt["discarded"] == .bool(true) else { return false }
            sleepState.discarded = true
            clearDiscardedRenderer()
            return true
        } catch { return false }
    }

    func restoreFromSleep() {
        // Queue before the stage's visible/resize updates or any page script.
        command("tab.restore")
    }

    func freezeForSleep(_ frozen: Bool) async -> Bool {
        guard remoteID != nil else { return false }
        guard let receipt = try? await navigationRequest("tab.freeze", ["frozen": .bool(frozen)]),
              receipt["accepted"] == .bool(true) else { return false }
        sleepState.frozen = frozen
        return true
    }

    func receiveSleep(_ state: [String: JSONValue]) {
        if let capability = state["nativeDiscard"] {
            // Native CEF feature macros may arrive as JSON 0/1.
            sleepState.supported = capability == .bool(true) || capability == .number(1)
        }
        if case .bool(let discarded) = state["discarded"] {
            sleepState.discarded = discarded
            if discarded { clearDiscardedRenderer() }
        }
        if case .bool(let frozen) = state["frozen"] { sleepState.frozen = frozen }
        if state["audibleSource"] == .string("native"), case .bool(let audible) = state["audible"] {
            // Also consumes own-CEF's page.state event. A media frame report
            // must not turn this native signal back into a DOM-only guess.
            var report = media.rawReport
            report.native = true; report.audible = audible
            receiveNativeAudible(report)
        }
    }

    var sleepActivityUnavailable: Bool {
        // Browser.awake(because:) already keeps a page on a call (camera,
        // microphone, screen), with its document out, playing sound or
        // holding something typed (the yab world's form probe answers on
        // Chromium too). What remains is the helper's native discard: a
        // page without it never sleeps, as before. YAB_CHROMIUM_SLEEP=0
        // turns automatic sleep off in a test world.
        if Store.testing, ProcessInfo.processInfo.environment["YAB_CHROMIUM_SLEEP"] == "0" { return true }
        // Chrome's DevTools are looking at it.
        if navigationTab?.chromiumDev != nil { return true }
        return !sleepState.supported
    }
}
