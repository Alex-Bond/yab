import AppKit

/// An Edit command for an extension's action popup on a Chromium tab, by the
/// name of the popup view's own action (`paste:` on Chrome's
/// RenderWidgetHostViewCocoa). The renderer on a Mac reads ⌘V as a plain key:
/// in Chrome the Edit menu turns it into the view's paste:, and the helper
/// that draws the popup has no Edit menu, so Yab names the command
/// (YabCore popup.input kind "edit").
enum ChromiumPopupEdit: String, CaseIterable {
    case paste, pasteAndMatchStyle, copy, cut, selectAll, undo, redo

    /// The command a key means when it reaches the popup itself: ⌘A, ⌘C,
    /// ⌘V, ⌘X, ⌘Z, ⇧⌘Z and ⌥⇧⌘V, read by the key's letter on this layout.
    static func command(for event: NSEvent) -> ChromiumPopupEdit? {
        guard event.type == .keyDown, let typed = event.charactersIgnoringModifiers?.lowercased(),
              let letter = KeyLayout.keyName(for: typed, at: event.keyCode, on: .current)?.lowercased() else { return nil }
        return command(letter: letter, flags: event.modifierFlags)
    }

    static func command(letter: String, flags: NSEvent.ModifierFlags) -> ChromiumPopupEdit? {
        let held = flags.intersection([.command, .shift, .option, .control])
        switch (letter, held) {
        case ("v", [.command]): return .paste
        case ("v", [.command, .shift, .option]): return .pasteAndMatchStyle
        case ("c", [.command]): return .copy
        case ("x", [.command]): return .cut
        case ("a", [.command]): return .selectAll
        case ("z", [.command]): return .undo
        case ("z", [.command, .shift]): return .redo
        default: return nil
        }
    }
}
