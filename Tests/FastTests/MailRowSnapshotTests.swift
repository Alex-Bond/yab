import Foundation
import Testing
@testable import Fast

// Crash311: SwiftUI may ask an old ForEach child for its content after the
// live list has shrunk. These exercise the same deferred presentation path
// as MailListView, including grouping and MailSelection, without mail accounts.
@MainActor
struct MailRowSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ thread: String, who: String = "Ada", account: String = "a", daysAgo: Int = 0) -> MailDesk.Row {
        MailDesk.Row(account: account, thread: thread, who: who, whoFull: who, subject: thread, line: "",
                     at: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!,
                     unread: false, count: 1, when: "", snoozed: false, scheduled: nil)
    }

    private func snapshot(_ rows: [MailDesk.Row], _ selection: MailSelection = MailSelection(),
                          chosen: Int = 0, group: String? = "sender", ghost: Bool = false) -> MailListView.RowSnapshot {
        MailListView.RowSnapshot(rows: rows, selection: selection, chosen: chosen, group: group, ghost: ghost)
    }

    @Test func deferredLastRowKeepsItsNeighboursAfterTheLiveListShrinks() {
        var liveRows = [row("one"), row("two"), row("three")]
        var liveSelection = MailSelection()
        liveSelection.all(liveRows.map(\.id))
        let render = snapshot(liveRows, liveSelection, chosen: 2)
        let deferred = { render.presentation(at: 2, now: self.now) }

        liveRows.removeLast(2)
        liveSelection.keep(liveRows.map(\.id))
        let old = deferred()
        #expect(old.row.id == "a|three")
        #expect(old.chosen && old.picked && old.picking)
        #expect(old.joinsUp && !old.joinsDown)
        #expect(old.heading == nil)
        let fresh = snapshot(liveRows, liveSelection).presentation(at: 0, now: now)
        #expect(fresh.row.id == "a|one")
        #expect(fresh.heading == "Ada · 1")
        #expect(!fresh.joinsUp && !fresh.joinsDown)
    }

    @Test func deferredMiddleRowKeepsBothJoinsAfterTheLiveListIsEmptied() {
        var liveRows = [row("one"), row("two"), row("three")]
        var liveSelection = MailSelection()
        liveSelection.all(liveRows.map(\.id))
        let render = snapshot(liveRows, liveSelection, chosen: 1)
        let deferred = { render.presentation(at: 1, now: self.now) }

        liveRows.removeAll()
        liveSelection.clear()
        let old = deferred()
        #expect(old.row.id == "a|two")
        #expect(old.chosen && old.picked && old.joinsUp && old.joinsDown)
        #expect(old.picking)
        #expect(snapshot(liveRows, liveSelection).rows.isEmpty)
    }

    @Test func sameCountReorderingCannotSubstituteAnotherRowsSelection() {
        var liveRows = [row("one"), row("two"), row("three")]
        var selection = MailSelection()
        selection.toggle(liveRows[0].id)
        let render = snapshot(liveRows, selection, chosen: 1)
        let deferred = { render.presentation(at: 1, now: self.now) }

        liveRows.swapAt(0, 2)
        let old = deferred()
        let fresh = snapshot(liveRows, selection, chosen: 1).presentation(at: 1, now: now)
        #expect(old.row.id == fresh.row.id)
        #expect(old.joinsUp && !old.joinsDown)
        #expect(!fresh.joinsUp && fresh.joinsDown)
        #expect(!old.picked && !fresh.picked)
    }

    @Test func headingsUseTheSameRowsAndGroupingAsTheirDeferredChild() {
        var liveRows = [row("one"), row("two"), row("three", who: "Bea", daysAgo: 1)]
        var liveGroup: String? = "sender"
        let render = snapshot(liveRows, group: liveGroup)
        let deferred = { render.presentation(at: 0, now: self.now) }

        liveRows = [row("new", who: "Cy", daysAgo: 1)]
        liveGroup = "when"
        let old = deferred()
        let fresh = snapshot(liveRows, group: liveGroup).presentation(at: 0, now: now)
        #expect(old.row.id == "a|one" && old.heading == "Ada · 2")
        #expect(fresh.row.id == "a|new" && fresh.heading == "Yesterday · 1")
    }

    @Test func selectionAndCursorChangeOnlyInTheNextPresentation() {
        let rows = [row("one"), row("two")]
        var selection = MailSelection()
        selection.all(rows.map(\.id))
        var chosen = 0
        let render = snapshot(rows, selection, chosen: chosen)
        let deferred = { render.presentation(at: 0, now: self.now) }

        selection.clear()
        chosen = 1
        let old = deferred()
        let fresh = snapshot(rows, selection, chosen: chosen).presentation(at: 0, now: now)
        #expect(old.chosen && old.picked && old.picking && old.joinsDown)
        #expect(!fresh.chosen && !fresh.picked && !fresh.picking && !fresh.joinsDown)
    }

    @Test func accountQualifiedIDsKeepSelectionSeparate() {
        let rows = [row("same", account: "first"), row("same", account: "second")]
        var selection = MailSelection()
        selection.toggle(rows[0].id)
        let render = snapshot(rows, selection)
        #expect(render.rows.map(\.id) == ["first|same", "second|same"])
        let first = render.presentation(at: 0, now: now)
        let second = render.presentation(at: 1, now: now)
        #expect(first.picked && !first.joinsUp && !first.joinsDown)
        #expect(!second.picked && second.joinsUp && !second.joinsDown)
    }

    @Test func ghostAndUngroupedListsKeepTheirExistingPresentationRules() {
        let rows = [row("one"), row("two")]
        let ghost = snapshot(rows, ghost: true)
        let ungrouped = snapshot(rows, group: nil)
        #expect(ghost.presentation(at: 0, now: now).heading == nil)
        #expect(ungrouped.presentation(at: 0, now: now).heading == nil)
        #expect(snapshot(rows).presentation(at: 0, now: now).heading == "Ada · 2")
        #expect(!ghost.presentation(at: 0, now: now).picking)
    }
}
