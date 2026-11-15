import Foundation
import Testing
@testable import Fast

// A search's folder (Research.swift): which pages are results pages and the
// words they were asked for, what a tab in the folder is called, and when a
// later search is the same inquiry.
struct ResearchTests {
    static func terms(_ address: String, custom: String = "") -> String? {
        Engine.terms(of: URL(string: address)!, custom: custom)
    }

    @Test func enginesSayTheirWords() {
        #expect(Self.terms("https://www.google.com/search?q=cheap+flights+lisbon&sca_esv=1") == "cheap flights lisbon")
        #expect(Self.terms("https://www.google.co.uk/search?q=flights%20lisbon") == "flights lisbon")
        #expect(Self.terms("https://duckduckgo.com/?q=rust+borrow+checker&ia=web") == "rust borrow checker")
        #expect(Self.terms("https://kagi.com/search?q=swiftui+lazyvstack") == "swiftui lazyvstack")
        #expect(Self.terms("https://www.bing.com/search?q=espresso+grinder") == "espresso grinder")
        #expect(Self.terms("https://www.startpage.com/sp/search?query=standing+desk") == "standing desk")
        #expect(Self.terms("https://search.brave.com/search?q=hiking+boots") == "hiking boots")
        #expect(Self.terms("https://www.ecosia.org/search?q=tram+lisbon") == "tram lisbon")
        #expect(Self.terms("https://yandex.com/search/?text=weather+boston") == "weather boston")
    }

    @Test func otherPagesAreNotResults() {
        #expect(Self.terms("https://www.google.com/maps?q=lisbon") == nil)
        #expect(Self.terms("https://www.google.com/search") == nil)
        #expect(Self.terms("https://www.google.com/search?q=+++") == nil)
        #expect(Self.terms("https://example.com/search?q=lisbon") == nil)
        #expect(Self.terms("https://www.bing.com/maps?q=lisbon") == nil)
        #expect(Self.terms("https://news.ycombinator.com/item?id=1") == nil)
    }

    @Test func yourOwnEngineToo() {
        let own = "https://search.example.org/find?term=%s&lang=en"
        #expect(Self.terms("https://search.example.org/find?term=lisbon+trams&lang=en", custom: own) == "lisbon trams")
        #expect(Self.terms("https://search.example.org/other?term=lisbon", custom: own) == nil)
        #expect(Self.terms("https://elsewhere.org/find?term=lisbon", custom: own) == nil)
    }

    @Test func aFolderIsNamedForTheWords() {
        #expect(Research.name("cheap  flights lisbon") == "Cheap flights lisbon")
        #expect(Research.name("iPhone case") == "IPhone case")
    }

    @Test func rowsSayWhatSetsThemApart() {
        let asked = "cheap flights lisbon"
        #expect(Research.label(title: "Cheap Flights to Lisbon | Skyscanner", host: "www.skyscanner.net", search: asked) == "skyscanner.net")
        #expect(Research.label(title: "Cheap flights to Lisbon from €89 - TAP Air Portugal", host: "www.flytap.com", search: asked) == "€89 - TAP Air Portugal")
        #expect(Research.label(title: "Lisbon travel guide - Lonely Planet", host: "www.lonelyplanet.com", search: asked) == "Travel guide")
        // A possessive and a plural are the words searched too.
        #expect(Research.label(title: "Lisbon's Tram 28: A Must-Have Experience in Portugal", host: "storiesmysuitcasecouldtell.com", search: "lisbon tram 28") == "Must-Have Experience in Portugal")
        #expect(Research.label(title: "Trams in Lisbon - Visit Portugal", host: "www.visitportugal.com", search: "lisbon tram 28") == "visitportugal.com")
        // Nothing of the words in it: as it is.
        #expect(Research.label(title: "Ryanair", host: "www.ryanair.com", search: asked) == nil)
        // The results page itself.
        #expect(Research.label(title: "cheap flights lisbon - Google Search", host: "www.google.com", search: asked) == "google.com")
    }

    @Test func aLaterSearchKeepsTheFolderWhenAlike() {
        #expect(Research.alike("flights lisbon", "cheap flights lisbon may"))
        #expect(Research.alike("cheap flights to lisbon", "flights lisbon"))
        #expect(!Research.alike("flights lisbon", "hotels porto"))
        #expect(!Research.alike("", "anything"))
    }
}
