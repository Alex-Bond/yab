import Testing
@testable import Fast

// Which letters of the old words the new words keep, as the field's words
// change (FieldWords.shared): new letter's position → old letter's.
struct FieldWordsTests {
    static func kept(_ old: String, _ new: String) -> String {
        let pairs = FieldWords.shared(Array(old), Array(new))
        return String(Array(new).enumerated().map { pairs[$0.offset] == nil ? "·" : $0.element })
    }

    @Test func typedWordsBecomeTheSiteInTheirCapitals() {
        #expect(Self.kept("youtube", "Search YouTube") == "·······YouTube")
        #expect(Self.kept("youtube.com", "Search YouTube") == "·······YouTube")
    }

    @Test func aSiteToAnotherKeepsSearch() {
        #expect(Self.kept("Search YouTube", "Search GitHub").hasPrefix("Search "))
    }

    @Test func eachOldLetterIsTakenOnce() {
        let pairs = FieldWords.shared(Array("Good evening"), Array("Enter a web address"))
        #expect(Set(pairs.values).count == pairs.count)
        #expect(pairs.values.allSatisfy { $0 < "Good evening".count })
    }

    @Test func nothingSharedWithNothing() {
        #expect(FieldWords.shared([], Array("Enter a web address")).isEmpty)
        #expect(FieldWords.shared(Array("abc"), []).isEmpty)
    }
}
