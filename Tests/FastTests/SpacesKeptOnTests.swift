import Foundation
import Testing
@testable import Fast

/// Spaces on or off at launch (Spaces.on): the choice written down, or,
/// with the settings gone and the folder kept (feedback #320), the spaces
/// kept there.
struct SpacesKeptOnTests {
    private struct Install {
        let name = "dev.serafim.fast.tests.spaces-on.\(UUID().uuidString)"
        let settings: UserDefaults
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-on-\(UUID().uuidString)")
        var file: URL { folder.appendingPathComponent("spaces.json") }

        init() {
            settings = UserDefaults(suiteName: name)!
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func keep(_ names: [String]) throws {
            let spaces = names.enumerated().map { at, name in
                Space(id: at == 0 ? Space.firstID : UUID(), name: name, icon: "🏠", ownSignIns: false)
            }
            try JSONEncoder().encode(spaces).write(to: file)
        }

        func on() -> Bool { Spaces.on(settings: settings, kept: file) }

        func close() {
            settings.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func aNewMacStartsWithSpacesOff() {
        let mac = Install()
        defer { mac.close() }
        #expect(!mac.on())
    }

    @Test func spacesKeptWithTheSettingsGoneComeBackOn() throws {
        let mac = Install()
        defer { mac.close() }
        try mac.keep(["Personal", "Work", "School"])
        #expect(mac.on())
    }

    @Test func theOneSpaceEveryMacHasIsNotSpacesOn() throws {
        let mac = Install()
        defer { mac.close() }
        try mac.keep(["Personal"])
        #expect(!mac.on())
    }

    @Test func aDamagedListOfSeveralSpacesIsSpacesOn() throws {
        let mac = Install()
        defer { mac.close() }
        try Data(#"[{"id":"x"},{"id":"y"}]"#.utf8).write(to: mac.file)
        #expect(mac.on())
    }

    @Test func aMissingListWithAnotherSpacesRowIsSpacesOn() throws {
        let mac = Install()
        defer { mac.close() }
        try Data("{}".utf8).write(to: mac.folder.appendingPathComponent("session.json"))
        #expect(!mac.on())
        try Data("{}".utf8).write(to: mac.folder.appendingPathComponent("session-\(UUID().uuidString).json"))
        #expect(mac.on())
    }

    @Test func aChoiceWrittenDownStays() throws {
        let mac = Install()
        defer { mac.close() }
        try mac.keep(["Personal", "Work"])
        mac.settings.set(false, forKey: "spaces")
        #expect(!mac.on())
        mac.settings.set(true, forKey: "spaces")
        #expect(mac.on())
    }
}
