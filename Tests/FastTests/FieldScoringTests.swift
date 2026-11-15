import Foundation
import Testing
@testable import Fast

/// The field scores every command and settings page at every key from
/// words split once (docs/main-thread-budget.md): the scores are the ones
/// worked out from the words each time.
struct FieldScoringTests {
    private let needles = ["", "n", "ne", "new", "new tab", "priv", "tab", "close", "close le", "close ab", "sf", "ny",
                           "top bar", "sidebar", "hist", "dwnld", "apper", "dark th", "⌥⌘y", "cmd y", "passwords settings",
                           "zoom in", "reader", "re", "  hist  ", "Bookm"]

    @Test func everyCommandScoresAsItsWordsSay() {
        for command in Command.allCases {
            for needle in needles {
                #expect(command.score(needle) == command.scoreUnprepared(needle), "\(command) \(needle)")
            }
        }
    }

    @Test func preparedWordsScoreAsWordingDoes() {
        let prepared = Wording.Prepared(title: "New Private Tab", words: "incognito secret window")
        #expect(prepared.score("new") == 3)
        #expect(prepared.score("priv tab") == 2.5)
        #expect(prepared.score("incog") == 1)
        #expect(prepared.score("x") == nil)
        #expect(prepared.score("zzz") == nil)
    }

    @Test func settingsPagesStillFoundByTheirNamesAndWords() {
        #expect(SettingsPage.appearance.score("appear") != nil)
        #expect(SettingsPage.appearance.score("apper") != nil)
        #expect(SettingsPage.developers.score("localhost") != nil)
        #expect(SettingsPage.mail.score("gmail") != nil)
        #expect(SettingsPage.appearance.score("q") == nil)
        let fresh = SettingsMatch.Prepared(title: "Appearance", words: "dark light theme")
        #expect(fresh.score("dark th") == SettingsMatch.score("dark th", title: "Appearance", words: "dark light theme"))
    }
}
