import Foundation

extension Browser {
    /// These side effects already belong to the WebKit navigation path.
    /// Chromium shares the page-script state without touching WK history.
    func chromiumScriptsCommitted(_ tab: Tab) {
        tab.chromiumScriptsCommitted()
        ChatBusy.left(tab)
        walletPageLeft(tab)
        pageTranslation.navigationCommitted(tab)
    }

    func chromiumScriptsFinished(_ tab: Tab) {
        tab.settleSignIn()
        Favicons.shared.fetch(for: tab)
        warmDrafts(tab)
    }
}
