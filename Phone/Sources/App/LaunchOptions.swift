import Foundation

/// What the app was launched with. Named states for screenshots and tests:
///
///     -YabWorld mira       the world to load (Phone/Worlds/mira.json)
///     -YabState page.2     a named state of the prototype's atlas (StateCatalog)
///     -YabNoAnim YES       no movement: states land in their final frame
///     -YabTab work-ledger  start on this tab instead of the world's
///
/// Read from the arguments themselves, so nothing of it lingers in defaults.
struct LaunchOptions: Sendable {
    var world: String
    /// Fixtures are explicit. A normal launch restores this person's profile.
    var fixtureWorld: String?
    var state: String?
    var noAnimation: Bool
    var tab: String?
    /// A world was named, or XCTest runs the app: haptics keep a journal,
    /// nothing is read from or written to the person's own data.
    var isTestRun: Bool
    /// A repeatable, isolated profile for live-browser tests.
    var profileDirectory: String?
    /// A real page to open for a hands-on browser check.
    var initialURL: URL?
    /// `-YabLaunchKeyboard YES`: a test run opens New Tab's field at launch
    /// as a person's does (Field/LaunchKeyboard); test runs don't otherwise.
    var launchKeyboard: Bool
    /// `-YabSettingsSuite NAME`: a test run's settings kept in this suite
    /// from one launch to the next, for tests of what a relaunch finds.
    /// Test runs otherwise start with empty settings every launch.
    var settingsSuite: String?

    static let defaultWorld = "mira"

    init(arguments: [String], environment: [String: String] = [:]) {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: "-" + key), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let named = value("YabWorld")
        let profile = value("YabProfileDirectory") ?? environment["YAB_PROFILE_DIRECTORY"]
        // A live named-state probe must never fall back to the person's profile.
        let liveState = ["yes", "true", "1"].contains((value("YabLiveState") ?? "").lowercased())
            && !(profile ?? "").isEmpty
        state = value("YabState")
        fixtureWorld = named ?? (state == nil || liveState ? nil : Self.defaultWorld)
        world = fixtureWorld ?? ""
        noAnimation = ["yes", "true", "1"].contains((value("YabNoAnim") ?? "").lowercased())
        tab = value("YabTab")
        profileDirectory = profile
        // An explicit isolated profile never reads the person's keychain or sync.
        isTestRun = fixtureWorld != nil || !(profileDirectory ?? "").isEmpty
            || environment["XCTestConfigurationFilePath"] != nil || environment["YAB_TEST"] == "1"
        initialURL = value("YabURL").flatMap { URL(string: $0) }
        launchKeyboard = ["yes", "true", "1"].contains((value("YabLaunchKeyboard") ?? "").lowercased())
        settingsSuite = value("YabSettingsSuite").flatMap { $0.isEmpty ? nil : "dev.serafim.fast.iphone.test-settings." + $0 }
    }

    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
}
