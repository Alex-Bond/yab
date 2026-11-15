import UIKit

/// ‹ held: this tab's way back in iOS's own menu, the nearest page on top,
/// each its title over its site, with the site's icon when Yab has one; a
/// row goes straight there. iOS gives the menu's feel and its ticks. The
/// pages are a section of their own; the menu ends in another (`trailing`),
/// All History under a line.
@MainActor
enum BackHistoryMenu {
    /// The last row's identifier, for tests.
    static let allHistory = "chrome.back.history.all"

    struct Row: Equatable {
        /// How many pages back from the one shown.
        let steps: Int
        let url: URL
        let title: String
        let site: String
        /// The bundled favicon's key for a test world's page, else the host.
        let icon: String
    }

    static func rows(_ items: [WebPool.BackItem]) -> [Row] {
        items.map { item in
            // A test world's page goes by its stem: the world's own title and site.
            if item.url.scheme == PageSchemeHandler.scheme, let stem = item.url.host(),
               let entry = PageFixtures.entries.first(where: { $0.stem == stem }) {
                let site = entry.url.components(separatedBy: "/").first ?? entry.site
                return Row(steps: item.steps, url: item.url, title: item.title.isEmpty ? entry.title : item.title,
                           site: site, icon: entry.fav)
            }
            let host = item.url.host()?.lowercased() ?? item.url.absoluteString
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return Row(steps: item.steps, url: item.url, title: item.title.isEmpty ? site : item.title,
                       site: site, icon: host)
        }
    }

    static func make(_ rows: [Row], isPrivate: Bool, go: @escaping (Row) -> Void,
                     trailing: [UIMenuElement] = []) -> [UIMenuElement] {
        let pages = rows.map { row in
            let id = "chrome.back.history.\(row.steps)"
            let action = UIAction(title: row.title, subtitle: row.site, image: icon(for: row, isPrivate: isPrivate),
                                  identifier: UIAction.Identifier(id)) { _ in go(row) }
            action.accessibilityIdentifier = id
            return action
        }
        return [UIMenu(options: .displayInline, children: pages)] + trailing
    }

    /// The site's icon as large as a menu's glyphs, rounded like a favicon; the
    /// globe when there is none. Private rows use bundled icons only.
    static func icon(for row: Row, isPrivate: Bool) -> UIImage? {
        let web = row.url.scheme != PageSchemeHandler.scheme
        guard let image = FaviconImages.image(row.icon, host: web ? row.url.host() : row.site,
                                              url: web ? row.url : nil, isPrivate: isPrivate) else {
            return UIImage.menuGlyph(GlyphName.globe.asset)
        }
        return UIImage.menuIcon(image, radius: Metrics.Back.menuIconRadius)
    }
}

extension AppModel {
    /// ‹'s menu for the tab in front: its way back, each row checked again
    /// when chosen (the tab still in front, the page still that many back),
    /// then All History, the History screen (History/HistoryModel).
    func backHistoryMenu(for id: Tab.ID) -> [UIMenuElement] {
        let isPrivate = browser.tab(id)?.isPrivate == true || browser.space(holding: id)?.isPrivate == true
        let rows = BackHistoryMenu.rows(pages.backList(id))
        let all = UIAction(title: "All History", image: UIImage.menuGlyph(MacGlyph.yabClock),
                           identifier: UIAction.Identifier(BackHistoryMenu.allHistory)) { [weak self] _ in
            guard let self, !self.privateContentBlocked else { return }
            self.showHistory()
        }
        all.accessibilityIdentifier = BackHistoryMenu.allHistory
        return BackHistoryMenu.make(rows, isPrivate: isPrivate, go: { [weak self] row in
            guard let self, self.browser.tab?.id == id, !self.privateContentBlocked,
                  self.pages.backList(id).contains(where: { $0.steps == row.steps && $0.url == row.url }) else { return }
            self.pages.go(id, by: -row.steps)
        }, trailing: [UIMenu(options: .displayInline, children: [all])])
    }
}
