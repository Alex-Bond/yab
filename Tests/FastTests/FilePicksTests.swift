import Testing
@testable import Fast

struct FilePicksTests {
    @Test func checkedFilesUseTheSameSetAcrossModifierClicksAndRanges() {
        let paths: [String?] = ["/fixture/a", nil, "/fixture/b", "/fixture/c"]
        let a: Set<String> = ["/fixture/a"]
        let ab = FilePicks.click(a, paths: paths, at: 2, anchor: 0, ranged: false)
        #expect(ab == ["/fixture/a", "/fixture/b"])
        #expect(FilePicks.click(ab, paths: paths, at: 2, anchor: 2, ranged: false) == a)
        #expect(FilePicks.click(ab, paths: paths, at: 1, anchor: 0, ranged: false) == ab)
        #expect(FilePicks.click(ab, paths: paths, at: 9, anchor: 0, ranged: true) == ab)
        #expect(FilePicks.click([], paths: paths, at: 3, anchor: 0, ranged: true) == ["/fixture/a", "/fixture/b", "/fixture/c"])
        #expect(FilePicks.click([], paths: paths, at: 0, anchor: 3, ranged: true) == ["/fixture/a", "/fixture/b", "/fixture/c"])
        #expect(FilePicks.click(["/other/kept"], paths: paths, at: 2, anchor: 0, ranged: true) == ["/other/kept", "/fixture/a", "/fixture/b"])
        #expect(FilePicks.click(a, paths: [], at: 0, anchor: 0, ranged: true) == a)
    }
}
