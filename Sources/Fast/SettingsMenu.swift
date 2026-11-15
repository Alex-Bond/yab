import AppKit
import SwiftUI

/// One row of a Settings menu (an account's or a key's ···, or its
/// right-click). Built by `SettingsMenu.make`, which puts every destructive
/// row last, under a separator, in red: SwiftUI's destructive role has no
/// red title in a macOS menu, so these menus are AppKit's.
enum SettingsMenuEntry {
    case item(String, enabled: Bool = true, act: () -> Void)
    /// A row with a check by it while `on`.
    case toggle(String, on: Bool, enabled: Bool = true, act: () -> Void)
    /// A small grey title over the rows after it.
    case header(String)
    case separator
    /// Remove, Disconnect: red, at the end, under a separator.
    case destructive(String, act: () -> Void)
}

@MainActor
enum SettingsMenu {
    /// The menu for `entries`: separators only between rows, never two in
    /// a row or at an end, and the destructive rows last under their own.
    static func make(_ entries: [SettingsMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var rows: [NSMenuItem?] = []
        var last: [NSMenuItem] = []
        for entry in entries {
            switch entry {
            case .item(let title, let enabled, let act):
                let item = PageMenuItem(title, act: act)
                item.isEnabled = enabled
                rows.append(item)
            case .toggle(let title, let on, let enabled, let act):
                let item = PageMenuItem(title, act: act)
                item.state = on ? .on : .off
                item.isEnabled = enabled
                rows.append(item)
            case .header(let title):
                rows.append(NSMenuItem.sectionHeader(title: title))
            case .separator:
                rows.append(nil)
            case .destructive(let title, let act):
                last.append(destructive(title, act: act))
            }
        }
        if !last.isEmpty { rows.append(nil) }
        rows += last.map { Optional($0) }
        for row in rows {
            if let row { menu.addItem(row); continue }
            // A header with nothing under it goes; a separator only after
            // a row, and only one.
            while let tail = menu.items.last, tail.isSectionHeader { menu.removeItem(tail) }
            if let tail = menu.items.last, !tail.isSeparatorItem { menu.addItem(.separator()) }
        }
        while let tail = menu.items.last, tail.isSeparatorItem || tail.isSectionHeader { menu.removeItem(tail) }
        return menu
    }

    /// A red row in the menu's own font, as Remove Gemini first was.
    static func destructive(_ title: String, act: @escaping () -> Void) -> PageMenuItem {
        let item = PageMenuItem(title, act: act)
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0),
        ])
        return item
    }

    /// Opens `entries` under `view`, where a pop-up button's list would.
    static func open(_ entries: [SettingsMenuEntry], under view: NSView?) {
        guard let view, view.window != nil else { return }
        let menu = make(entries)
        // Return from AXPress before AppKit starts tracking the menu.
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view) }
    }
}

/// A Settings row's ··· button: its face as the row draws it, and on a
/// press the native menu of `entries`. `title` names it to VoiceOver and
/// to the bench's anchor-menu.
struct SettingsMoreMenu<Face: View>: View {
    let title: String
    let entries: () -> [SettingsMenuEntry]
    @ViewBuilder let face: () -> Face
    @State private var place = DropAnchor.Place()

    init(_ title: String, entries: @escaping () -> [SettingsMenuEntry], @ViewBuilder face: @escaping () -> Face) {
        self.title = title
        self.entries = entries
        self.face = face
    }

    var body: some View {
        Button(action: open) { face() }
            .buttonStyle(.plain)
            .background(DropAnchor(place: place, title: title, press: open, hover: { _ in }))
            .accessibilityLabel(title)
    }

    private func open() { SettingsMenu.open(entries(), under: place.view) }
}

extension View {
    /// A right-click (or control-click) on this row opens the native menu
    /// of `entries` at the pointer, as `.contextMenu` would, with its
    /// destructive rows red. Every other press goes through to the row.
    func settingsContextMenu(_ entries: @escaping () -> [SettingsMenuEntry]) -> some View {
        overlay { SettingsContextMenu(entries: entries) }
    }
}

private struct SettingsContextMenu: NSViewRepresentable {
    let entries: () -> [SettingsMenuEntry]

    func makeNSView(context: Context) -> SettingsContextMenuView { SettingsContextMenuView() }

    func updateNSView(_ view: SettingsContextMenuView, context: Context) { view.entries = entries }
}

final class SettingsContextMenuView: NSView {
    var entries: (() -> [SettingsMenuEntry])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        BookmarkBar.asksForMenu(NSApp.currentEvent) ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        entries.map { SettingsMenu.make($0()) }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let menu = self.menu(for: event) else { return super.mouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
