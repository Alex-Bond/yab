import Foundation
import Testing
@testable import Fast

struct DarkModeDefaultsTests {
    private func withStore(_ check: (UserDefaults) throws -> Void) throws {
        let name = "yab-dark-mode-defaults-" + UUID().uuidString
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        try check(store)
    }

    @Test func aNewProfileLeavesWebsitesAloneWithoutSavingAChoice() throws {
        try withStore { store in
            #expect(store.object(forKey: DarkMode.key) == nil)
            #expect(DarkMode.read(in: store) == .off)
            #expect(store.object(forKey: DarkMode.key) == nil)
        }
    }

    @Test func anUnknownSavedModeDoesNotEnableDarkPages() throws {
        try withStore { store in
            store.set("future-mode", forKey: DarkMode.key)
            #expect(DarkMode.read(in: store) == .off)
            #expect(store.string(forKey: DarkMode.key) == "future-mode")
        }
    }

    @Test(arguments: DarkMode.allCases)
    func explicitChoicesSurviveReading(_ choice: DarkMode) throws {
        try withStore { store in
            store.set(choice.rawValue, forKey: DarkMode.key)
            #expect(DarkMode.read(in: store) == choice)
            #expect(store.string(forKey: DarkMode.key) == choice.rawValue)
        }
    }
}
