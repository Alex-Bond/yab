import Foundation

/// Tests that exercise a WebKit-only mechanism, or that assume the default
/// engine choice, say so with `.enabled(if: !ForcedEngine.chromium, "reason")`.
/// Under `YAB_ENGINE=chromium` (the parity run) they are reported as skipped
/// with that reason instead of failing for an engine they never meant to cover.
enum ForcedEngine {
    nonisolated static var chromium: Bool { ProcessInfo.processInfo.environment["YAB_ENGINE"]?.lowercased() == "chromium" }
}
