import SwiftUI
import UIKit

/// Stable hosts for both halves. Changing focus never reparents either web view.
struct TabletDocumentView: UIViewRepresentable {
    let tab: Tab
    let app: AppModel
    let interactive: Bool

    func makeCoordinator() -> Focus { Focus() }
    func makeUIView(context: Context) -> PageContainer {
        let host = PageContainer()
        let focus = UITapGestureRecognizer()
        focus.cancelsTouchesInView = false
        focus.delegate = context.coordinator
        host.addGestureRecognizer(focus)
        return host
    }

    func updateUIView(_ host: PageContainer, context: Context) {
        context.coordinator.focus = { [weak app] in
            guard let app, interactive, !app.privateContentBlocked, app.privateLock.isActive,
                  app.surfaces.menu == nil, !app.surfaces.coversChrome else { return }
            if app.browser.tab?.id != tab.id { app.browser.select(tab.id) }
        }
        host.accessibilityCovered = !interactive
        host.pool = app.pages
        if app.browser.tab?.id == tab.id {
            app.pages.bindPageInteractions(to: host, enabled: interactive, visibility: { [weak app] id in
                guard let app else { return false }
                return app.browser.tab?.id == id && app.privateLock.isActive && !app.privateContentBlocked
                    && !app.surfaces.coversChrome && app.surfaces.chat == nil && app.surfaces.menu == nil
                    && !app.surfaces.settings && !app.surfaces.join
            })
        } else { app.pages.releasePageInteractions(from: host) }
        host.fixturesEnabled = app.pages.fixturesEnabled
        host.chrome = PageViewport.Chrome(folded: false, hasNow: false, visible: false)
        host.show(app.browser.tab?.id == tab.id ? app.pages.activate(tab) : app.pages.view(for: tab))
        host.updateViewport()
        host.showFailure(app.chrome.pageStates[tab.id]?.failure, tab: tab.id, isPrivate: tab.isPrivate)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PageContainer, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ host: PageContainer, coordinator: Focus) {
        host.pool?.releasePageInteractions(from: host)
        host.showFailure(nil, tab: "")
        host.show(nil)
    }

    final class Focus: NSObject, UIGestureRecognizerDelegate {
        var focus: (() -> Void)?
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            focus?()
            // Observe touch-down only; the website owns the entire touch sequence.
            return false
        }
    }
}
