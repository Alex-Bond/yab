import Testing
@testable import Fast

struct ShortcutKeyFilterTests {
    @Test func modifierFilterFindsAllRequestedModifiersAcrossAdditionalOnes() {
        let custom = [["⌃", "⌥", "⇧", "⌘", "K"]]
        #expect(ShortcutsPage.keysMatch(custom, "⌃⌘", whole: false))
        #expect(ShortcutsPage.keysMatch(custom, "⌥⌘", whole: false))
        #expect(ShortcutsPage.keysMatch(custom, "⌃⇧", whole: false))
        #expect(!ShortcutsPage.keysMatch([["⌘", "K"]], "⌃⌘", whole: false))
    }

    @Test func completeChordStillMatchesExactlyRatherThanAcceptingExtraModifiers() {
        let caps = [["⌥", "⌘", "K"]]
        #expect(ShortcutsPage.keysMatch(caps, "⌥⌘k", whole: true))
        #expect(ShortcutsPage.keysMatch(caps, "⌥⌘K", whole: true))
        #expect(!ShortcutsPage.keysMatch(caps, "⌘k", whole: true))
        #expect(!ShortcutsPage.keysMatch([["⌥", "⇧", "⌘", "K"]], "⌥⌘k", whole: true))
        #expect(!ShortcutsPage.keysMatch(caps, "⌥⌘j", whole: true))
    }

    @Test func fixedAlternativesDisabledAndEmptyQueryKeepTheirBoundaries() {
        let alternatives = [["⌃", "⇧", "⌘", "→"], ["⌥", "⌘", "→"]]
        #expect(ShortcutsPage.keysMatch(alternatives, "⌃⌘", whole: false))
        #expect(ShortcutsPage.keysMatch(alternatives, "⌥⌘→", whole: true))
        #expect(!ShortcutsPage.keysMatch(alternatives, "⌥⌘←", whole: true))
        #expect(!ShortcutsPage.keysMatch([], "⌘", whole: false))
        #expect(!ShortcutsPage.keysMatch([[]], "⌘", whole: false))
        #expect(!ShortcutsPage.keysMatch(alternatives, "", whole: false))
    }

    @Test func ordinaryTextSearchKeepsEveryWordMatchingWithoutUsingTheKeyFilter() {
        #expect(ShortcutsPage.says("Keep or release tab", "tab keep"))
        #expect(!ShortcutsPage.says("Keep or release tab", "keep window"))
        #expect(!ShortcutsPage.says("Keep or release tab", " "))
    }
}
