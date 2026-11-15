import AppKit

/// A page's tooltip, a title="" under the pointer, drawn as every tip in Yab
/// is (PageTip). The page script says it (chromium-tips.js): CEF tells only an
/// offscreen view, and the helper's window isn't on screen to show one.
extension ChromiumPage {
    func receiveTooltip(_ text: String) {
        // Script replies can arrive after the native pointer left for an overlay.
        let text = hoverAdmitted ? text : ""
        let said = text.count > PageTip.longest ? String(text.prefix(PageTip.longest)) + "\u{2026}" : text
        guard said != tipText else { return }
        if !tipText.isEmpty { KeyTip.shared.leave(self) }
        tipText = said
        if !said.isEmpty { KeyTip.shared.hover(self, title: said, shortcut: nil, side: .pointer, wait: PageTip.wait) }
    }
}
