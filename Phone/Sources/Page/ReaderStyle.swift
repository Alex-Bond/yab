import Foundation
import Observation

/// Reading mode's theme on this iPhone: the Mac's six (ReaderThemes.swift),
/// the light over them and each theme's edits, kept under the Mac's own
/// keys. Every change goes to the pages being read (WebPool.restyleReaders).
@MainActor
@Observable
final class ReaderStyle {
    static let shared = ReaderStyle(defaults: ReaderStyle.launchDefaults())
    static let changed = Notification.Name("yab.reader-style.changed")

    var prefs: ReaderPrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save(to: defaults)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        prefs = ReaderPrefs.load(from: defaults)
    }

    /// The person's own defaults, or a test run's suite, emptied at launch.
    static func launchDefaults(_ options: LaunchOptions = .current) -> UserDefaults {
        guard options.isTestRun else { return .standard }
        let name = "dev.serafim.fast.iphone.test-reader"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }
}
