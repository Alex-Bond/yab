import Foundation
import Testing
@testable import Fast

/// Another browser's history is read only after it was brought in from,
/// or switched on in Settings › Bring In; never in a `YAB_HISTORY=own` world.
struct OtherHistoryTests {
    private static func source(_ name: String) -> Chromium.Source {
        Chromium.Source(name: name, folder: name, service: "\(name) Safe Storage", account: name, bundle: "test.\(name)")
    }

    private let installed = ["Arc", "Chrome", "Dia"].map(Self.source)

    @Test func nothingBroughtInReadsNoOne() {
        #expect(OtherHistory.allowed(installed, choices: [:], ownOnly: false).isEmpty)
    }

    @Test func broughtInReadsOnlyThatBrowser() {
        let read = OtherHistory.allowed(installed, choices: ["Arc": true], ownOnly: false)
        #expect(read.map(\.name) == ["Arc"])
    }

    @Test func switchedOffStops() {
        let read = OtherHistory.allowed(installed, choices: ["Arc": false, "Dia": true], ownOnly: false)
        #expect(read.map(\.name) == ["Dia"])
    }

    @Test func notOnThisMacIsNotRead() {
        #expect(OtherHistory.allowed(installed, choices: ["Brave": true], ownOnly: false).isEmpty)
    }

    @Test func ownWorldReadsNoOne() {
        #expect(OtherHistory.allowed(installed, choices: ["Arc": true, "Chrome": true], ownOnly: true).isEmpty)
    }

    @Test func migrationKeepsTheBrowserBroughtFrom() {
        #expect(OtherHistory.migrated(broughtFrom: "Arc") == ["Arc": true])
        #expect(OtherHistory.migrated(broughtFrom: nil) == [:])
        #expect(OtherHistory.migrated(broughtFrom: "") == [:])
    }

    /// Kept in the settings: a first look migrates once, bringing in and
    /// the switch change it after.
    @Test func keptChoices() {
        let settings = Store.settings
        let kept = settings.object(forKey: OtherHistory.key)
        let from = settings.object(forKey: OtherHistory.broughtFromKey)
        defer {
            settings.set(kept, forKey: OtherHistory.key)
            settings.set(from, forKey: OtherHistory.broughtFromKey)
        }
        settings.removeObject(forKey: OtherHistory.key)
        settings.set("Chrome", forKey: OtherHistory.broughtFromKey)
        #expect(OtherHistory.choices == ["Chrome": true])
        // Migrated once: what was first brought from no longer decides.
        settings.set("Dia", forKey: OtherHistory.broughtFromKey)
        #expect(OtherHistory.choices == ["Chrome": true])
        OtherHistory.brought("Arc")
        #expect(OtherHistory.reads("Arc"))
        OtherHistory.set("Chrome", reading: false)
        #expect(!OtherHistory.reads("Chrome"))
        #expect(OtherHistory.choices == ["Chrome": false, "Arc": true])

        settings.removeObject(forKey: OtherHistory.key)
        settings.removeObject(forKey: OtherHistory.broughtFromKey)
        #expect(OtherHistory.choices.isEmpty)
    }
}
