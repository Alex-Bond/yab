import Foundation
import Testing
@testable import Fast

/// A routine that keeps a folder (Routines.folderWords, LiveFolders.keep):
/// what a run's list changes in it.
struct RoutineFolderTests {
    private func item(_ path: String, _ words: String? = nil, loud: Bool = false, gone: Bool = false) -> LiveItem {
        let url = URL(string: "https://zillow.com/" + path)!
        return LiveItem(key: LiveFolder.page(url)!, url: url, title: path, group: "", words: nil, updated: nil,
                        said: words.map { LiveSaid(text: $0, loud: loud, gone: gone) })
    }

    private func held(_ path: String, _ words: String? = nil, brought: Bool = true) -> LiveFolder.Held {
        LiveFolder.Held(id: UUID(), key: LiveFolder.page(URL(string: "https://zillow.com/" + path)), brought: brought, words: nil,
                        said: words.map { LiveSaid(text: $0) })
    }

    @Test func newOnesComeInWithTheirWords() {
        let diff = LiveFolder.diff([item("a", "$4,250"), item("b", "New", loud: true)], held: [], today: [:], elsewhere: [], hidden: [])
        #expect(diff.add.map(\.title) == ["a", "b"])
        #expect(diff.add.last?.said == LiveSaid(text: "New", loud: true))
    }

    @Test func changedWordsAreSaidAndTheRestLeftAlone() {
        let a = held("a", "$3,950"), b = held("b", "$4,400")
        let diff = LiveFolder.diff([item("a", "$3,800 · −$150"), item("b", "$4,400")], held: [a, b], today: [:], elsewhere: [], hidden: [])
        #expect(diff.add.isEmpty && diff.remove.isEmpty)
        #expect(diff.said == [a.id: LiveSaid(text: "$3,800 · −$150")])
    }

    @Test func aGoneOneStaysOneRunMoreThenGoes() {
        let a = held("a", "$4,480")
        let gone = LiveFolder.diff([item("a", "Rented", gone: true)], held: [a], today: [:], elsewhere: [], hidden: [])
        #expect(gone.remove.isEmpty)
        #expect(gone.said[a.id] == LiveSaid(text: "Rented", gone: true))
        let next = LiveFolder.diff([], held: [held("a", "Rented")], today: [:], elsewhere: [], hidden: [])
        #expect(next.remove.count == 1)
    }

    @Test func aGoneOneNeverComesIn() {
        let diff = LiveFolder.diff([item("x", "Rented", gone: true)], held: [], today: [:], elsewhere: [], hidden: [])
        #expect(diff.add.isEmpty)
    }

    @Test func yoursStayWhateverTheListSays() {
        let mine = held("mine", nil, brought: false)
        let diff = LiveFolder.diff([], held: [mine], today: [:], elsewhere: [], hidden: [])
        #expect(diff.remove.isEmpty)
    }

    @Test func yoursLeftOutLoseTheirWordsNotTheirPlace() {
        let mine = held("mine", "Closed", brought: false)
        let diff = LiveFolder.diff([], held: [mine], today: [:], elsewhere: [], hidden: [])
        #expect(diff.remove.isEmpty)
        #expect(diff.said.keys.contains(mine.id))
        #expect(diff.said[mine.id] == .some(nil))
    }

    @Test func wwwIsOnlyTheHostsStart() {
        #expect(LiveFolder.page(URL(string: "https://awww.example.com/a")) == "awww.example.com/a")
        #expect(LiveFolder.page(URL(string: "https://www.example.com/a")) == "example.com/a")
    }

    @Test func aPageIsKnownWhateverWayItWasReached() {
        let plain = LiveFolder.page(URL(string: "https://www.zillow.com/homedetails/123/?utm_source=x&b=2&a=1#photos"))
        let again = LiveFolder.page(URL(string: "https://zillow.com/homedetails/123?a=1&b=2"))
        #expect(plain == again)
        #expect(plain == "zillow.com/homedetails/123?a=1&b=2")
    }

    @Test func loudNewWordsCallOutUntilOpened() {
        var mark = LiveMark(key: "k", words: nil, seen: nil, folder: nil, said: LiveSaid(text: "New", loud: true))
        #expect(mark.callsOut)
        mark.heard = mark.said
        #expect(!mark.callsOut)
        mark.said = LiveSaid(text: "Rented", loud: true, gone: true)
        #expect(!mark.callsOut)
    }

    @Test func itsRowSaysItKeepsAFolder() {
        var routine = Routine(id: "r1", when: "hourly", prompt: "Mission 1BR", last: nil)
        routine.folder = true
        routine.ended = Date()
        routine.found = 2
        #expect(Routines.status(routine, live: false).hasPrefix("Folder · Ran at"))
        #expect(Routines.status(routine, live: false).hasSuffix("2 new"))
    }
}
