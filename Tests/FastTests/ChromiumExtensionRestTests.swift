import Foundation
import Testing
@testable import Fast

@MainActor
struct ChromiumExtensionRestTests {
    private static let passwords = String(repeating: "a", count: 32)
    private static let browserStack = String(repeating: "b", count: 32)
    private static let builtIn = String(repeating: "c", count: 32)

    /// Only what Chrome lists as installed rests in WebKit: store and
    /// unpacked ones, never its own built-in ones.
    @Test func chromesSettingsNameWhatIsInstalled() {
        let prefs: [String: Any] = ["extensions": ["settings": [
            Self.passwords: ["location": 4, "state": 1],
            Self.builtIn: ["location": 5],
            "not-an-id": ["location": 1],
        ]]]
        #expect(ChromiumExtensions.installed(inPreferences: prefs) == [Self.passwords])
        #expect(ChromiumExtensions.installed(inPreferences: [:]).isEmpty)
    }

    /// Adopted on paper (an older file wrote one that asked for more as
    /// adopted) but missing in Chromium: its WebKit copy keeps running.
    @Test func anIdAdoptedOnPaperButMissingInChromiumStillRunsOnWebKit() throws {
        let profile = UUID().uuidString
        let file = Store.file("ChromiumImports").appendingPathComponent(profile + ".json")
        let folder = Store.file("Chromium").appendingPathComponent("space-" + profile)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pending":[],"pins":[],"adopted":["\#(Self.passwords)","\#(Self.browserStack)"]}"#.utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefs: [String: Any] = ["extensions": ["settings": [Self.passwords: ["location": 4]]]]
        try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Secure Preferences"))
        let resting = ChromiumExtensions.inChromium(profile: profile)
        #expect(resting.contains(Self.passwords))
        #expect(!resting.contains(Self.browserStack))
    }

    /// No Chromium profile on disk: nothing rests.
    @Test func aProfileWithoutChromiumRestsNothing() {
        #expect(ChromiumExtensions.inChromium(profile: UUID().uuidString).isEmpty)
    }
}
