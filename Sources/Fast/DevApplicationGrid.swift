import AppKit
import SwiftUI

/// View-based, virtualized rows keep large storage values out of layout work.
struct DevApplicationGrid: NSViewRepresentable {
    struct Column: Equatable {
        var title: String
        var width: CGFloat
    }
    var columns: [Column]
    var rows: [ApplicationGridRow]
    var selected: String
    var editable: Set<Int> = []
    var pick: (ApplicationGridRow) -> Void
    var edit: ((ApplicationGridRow, Int, String) -> Void)?
    var remove: (() -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = Palette.NS.ground
        let table = ApplicationTable(); table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.identifier = NSUserInterfaceItemIdentifier("application-grid")
        table.rowHeight = 23; table.intercellSpacing = NSSize(width: 0, height: 0); table.backgroundColor = Palette.NS.ground
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]; table.gridColor = Palette.NS.hairline
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .regular; table.headerView = NSTableHeaderView()
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.beginEdit(_:))
        table.onDelete = { context.coordinator.parent.remove?() }
        table.onCopy = { context.coordinator.copyRow() }
        scroll.documentView = table; context.coordinator.table = table
        context.coordinator.update(self); ThreadScroller.put(on: scroll); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    @MainActor static func probe(_ window: NSWindow?) -> [String: Any] {
        guard let window, let content = window.contentView else { return [:] }
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.identifier?.rawValue == "application-grid" { return table }
            for child in view.subviews { if let table = find(child) { return table } }; return nil
        }
        guard let table = find(content), let scroll = table.enclosingScrollView else { return [:] }
        func rect(_ view: NSView, _ frame: NSRect) -> [Double] {
            let r = view.convert(frame, to: nil); return [r.minX, content.bounds.height - r.maxY, r.width, r.height]
        }
        return ["frame": rect(scroll, scroll.bounds), "rows": table.numberOfRows, "firstRow": table.numberOfRows > 0 ? rect(table, table.rect(ofRow: 0)) : [], "columns": table.tableColumns.indices.map { rect(table, table.rect(ofColumn: $0)) }]
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: DevApplicationGrid
        fileprivate weak var table: ApplicationTable?
        var rows: [ApplicationGridRow] = []
        var columns: [Column] = []
        var sortColumn: Int?
        var ascending = true
        var updating = false
        init(_ parent: DevApplicationGrid) { self.parent = parent }
        func update(_ parent: DevApplicationGrid) {
            self.parent = parent; guard let table else { return }; updating = true; defer { updating = false }
            if columns != parent.columns {
                for column in table.tableColumns { table.removeTableColumn(column) }
                columns = parent.columns; sortColumn = nil
                table.columnAutoresizingStyle = columns.count <= 3 ? .uniformColumnAutoresizingStyle : .noColumnAutoresizing
                for (i, definition) in columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
                    column.title = definition.title; column.width = definition.width; column.minWidth = 52
                    column.headerCell.font = .systemFont(ofSize: 11); table.addTableColumn(column)
                }
            }
            let next = sorted(parent.rows)
            if rows.map(\.id) != next.map(\.id) || rows.map(\.cells) != next.map(\.cells) {
                rows = next; table.reloadData()
            }
            if let index = rows.firstIndex(where: { $0.id == parent.selected }) {
                if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
        }
        func sorted(_ rows: [ApplicationGridRow]) -> [ApplicationGridRow] {
            guard let column = sortColumn else { return rows }
            return rows.sorted { a, b in
                let left = a.cells.indices.contains(column) ? a.cells[column] : "", right = b.cells.indices.contains(column) ? b.cells[column] : ""
                let result = left.localizedStandardCompare(right)
                return result == .orderedSame ? a.id < b.id : ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = Int(tableColumn?.identifier.rawValue ?? "") else { return nil }
            let id = NSUserInterfaceItemIdentifier("application-cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? NSTableCellView()
            cell.identifier = id
            let field: NSTextField
            if let existing = cell.textField { field = existing } else {
                field = NSTextField(string: ""); field.translatesAutoresizingMaskIntoConstraints = false
                field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
                field.isEditable = false; field.isSelectable = false
                cell.addSubview(field); cell.textField = field
                NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            field.font = DevMono.nsFont(11, weight: .regular); field.textColor = Palette.NS.ink
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
            if !field.isEditable {
                field.stringValue = rows[row].cells.indices.contains(column) ? rows[row].cells[column] : ""
            }
            field.keyTip(field.stringValue); field.delegate = self; field.identifier = NSUserInterfaceItemIdentifier(rows[row].id + "\u{1e}" + String(column))
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, rows.indices.contains(table.selectedRow) else { return }
            parent.pick(rows[table.selectedRow])
        }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let column = Int(tableColumn.identifier.rawValue) else { return }
            if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = true }
            update(parent)
        }
        @objc func beginEdit(_ sender: NSTableView) {
            let row = sender.clickedRow, column = sender.clickedColumn
            guard rows.indices.contains(row), parent.editable.contains(column), let cell = sender.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView, let field = cell.textField else { return }
            // selectText starts the field editor itself. Starting it first through
            // makeFirstResponder ends that first session and disables this field.
            field.isEditable = true; field.isSelectable = true; field.selectText(nil)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let identity = (field.identifier?.rawValue ?? "").components(separatedBy: "\u{1e}")
            field.isEditable = false; field.isSelectable = false
            guard let last = identity.last, let column = Int(last), let row = rows.first(where: { $0.id == identity.dropLast().joined(separator: "\u{1e}") }), parent.editable.contains(column) else { return }
            if row.cells.indices.contains(column), row.cells[column] != field.stringValue { parent.edit?(row, column, field.stringValue) }
        }
        func copyRow() {
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rows[table.selectedRow].cells.joined(separator: "\t"), forType: .string)
        }
    }
}

private final class ApplicationTable: NSTableView, DevKeyTarget {
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        super.keyDown(with: event)
    }
    @objc func copy(_ sender: Any?) { onCopy?() }
}
