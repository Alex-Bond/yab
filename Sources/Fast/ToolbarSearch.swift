import AppKit

/// A Settings page's search in the window toolbar, as Shortcuts and Engines
/// for Sites have it: the system's glass button, which opens into a native
/// search field without a focus ring and goes back to the glass once it is
/// empty and has lost the keys. Real toolbar items receive AppKit's Liquid
/// Glass, sizing and keyboard behavior. A custom hosting view would bypass
/// that toolbar treatment.
@MainActor
final class ToolbarSearch: NSObject, NSSearchFieldDelegate {
    let id: NSToolbarItem.Identifier

    private let label: String
    private let prompt: String
    private let words: () -> String
    private let typed: (String) -> Void
    private weak var toolbar: NSToolbar?
    private weak var window: NSWindow?
    private var search: NSSearchToolbarItem?
    private(set) var searching = false

    /// `label` names the item, `prompt` is what the empty field says; the
    /// words themselves stay with the page, `words` and `typed` reach them.
    init(id: NSToolbarItem.Identifier, label: String, prompt: String, window: NSWindow,
         words: @escaping () -> String, typed: @escaping (String) -> Void) {
        self.id = id
        self.label = label
        self.prompt = prompt
        self.window = window
        self.words = words
        self.typed = typed
        super.init()
    }

    var field: NSSearchField? { search?.searchField }

    func attach(to toolbar: NSToolbar) { self.toolbar = toolbar }

    /// The page has gone, and its item with it.
    func detach() {
        searching = false
        search = nil
    }

    /// The field or the glass. A page come back to with words in its search
    /// shows them, rather than a filtered list and an empty glass.
    func item() -> NSToolbarItem {
        if searching || !words().isEmpty {
            searching = true
            let field = NSSearchField()
            field.placeholderString = prompt
            field.setAccessibilityLabel(prompt)
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 13)
            field.sendsSearchStringImmediately = true
            field.sendsWholeSearchString = false
            field.delegate = self
            field.target = self
            field.action = #selector(searchChanged(_:))
            field.stringValue = words()
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField = field
            item.preferredWidthForSearchField = 220
            item.label = label
            item.visibilityPriority = .high
            search = item
            return item
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = prompt // design: native toolbar items have no custom view for keyTip.
        item.image = Glyphs.image("magnifyingglass", size: 15)
        item.target = self
        item.action = #selector(openSearch(_:))
        item.isBordered = true
        item.visibilityPriority = .high
        return item
    }

    func sync() {
        if let field, field.stringValue != words() { field.stringValue = words() }
    }

    @objc private func openSearch(_ sender: Any?) { _ = begin() }

    @discardableResult
    func begin() -> NSSearchField? {
        if !searching { searching = true; replace() }
        guard let search else { return nil }
        // AppKit must attach the newly inserted field before it can take
        // keyboard focus. Do not start editing in a detached toolbar view.
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        search.beginSearchInteraction()
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        if search.searchField.window === window {
            window?.makeFirstResponder(search.searchField)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.search === search else { return }
                window?.contentView?.superview?.layoutSubtreeIfNeeded()
                search.beginSearchInteraction()
                window?.makeFirstResponder(search.searchField)
            }
        }
        return search.searchField
    }

    private func replace() {
        guard let toolbar, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) else { return }
        search = nil
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: id, at: index)
    }

    @objc private func searchChanged(_ sender: NSSearchField) { typed(sender.stringValue) }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSSearchField { searchChanged(field) }
    }

    func controlTextDidEndEditing(_ notification: Notification) { collapseEmpty() }
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        // Deleting a query is still editing: keep the field so the next
        // character can start a replacement query without another click.
        searchChanged(sender)
    }

    private func collapseEmpty() {
        DispatchQueue.main.async { [weak self] in
            // Opening hands the field's focus along more than once, and each
            // hand-over ends editing for a moment: only a field that has
            // really lost the keys goes back to the glass.
            guard let self, searching, words().isEmpty, field?.currentEditor() == nil else { return }
            searching = false
            replace()
        }
    }
}

extension NSToolbar {
    /// A page's own items at the toolbar's end, in order, or none of them.
    func keep(_ ids: [NSToolbarItem.Identifier], shown: Bool) {
        for id in ids {
            let index = items.firstIndex { $0.itemIdentifier == id }
            if shown, index == nil {
                insertItem(withItemIdentifier: id, at: items.count)
            } else if !shown, let index {
                removeItem(at: index)
            }
        }
    }
}
