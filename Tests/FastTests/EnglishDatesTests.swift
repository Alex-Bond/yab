import Foundation
import SyncKit
import Testing

// Yab's dates are English whatever language the Mac is set to: the locale's
// language becomes English, its region and keywords stay.
struct EnglishDatesTests {
    @Test func theLanguageBecomesEnglishAndTheRegionStays() {
        #expect(EnglishDates.identifier(system: "fr_FR") == "en_FR")
        #expect(EnglishDates.identifier(system: "de_DE") == "en_DE")
        #expect(EnglishDates.identifier(system: "sr_Latn_RS") == "en_RS")
        #expect(EnglishDates.identifier(system: "ja_JP@calendar=japanese") == "en_JP@calendar=japanese")
        #expect(EnglishDates.identifier(system: "uk") == "en")
    }

    @Test func anEnglishOneIsLeftAsItIs() {
        #expect(EnglishDates.identifier(system: "en_GB") == "en_GB")
        #expect(EnglishDates.identifier(system: "en_US@rg=gbzzzz") == "en_US@rg=gbzzzz")
        #expect(EnglishDates.identifier(system: nil) == nil)
        #expect(EnglishDates.identifier(system: "") == nil)
    }

    @Test func aGermanMacsDateReadsInEnglish() throws {
        let id = try #require(EnglishDates.identifier(system: "de_DE"))
        let day = try #require(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                              year: 2026, month: 10, day: 15).date)
        let words = day.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: id)))
        #expect(words.contains("Oct"), "\(words)")
        #expect(!words.contains("Okt"), "\(words)")
        #expect(Locale(identifier: id).region?.identifier == "DE")
    }
}
