import AppKit

/// Every menu of the app, a context menu, a submenu, a menu under a button
/// or the menu bar's, is only as wide as its everyday words: a title longer
/// than `title` points, a long site in "Always Keep … Awake" or a bookmark's
/// name, is cut in the middle, its whole words in the item's tooltip.
/// SwiftUI's menus have no width of their own, so the cut is made as AppKit
/// adds or changes each item.
@MainActor enum MenuWidth {
    /// The widest a title is drawn: "Open Copy in New Window" and its keys
    /// still fit whole.
    static let title: CGFloat = 230

    private static var watching = false

    static func start() {
        guard !watching else { return }
        watching = true
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                MainActor.assumeIsolated { fit(note) }
            }
        }
    }

    private static func fit(_ note: Notification) {
        guard let menu = note.object as? NSMenu,
              let index = note.userInfo?["NSMenuItemIndex"] as? Int,
              index >= 0, index < menu.numberOfItems,
              let item = menu.item(at: index) else { return }
        // Short titles never reach the limit; drawn titles and views are
        // their owners' to size.
        guard item.title.count > 24, item.view == nil, item.attributedTitle == nil else { return }
        let font = item.menu?.font ?? NSFont.menuFont(ofSize: 0)
        guard let short = cut(item.title, font: font), short != item.title else { return }
        let whole = item.title
        item.title = short
        if item.toolTip == nil { item.toolTip = whole } // design: NSMenuItem has no view to wear a keyTip
    }

    /// The words cut in the middle to fit `title`, or nil when they fit.
    static func cut(_ words: String, font: NSFont, width: CGFloat = title) -> String? {
        func wide(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        guard wide(words) > width else { return nil }
        let characters = Array(words)
        var keep = 0, over = characters.count
        // The most characters, half from each end, that fit with "…".
        while keep + 1 < over {
            let middle = (keep + over) / 2
            if wide(joined(characters, keep: middle)) <= width { keep = middle } else { over = middle }
        }
        return joined(characters, keep: keep)
    }

    private static func joined(_ characters: [Character], keep: Int) -> String {
        let head = (keep + 1) / 2, tail = keep / 2
        let start = String(characters[..<head]).trimmingCharacters(in: .whitespaces)
        let end = String(characters[(characters.count - tail)...]).trimmingCharacters(in: .whitespaces)
        return start + "…" + end
    }
}
