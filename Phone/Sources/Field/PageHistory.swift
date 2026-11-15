import Foundation

/// What each tab's own web view has shown since the field loaded another page
/// into it: a search or an address chosen in the plate's field replaces the
/// page, not the tab, so Back returns to the page before. The web view keeps
/// the history; this keeps what each of its pages is called (title, site,
/// icon, address), so the plate and the column say the page shown after Back
/// or Forward.
@MainActor
final class PageHistory {
    /// Per tab, the record of each page by its address.
    private var pages: [Tab.ID: [String: Tab]] = [:]

    /// Remembers what a page in a tab is called.
    func remember(_ page: Tab, in id: Tab.ID) {
        pages[id, default: [:]][Self.key(page.pageURL)] = page
    }

    /// What the page at `url` in a tab is called, if the field loaded it there.
    func page(at url: URL, in id: Tab.ID) -> Tab? {
        pages[id]?[Self.key(url)]
    }

    func forget(_ id: Tab.ID) { pages[id] = nil }

    /// An address as WebKit may hand it back: no trailing slash, the query's
    /// words decoded and in order.
    static func key(_ url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let host = (parts.host ?? "").lowercased()
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = (parts.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        return "\(parts.scheme ?? "")://\(host)/\(path)?\(query)"
    }
}

extension AppModel {
    /// Another page in a tab's own web view: the tab keeps its id, its place
    /// and its row (pinned, kept, today's, private), and Back returns to the
    /// page it showed before.
    func load(_ page: Tab, into tab: Tab) {
        var next = page
        next.id = tab.id
        next.place = tab.place
        next.isPrivate = tab.isPrivate
        next.onMac = tab.onMac
        next.badge = nil
        if fixturesEnabled {
            field.history.remember(tab, in: tab.id)
            field.history.remember(next, in: tab.id)
        }
        browser.replace(tab.id, with: next)
        // Dark or not is the new page's to say once it has loaded.
        chrome.pageDark[tab.id] = nil
        pages.load(tab.id, pages.loadingURL(for: next))
        tabChanged()
    }

    /// A tab's web view is at another page (a load, Back, Forward): the tab
    /// says the page it shows, when the field loaded that page into it.
    func pageCommitted(_ id: Tab.ID, _ url: URL) {
        guard let tab = browser.tab(id), let record = field.history.page(at: url, in: id),
              PageHistory.key(tab.pageURL) != PageHistory.key(url) else { return }
        var shown = record
        shown.isPrivate = tab.isPrivate
        shown.onMac = tab.onMac
        browser.replace(id, with: shown)
        // A page back from WebKit's cache says nothing again: its record does.
        chrome.pageDark[id] = nil
    }
}
