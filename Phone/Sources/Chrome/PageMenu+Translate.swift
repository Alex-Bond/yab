import Foundation

/// The page menu's Translate rows (PageMenu's list): "Translate to English"
/// on a page in a language the person doesn't read, Show Original once it is
/// translated or on its way, and Always Translate <language> for the site,
/// which answers in place with its check. Translate and Show Original close
/// the menu, so the page itself shows what happened and the plate says it.
extension AppModel {
    /// The site in front is always translated from its page's language.
    var pageAlwaysTranslates: Bool {
        guard let tab = browser.tab, let page = translation.page(tab.id) else { return false }
        return siteSettings.alwaysTranslates(siteHost(of: tab), isPrivate: pageIsPrivate) == page.source
    }

    func pageMenuTranslate() {
        guard let tab = browser.tab, let page = translation.page(tab.id), !currentPageState.readerEnabled else { return }
        Haptics.play(.soft, reason: Haptics.Reason.pageToggle)
        dropPageMenu()
        if page.phase == .offered { translation.translate(tab.id) } else { translation.showOriginal(tab.id) }
    }

    /// On: remembered for the site and the page translated now if it isn't;
    /// off: forgotten, the page stays as it is.
    func pageMenuAlwaysTranslate() {
        guard let tab = browser.tab, let page = translation.page(tab.id) else { return }
        Haptics.play(.soft, reason: Haptics.Reason.pageToggle)
        let on = pageAlwaysTranslates
        siteSettings.setAlwaysTranslates(on ? nil : page.source, for: siteHost(of: tab), isPrivate: pageIsPrivate)
        if !on, page.phase == .offered, !currentPageState.readerEnabled { translation.translate(tab.id) }
    }
}

/// What the Translate row says under its title.
enum TranslateWords {
    static func subtitle(_ page: PageTranslation.Page) -> String {
        switch page.phase {
        case .offered: "This page is in \(page.sourceName)"
        case .translating: "Translating… \(Int((page.progress * 100).rounded())) %"
        case .translated: "Translated from \(page.sourceName)"
        }
    }
}
