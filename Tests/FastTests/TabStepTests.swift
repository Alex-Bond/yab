import Foundation
import Testing
@testable import Fast

// ⇧⌘] and ⇧⌘[ pass a shut agent folder's tabs as if they weren't there.
struct TabStepTests {
    @Test func plainStepsRoundTheEnds() {
        let none = [Bool](repeating: false, count: 4)
        #expect(Browser.stepped(from: 0, by: 1, skipping: none) == 1)
        #expect(Browser.stepped(from: 3, by: 1, skipping: none) == 0)
        #expect(Browser.stepped(from: 0, by: -1, skipping: none) == 3)
    }

    @Test func passesAShutFolder() {
        // Yours, yours, then a shut folder of three.
        let shut = [false, false, true, true, true]
        #expect(Browser.stepped(from: 1, by: 1, skipping: shut) == 0)
        #expect(Browser.stepped(from: 0, by: -1, skipping: shut) == 1)
    }

    @Test func leavesAShutFolderFromInside() {
        // On a folder's tab (shown because you are on it): out to yours.
        let shut = [false, true, true, false]
        #expect(Browser.stepped(from: 1, by: 1, skipping: shut) == 3)
        #expect(Browser.stepped(from: 2, by: -1, skipping: shut) == 0)
    }

    @Test func nowhereElseToGo() {
        #expect(Browser.stepped(from: 0, by: 1, skipping: [false, true, true]) == nil)
        #expect(Browser.stepped(from: 0, by: 1, skipping: [false]) == nil)
    }

    @MainActor @Test func passesAShutFolderOfYours() {
        // A kept folder of yours, shut, is passed as a task's is; open, walked.
        let key = Nest.key(UUID())
        let place = Folders.Place(folder: key, shown: false, order: 0, listed: false, depth: 0, bare: false)
        let row: [Folders.Place?] = [nil, place, place, nil]
        let shut = Browser.passed(row, sealed: [false, false, false, false], open: { _ in false })
        #expect(shut == [false, true, true, false])
        #expect(Browser.stepped(from: 0, by: 1, skipping: shut) == 3)
        let open = Browser.passed(row, sealed: [false, false, false, false], open: { _ in true })
        #expect(open == [false, false, false, false])
    }

    @MainActor @Test(arguments: 0..<8) func passesEveryShutAncestor(_ state: Int) {
        let parent = Nest(name: "Parent", open: state & 1 != 0)
        let child = Nest(name: "Child", open: state & 2 != 0)
        let deepest = Nest(name: "Deepest", open: state & 4 != 0)
        child.parent = parent
        deepest.parent = child
        let tabs = (0..<5).map { _ in Tab() }
        defer { tabs.forEach { $0.close() } }
        for (tab, nest) in zip(tabs[1...3], [parent, child, deepest]) {
            tab.kept = true
            tab.nest = nest
        }
        let placed = Folders.lay(Folders.nests(in: tabs), isOpen: { $0.nest?.open ?? false },
                                 whole: [], folding: [], active: tabs[3].id).places
        let open = Set([parent, child, deepest].filter { $0.open }.map(\.key))
        let shut = Browser.passed(tabs.map { placed[$0.id] }, sealed: tabs.map { _ in false }, open: { open.contains($0) })
        #expect(shut == [false, !parent.open, !(parent.open && child.open), !(parent.open && child.open && deepest.open), false])
        // The selected tab peeks out, but a shut ancestor still blocks keys.
        #expect(placed[tabs[3].id]?.shown == true)
        let reachable = tabs.indices.filter { !shut[$0] }
        #expect(Browser.stepped(from: 0, by: 1, skipping: shut) == reachable[1])
        #expect(Browser.stepped(from: 4, by: -1, skipping: shut) == reachable[reachable.count - 2])
        #expect(Browser.stepped(from: 4, by: 1, skipping: shut) == 0)
        #expect(Browser.stepped(from: 0, by: -1, skipping: shut) == 4)
    }

    @MainActor @Test func foldedSpaceStillUsesItsVisibleRows() {
        let shown = Folders.Place(folder: "", shown: true, order: 0, depth: 0, bare: true)
        let hidden = Folders.Place(folder: "", shown: false, order: 0, depth: 0, bare: true)
        #expect(Browser.passed([shown, hidden], sealed: [false, false], open: { _ in false }) == [false, true])
    }
}
