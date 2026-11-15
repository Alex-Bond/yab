import Foundation

/// The buttons at the end of the row that give a hop when something lands
/// in them, the downloads and the extensions, take turns. A file done and
/// an extension added in the same moment would hop side by side, and two
/// at once read as one twitch; a fifth of a second apart they read as two
/// arrivals.
@MainActor
enum Hop {
    static let gap: TimeInterval = 0.22
    private static var free = Date.distantPast

    static func take(_ run: @escaping @MainActor () -> Void) {
        let now = Date()
        let at = max(now, free)
        free = at.addingTimeInterval(gap)
        let wait = at.timeIntervalSince(now)
        if wait <= 0 {
            run()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { MainActor.assumeIsolated { run() } }
        }
    }
}
