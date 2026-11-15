import SwiftUI
import UIKit

/// Find on Page is iOS's own find bar (UIFindInteraction on the web view):
/// × on the left, the field with its options, the count, ↑ ↓, every match
/// marked and the page brought to the current one.
/// While it is up the plate, Back and + step aside; when it goes they come
/// back. From the page menu's tile, ⌘F (App/BrowserKeys), and the field's "On This Page" row.
extension AppModel {
    func findOnPage(_ id: Tab.ID? = nil, text: String? = nil) {
        guard let id = id ?? browser.tab?.id, browser.tab?.id == id else { return }
        if surfaces.menu == .plate { dropPageMenu() }
        _ = pages.view(for: browser.tab!)
        guard pages.presentFind(id, text: text) else { return }
        Motion.chromeButtons.run { pageMenu.finding = true }
        watchFind(id)
    }

    /// The find bar has no delegate to tell when it goes (WebKit keeps it),
    /// so it is looked at while up: four times a second, nothing more.
    private func watchFind(_ id: Tab.ID) {
        Task { @MainActor [weak self] in
            // Let the bar arrive before asking whether it is there.
            try? await Task.sleep(for: .milliseconds(600))
            while let self, self.pageMenu.finding {
                if !self.pages.isFinding(id) || self.browser.tab?.id != id {
                    if self.browser.tab?.id != id { self.pages.dismissFind(id) }
                    Motion.chromeButtons.run { self.pageMenu.finding = false }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
