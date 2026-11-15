import Foundation
import Testing
@testable import Fast

// Dia asked through its scripting for its spaces and their tabs, since its
// own file stopped being written (feedback #113).
struct DiaScriptTests {
    let f = "\u{1F}", r = "\u{1E}"

    @Test func eachProfileWithItsPinsAndTabs() throws {
        let text = "P\(f)Personal\(f)1\(r)T\(f)true\(f)https://x.com/\(f)X\(r)T\(f)true\(f)https://youtube.com/\(f)YouTube\(r)"
            + "T\(f)false\(f)https://news.ycombinator.com/\(f)Hacker News\(r)"
            + "P\(f)Work\(f)2\(r)T\(f)true\(f)https://linear.app/\(f)Linear\(r)"
        let places = try #require(DiaScript.parse(text, names: ["Default": "Personal", "Profile 1": "Work"]))
        #expect(places.map(\.name) == ["Personal", "Work"])
        #expect(places.map(\.profile) == ["Default", "Profile 1"])
        #expect(places[0].shared && !places[1].shared)
        #expect(places[0].pinned.count == 2 && places[0].open.count == 1)
        #expect(places[1].pinned.count == 1 && places[1].open.isEmpty)
        #expect(places.allSatisfy { $0.isProfile })
    }

    /// Spaces whose names Local State doesn't have: never a profile folder
    /// that isn't there, signed in as nobody, nor one place twice.
    @Test func spacesOfOneProfileStayApart() throws {
        let text = "P\(f)MonChron\(f)1\(r)T\(f)true\(f)https://linear.app/\(f)Linear\(r)"
            + "P\(f)Personal\(f)2\(r)T\(f)false\(f)https://x.com/\(f)X\(r)"
        let places = try #require(DiaScript.parse(text, names: ["Default": "Sam"]))
        #expect(places.map(\.name) == ["MonChron", "Personal"])
        #expect(places.map(\.profile) == ["Default", "Default"])
        #expect(places.allSatisfy { $0.shared && !$0.isProfile })
        #expect(Set(places.map(\.id)).count == 2)
        #expect(places[0].pinned.count == 1 && places[1].open.count == 1)
    }

    @Test func aTitleWithOddLettersStaysWhole() throws {
        let text = "P\(f)Main\(f)1\(r)T\(f)false\(f)https://example.com/a\(f)Tabs\tand\nlines\(r)"
        let places = try #require(DiaScript.parse(text, names: [:]))
        #expect(places[0].profile == "Default")
        #expect(places[0].open.count == 1)
    }

    @Test func nothingFromAnEmptyAnswer() {
        #expect(DiaScript.parse("", names: [:]) == nil)
        #expect(DiaScript.parse("garbage", names: [:]) == nil)
    }
}
