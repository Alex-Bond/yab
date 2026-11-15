import Foundation

/// What an extension is told as it is taken up again, the way Chrome tells it.
///
/// WebKit tells runtime.onInstalled "install" every time an extension's
/// context is loaded: at each launch, after it is turned off and on again,
/// after Yab brings it back, and after the extension calls runtime.reload()
/// itself. Chrome says "install" once, "update" when its version changed,
/// and nothing for the rest; only an unpacked one, loaded from a folder, is
/// told "update" on each Reload, as its files may have changed.
///
/// Yab used to tell every later load in a session "update". Surfshark's
/// worker answers "update" by turning its rule sets off and calling
/// runtime.reload(), which WebKit answered with "install" again, told as
/// "update" again: it reloaded itself about every 150 ms for as long as Yab
/// ran, and each load put its content scripts (800 KB of autofill among
/// them) into every open page again, 200 copies in half a minute, until a
/// long form froze and Yab asked "This page stopped answering" (feedback
/// #283, evals/feedback-283).
enum ExtensionInstallWord {
    /// What the shim makes of WebKit's "install" (extension-shims.js,
    /// runtime.onInstalled): nil, a real install; "reload", told as an
    /// update; "update:<version>", an update from that version; "launch"
    /// and "same", nothing at all.
    /// - loadedBefore: loaded earlier in this run of Yab.
    /// - told: the version it was last told of in this run, nil if none.
    static func word(loadedBefore: Bool, unpacked: Bool, broughtIn: Bool, installedBeforeLaunch: Bool,
                     told: String?, now: String) -> String? {
        if loadedBefore {
            if unpacked { return "reload" }
            if let told, told != now { return "update:" + told }
            return "same"
        }
        // There it was installed long ago (feedback #135).
        if broughtIn { return "reload" }
        return installedBeforeLaunch ? "launch" : nil
    }
}

/// An extension that reloads itself again and again: Chrome counts a
/// runtime.reload() within ten seconds of the one before as fast, and does
/// no more after five of them in a row (runtime_api.cc, kFastReloadTime and
/// kFastReloadCount); Chrome turns such an extension off, Yab only leaves
/// that reload undone. In WebKit each reload puts the extension's content
/// scripts into every open page again.
struct FastReloads {
    static let window: TimeInterval = 10
    static let limit = 5
    private var last: Date?
    private var count = 0

    /// Whether this reload may go ahead.
    mutating func allow(at now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) < Self.window { count += 1 } else { count = 0 }
        last = now
        return count < Self.limit
    }
}
