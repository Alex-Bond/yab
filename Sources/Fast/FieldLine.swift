import SwiftUI

/// The columns of Settings › Field's rows, as Extensions' are set out.
enum FieldLineColumn {
    static let gap: CGFloat = 10
    static let mark: CGFloat = 20
    /// The word a row ends on: an alias, a kind, a menu.
    static let status: CGFloat = 104
    /// The switch. A row with none keeps the room, so the words stand in
    /// one column down the page.
    static let end: CGFloat = 32
}

/// A row of Settings › Field: its mark, its name, a word in the status
/// column and the switch at the end. A row that is off is drawn faint, as
/// an extension that is off.
struct FieldLine<Mark: View, Status: View, End: View>: View {
    let title: String
    /// The line under the name, as SettingsRow's.
    var detail = ""
    var off = false
    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var status: () -> Status
    @ViewBuilder var end: () -> End

    init(_ title: String, detail: String = "", off: Bool = false, @ViewBuilder mark: @escaping () -> Mark,
         @ViewBuilder status: @escaping () -> Status, @ViewBuilder end: @escaping () -> End) {
        self.title = title
        self.detail = SettingsWords.text(detail)
        self.off = off
        self.mark = mark
        self.status = status
        self.end = end
    }

    var body: some View {
        HStack(spacing: FieldLineColumn.gap) {
            if Mark.self != EmptyView.self {
                mark().frame(width: FieldLineColumn.mark, height: FieldLineColumn.mark)
            }
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's gap between title and detail
                SettingsText(SettingsWords.text(title), size: 13)
                    .lineLimit(1)
                if !detail.isEmpty {
                    SettingsText(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            status().frame(width: FieldLineColumn.status, alignment: .leading)
            // The end's right edge is the row's, a menu wider than a switch
            // growing to the left over the empty status column.
            if End.self == EmptyView.self {
                Color.clear.frame(width: FieldLineColumn.end, height: 1)
            } else {
                end().frame(minWidth: FieldLineColumn.end, alignment: .trailing)
            }
        }
        .opacity(off ? 0.55 : 1)
    }
}

/// The minus at a row's end, where a switch would be, under the pointer. Its
/// plate stands over the row, so showing it never makes the row taller.
struct FieldLineRemove: View {
    let shown: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Color.clear
            .frame(width: FieldLineColumn.end, height: 1)
            .overlay(alignment: .trailing) {
                if shown { RemoveMinus(label: label, action: action).fixedSize() }
            }
    }
}

/// The small switch at a row's end, as Extensions' rows have it.
struct FieldSwitch: View {
    let title: String
    @Binding var on: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._on = isOn
    }

    var body: some View {
        Toggle(SettingsText.plain(SettingsWords.text(title)), isOn: $on)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

/// A row's own mark, drawn in the set.
struct FieldLineMark: View {
    let symbol: String

    var body: some View {
        Symbol(symbol, size: 12).foregroundStyle(.secondary)
    }
}

/// A row that drags: its mark at rest, the grip where it was under the
/// pointer, so hover moves nothing.
struct FieldGripMark<Mark: View>: View {
    let over: Bool
    @ViewBuilder var mark: () -> Mark

    var body: some View {
        ZStack {
            mark().opacity(over ? 0 : 1)
            Symbol("circle.grid.2x3", size: 12)
                .foregroundStyle(.secondary)
                .opacity(over ? 1 : 0)
        }
    }
}

/// The way to add to a list, under its last row, as Extensions' Add
/// Extension: muted until the hand is on it.
struct FieldAddLine: View {
    let title: String
    let press: () -> Void
    @State private var hovering = false

    init(_ title: String, press: @escaping () -> Void) {
        self.title = title
        self.press = press
    }

    var body: some View {
        Button(action: press) {
            HStack(spacing: FieldLineColumn.gap) {
                Symbol("plus", size: 11, weight: .semibold)
                    .frame(width: FieldLineColumn.mark)
                Text(SettingsWords.text(title))
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
        .onHover { hovering = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
