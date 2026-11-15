import Foundation

/// Synchronous entry from AppKit's main-thread callbacks, not from a Swift
/// task. In crashes #524, #636–637, #639, #644–645, assumeIsolated faulted
/// *inside* executor lookup on the main thread, before running our closure.
/// Check the actual AppKit contract instead. Keep this boundary synchronous:
/// deferring an event or marked-text update changes what the next handler sees.
enum AppKitMainThread {
    nonisolated static func sync<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        // Never allow this bridge to conceal a real off-main UI access.
        precondition(Thread.isMainThread, "AppKit callback must run on the main thread")
        // As in assumeIsolated, erase only the closure's isolation, while
        // keeping its lifetime and throwing/result conventions unchanged.
        return try withoutActuallyEscaping(body) { body in
            try unsafeBitCast(body, to: (() throws -> T).self)()
        }
    }
}
