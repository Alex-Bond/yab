import Testing
@testable import Fast

// The chapters a page lists, as the floating video's bar takes them: only a
// list that fits the video playing, in order, starting at its beginning.
struct ChaptersTests {
    typealias Chapter = Floater.Chapter

    @Test func readsWhatThePageAnswers() {
        let list = Chapter.list([[0, "Intro"], [67.5, "Series preview"], ["x", "no start"], [Double.infinity, "none"], [12]])
        #expect(list == [Chapter(start: 0, title: "Intro"), Chapter(start: 67.5, title: "Series preview")])
        #expect(Chapter.list(nil).isEmpty)
        #expect(Chapter.list("chapters").isEmpty)
    }

    @Test func keepsAListThatFits() {
        let list = [Chapter(start: 67, title: "B"), Chapter(start: 0, title: "A"), Chapter(start: 162, title: "C")]
        #expect(Chapter.fitted(list, length: 1120).map(\.title) == ["A", "B", "C"])
    }

    // A YouTube advert plays before the film, with the film's list already
    // on the page: the list runs past the advert's end.
    @Test func dropsAListForAnotherVideo() {
        let list = [Chapter(start: 0, title: "A"), Chapter(start: 67, title: "B"), Chapter(start: 1023, title: "C")]
        #expect(Chapter.fitted(list, length: 15).isEmpty)
        #expect(Chapter.fitted(list, length: 1023).isEmpty)
        #expect(Chapter.fitted(list, length: 0).isEmpty)
        #expect(Chapter.fitted([Chapter(start: -1, title: "")] + list, length: 2000).isEmpty)
    }

    @Test func startsAtTheBeginningWithoutRepeats() {
        let list = [Chapter(start: 30, title: "B"), Chapter(start: 30.2, title: "B again"), Chapter(start: 90, title: "C")]
        let fitted = Chapter.fitted(list, length: 180)
        #expect(fitted.map(\.start) == [0, 30, 90])
        #expect(fitted.first?.title == "")
    }

    @Test func oneChapterIsNoChapters() {
        #expect(Chapter.fitted([Chapter(start: 0, title: "All of it")], length: 60).isEmpty)
        #expect(Chapter.fitted([], length: 60).isEmpty)
    }
}

// A small window's bar has seconds to a point: a click or the knob near a
// chapter's start is taken to it.
struct ChapterMagnetTests {
    typealias Chapter = Floater.Chapter
    let list = [Chapter(start: 0, title: "Intro"), Chapter(start: 245, title: "Spinning arrows"), Chapter(start: 520, title: "Circles")]

    @Test func takesANearPointToTheStart() {
        // 1487 s over 335 pt: the second chapter starts at 55.2 pt.
        #expect(Chapter.snapped(list, length: 1487, width: 335, at: 60) == 1)
        #expect(Chapter.snapped(list, length: 1487, width: 335, at: 48) == 1)
        #expect(Chapter.snapped(list, length: 1487, width: 335, at: 3) == 0)
    }

    @Test func leavesAFarPointWhereItIs() {
        #expect(Chapter.snapped(list, length: 1487, width: 335, at: 64) == nil)
        #expect(Chapter.snapped(list, length: 1487, width: 335, at: 30) == nil)
    }

    @Test func picksTheNearerOfTwoClose() {
        let close = [Chapter(start: 0, title: ""), Chapter(start: 100, title: "A"), Chapter(start: 130, title: "B")]
        // 1000 s over 100 pt: starts at 10 and 13 pt.
        #expect(Chapter.snapped(close, length: 1000, width: 100, at: 12) == 2)
        #expect(Chapter.snapped(close, length: 1000, width: 100, at: 11) == 1)
    }

    @Test func noChaptersNoMagnet() {
        #expect(Chapter.snapped([], length: 100, width: 300, at: 0) == nil)
        #expect(Chapter.snapped([Chapter(start: 0, title: "")], length: 100, width: 300, at: 0) == nil)
        #expect(Chapter.snapped(list, length: 0, width: 300, at: 0) == nil)
    }
}
