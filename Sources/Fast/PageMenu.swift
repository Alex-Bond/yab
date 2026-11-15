import AppKit

/// A menu item that runs a closure, for menus built in code (LinkWindow's),
/// and shows a shortcut written the way a person writes one, "⌘⌫", "⇧⌘B",
/// "↩", as the Mac draws shortcuts.
final class PageMenuItem: NSMenuItem {
    private let act: () -> Void

    init(_ title: String, act: @escaping () -> Void) {
        self.act = act
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { act() }

    /// A shortcut chosen in Settings, including named keys and function keys.
    func shortcut(_ hotkey: Hotkey) {
        let named: [String: String] = [
            "↩": "\r", "⇥": "\t", "⌫": "\u{8}", "⌦": "\u{7f}", "esc": "\u{1b}", "space": " ",
            "←": String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            "→": String(UnicodeScalar(NSRightArrowFunctionKey)!),
            "↑": String(UnicodeScalar(NSUpArrowFunctionKey)!),
            "↓": String(UnicodeScalar(NSDownArrowFunctionKey)!),
        ]
        let key: String?
        if let equivalent = named[hotkey.key] {
            key = equivalent
        } else if hotkey.key.hasPrefix("f"), let number = Int(hotkey.key.dropFirst()), (1...35).contains(number),
                  let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
            key = String(scalar)
        } else {
            key = hotkey.key.count == 1 ? hotkey.key : nil
        }
        keyEquivalent = key ?? ""
        keyEquivalentModifierMask = hotkey.flags
    }

    func shortcut(_ keys: String) {
        var mask: NSEvent.ModifierFlags = []
        var key = ""
        for character in keys {
            switch character {
            case "⌘": mask.insert(.command)
            case "⇧": mask.insert(.shift)
            case "⌥": mask.insert(.option)
            case "⌃": mask.insert(.control)
            case "↩": key = "\r"
            case "⌫": key = "\u{8}"
            case "⎋": key = "\u{1b}"
            case "⇥": key = "\t"
            default: key = String(character).lowercased()
            }
        }
        keyEquivalent = key
        keyEquivalentModifierMask = mask
    }
}

/// A submenu that lists its rows again each time it opens, so rows still
/// being learned when the menu above it opened are there once it is looked
/// at. Its rows say for themselves whether they can be picked.
final class FreshMenu: NSMenu, NSMenuDelegate {
    private let rows: () -> [NSMenuItem]

    init(_ title: String, rows: @escaping () -> [NSMenuItem]) {
        self.rows = rows
        super.init(title: title)
        autoenablesItems = false
        delegate = self
        items = rows()
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) { items = rows() }
}
