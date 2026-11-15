import AppKit
import Testing
@testable import Fast

// The Network table's coordinator (DevNetTable.swift), asked about rows the
// table still counts while a new, shorter model is laid in (crash #26).
@MainActor
struct DevNetTableTests {
    private func model(_ items: [NetItem], columns: [String]) -> NetTableView.Model {
        NetTableView.Model(items: items, numbers: [:], columns: columns, selected: nil, up: [], down: [], big: false,
                           scale: NetScale(origin: 0, span: 1), horizon: nil, contentLoaded: nil, loaded: nil, sort: nil,
                           overridden: [:], empty: nil)
    }

    /// Fewer rows and other columns at once: re-laying the columns tiles the
    /// table, which asks whether its old rows are group rows before the
    /// reload; 0.0.15 trapped indexing past the new model's end.
    @Test func shorterModelWithNewColumnsDoesNotTrap() {
        let parent = NetTableView(model: model([], columns: ["name"]), select: { _ in }, open: { _ in }, sortBy: { _ in },
                                  hover: { _, _ in }, resend: { _ in }, rowMenu: { _ in NSMenu() }, headMenu: { NSMenu() },
                                  reveal: { _ in })
        let coordinator = parent.makeCoordinator()
        coordinator.parent = parent
        let table = NetTable()
        table.coordinator = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = table

        coordinator.update(model((0..<6).map { .frame("frame \($0)") }, columns: ["name"]))
        #expect(table.numberOfRows == 6)
        coordinator.update(model([], columns: ["name", "status"]))
        #expect(table.numberOfRows == 0)

        // As the table asks while it still counts the old rows.
        #expect(!coordinator.tableView(table, isGroupRow: 5))
        #expect(coordinator.tableView(table, heightOfRow: 5) == 21)
        #expect(!coordinator.tableView(table, shouldSelectRow: 5))
        #expect(coordinator.item(at: -1) == nil)
        #expect(coordinator.item(at: 0) == nil)
    }
}
