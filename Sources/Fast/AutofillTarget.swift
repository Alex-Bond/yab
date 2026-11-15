import AppKit

extension Browser {
    /// A field belongs to its page, including a link in a small window.
    func autofillTab(_ id: Tab.ID) -> Tab? {
        tabs.first { $0.id == id } ?? outside.first { $0.id == id }
    }

    /// Only the page in the key window can offer autofill. Hidden extension
    /// pages and selected tabs behind a small window cannot take its fields.
    func offersAutofill(_ tab: Tab) -> Bool {
        guard !tab.gone, !tab.asleep, let web = tab.builtPage, !web.isHiddenOrHasHiddenAncestor,
              let window = web.window, window.isKeyWindow else { return false }
        if peeking?.id == tab.id { return peekView?.window === window }
        if tabs.contains(where: { $0.id == tab.id }) { return tab.id == activeID && peeking == nil }
        return outside.contains(where: { $0.id == tab.id })
    }
}
