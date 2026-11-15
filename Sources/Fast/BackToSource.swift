import AppKit

extension Browser {
    /// A link's first page has one more Back destination: the tab it came
    /// from. `from` also covers typed addresses and split copies, so it is
    /// deliberately not the eligibility rule.
    func linkBack(_ tab: Tab, to source: Tab) {
        tab.backLinkSource = source.id
        tab.backSourceAvailable = backSource(for: tab) != nil
    }

    func backSource(for tab: Tab) -> Tab? {
        guard let id = tab.backLinkSource, id != tab.id,
              !tab.gone, tab.pin == nil, !tab.kept, !tab.bench else { return nil }
        return (tabs + outside).first { $0.id == id && !$0.gone }
    }

    /// Closing or moving a source updates the toolbar and menu immediately,
    /// including a link whose source lives in a Small Window.
    func refreshBackSources() {
        for tab in tabs + outside where tab.backLinkSource != nil {
            let available = backSource(for: tab) != nil
            if tab.backSourceAvailable != available { tab.backSourceAvailable = available }
        }
    }

    @discardableResult
    func closeBackToSource(_ tab: Tab) -> Bool {
        guard !tab.hasBackHistory, tab.builtPage?.canGoBack != true, let source = backSource(for: tab) else { return false }
        let sourceWindow = LinkWindow.all.first { $0.tab === source }
        if let link = LinkWindow.all.first(where: { $0.tab === tab }) {
            link.close()
        } else if peeking === tab {
            closePeek()
        } else {
            close(tab)
        }
        if let sourceWindow {
            sourceWindow.window.makeKeyAndOrderFront(nil)
        } else {
            select(source)
            BrowserWindows.shared.window(for: self)?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
