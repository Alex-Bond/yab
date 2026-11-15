import AppKit
import SwiftUI

/// The column's rows on AppKit and Core Animation (docs/column-appkit.md)
/// rather than in SideBar's SwiftUI tree: each space's rows a page of its
/// own, kept alive, its rows reusable cells. On by default; the SwiftUI
/// column stays for a release behind the switch: the setting
/// `column.appkit` false, or `YAB_COLUMN=swiftui` in the environment
/// (`YAB_COLUMN=appkit` the other way), which wins over the setting. Read
/// once: a window made after a change takes it.
@MainActor
enum ColumnKit {
    static let key = "column.appkit"

    /// Every tab row's body run, either column's, for the bench: a title
    /// changing should run one.
    static var rowBodies = 0

    /// Parts of the column left out, for an experiment build's measure of
    /// what each costs a change of space: "head", "plate", "foot"
    /// (YAB_COLUMN_CUT, comma separated). Only on a test run.
    static let cut: Set<String> = {
        guard Store.testing, let given = ProcessInfo.processInfo.environment["YAB_COLUMN_CUT"] else { return [] }
        return Set(given.split(separator: ",").map(String.init))
    }()

    static let on: Bool = {
        switch ProcessInfo.processInfo.environment["YAB_COLUMN"] {
        case "appkit": return true
        case "swiftui": return false
        default: return Store.settings.object(forKey: key) as? Bool ?? true
        }
    }()
}

private struct ColumnHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Drawn in a cell of the AppKit column (ColumnPages), in a host of its
    /// own: `.global` there is the cell, not the window, so a row doesn't
    /// say where it stands (the page says it, from its layout).
    var columnHosted: Bool {
        get { self[ColumnHostedKey.self] }
        set { self[ColumnHostedKey.self] = newValue }
    }
}

private struct ColumnPointedKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// A row of the AppKit column: whether the pointer is on it, as the
    /// column works it out from where the pointer is and where its rows
    /// are (ColumnPage.point). Nil anywhere else, where a row hears the
    /// pointer itself.
    var columnPointed: Bool? {
        get { self[ColumnPointedKey.self] }
        set { self[ColumnPointedKey.self] = newValue }
    }
}

/// A row's own hover, only where the column doesn't say (`columnPointed`):
/// in the AppKit column the row installs no tracking of its own.
struct RowHover: ViewModifier {
    let on: Bool
    let heard: (Bool) -> Void

    func body(content: Content) -> some View {
        if on {
            content.onHover(perform: heard)
        } else {
            content
        }
    }
}

extension View {
    /// `action` with the view's frame in the window whenever it changes, as
    /// `onGeometryChange` gives it, only if `on`: a row in the AppKit
    /// column's own host (`columnHosted`) reports nothing this way, and the
    /// watch itself was run by every row of every frame of a scroll.
    @ViewBuilder func globalFrame(_ on: Bool, _ action: @escaping (CGRect) -> Void) -> some View {
        if on {
            onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: action)
        } else {
            self
        }
    }
}
