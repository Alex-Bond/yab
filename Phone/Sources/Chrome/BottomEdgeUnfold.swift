import UIKit

/// A lift from the safe bottom edge restores reading controls even when
/// WebKit has no scroller under that part of the finger.
@MainActor
final class BottomEdgeUnfold: NSObject, UIGestureRecognizerDelegate {
    private let app: AppModel
    weak var owner: UIView?
    private let pan = UIPanGestureRecognizer()
    private var tab: Tab.ID?
    private var space: Space.ID?

    init(app: AppModel) {
        self.app = app
        super.init()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.addTarget(self, action: #selector(moved(_:)))
    }

    func install(on window: UIWindow) {
        guard pan.view !== window else { return }
        window.addGestureRecognizer(pan)
    }

    func uninstall() {
        pan.view?.removeGestureRecognizer(pan)
        tab = nil
        space = nil
    }

    private var available: Bool {
        let surface = app.surfaces
        return app.browser.tab != nil && !app.privateContentBlocked && app.privateLock.isActive
            && !app.workspace.tabletControls && !surface.coversChrome && surface.field == nil
            && surface.chat == nil && !surface.settings && !surface.join && surface.menu == nil
            && surface.pageSwipe == nil && surface.chromeOpacity > 0.5
            && TabStack.of(app).gallery == nil && !app.emptyHomeBar
    }

    static func region(in bounds: CGRect, insets: UIEdgeInsets) -> CGRect {
        CGRect(x: bounds.minX + max(0, insets.left),
               y: bounds.maxY - max(0, insets.bottom) - Metrics.touch,
               width: max(0, bounds.width - max(0, insets.left) - max(0, insets.right)),
               height: Metrics.touch + max(0, insets.bottom))
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = pan.view as? UIWindow, let touched = touch.view else { return false }
        return receive(at: touch.location(in: window), touched: touched, in: window)
    }

    func receive(at point: CGPoint, touched: UIView, in window: UIWindow) -> Bool {
        tab = nil
        space = nil
        guard available, app.chrome.folded, pan.view === window,
              let owner, owner.window === window,
              BackGestures.onPage(touched) || touched.isDescendant(of: owner) else { return false }
        var insets = window.safeAreaInsets
        insets.left += ChromeGeometry.extraSides.left
        insets.right += ChromeGeometry.extraSides.right
        let pane = app.workspace.paneFrame.isEmpty ? window.bounds : app.workspace.paneFrame
        let region = Self.region(in: window.bounds, insets: insets).intersection(pane)
        guard region.contains(point) else { return false }
        tab = app.browser.tab?.id
        space = app.browser.spaceID
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        begin(velocity: pan.velocity(in: pan.view))
    }

    func begin(velocity: CGPoint) -> Bool {
        return available && tab == app.browser.tab?.id && space == app.browser.spaceID
            && velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // The edge lift owns an upward finger before WebKit starts scrolling
        // down and folds the plate again during deceleration. Other page
        // gestures proceed as usual when this direction or region rejects it.
        guard let view = other.view else { return false }
        // The folded plate also has its own lift to Spaces. At the safe
        // bottom edge it must wait for restoration, just like page scrolling.
        if let owner, view.isDescendant(of: owner) { return true }
        return view is UIScrollView && BackGestures.onPage(view)
    }

    @objc private func moved(_ recognizer: UIPanGestureRecognizer) {
        follow(recognizer.state)
    }

    func follow(_ state: UIGestureRecognizer.State) {
        guard available, tab == app.browser.tab?.id, space == app.browser.spaceID else { return }
        if state == .began || state == .ended {
            app.chrome.fold(false)
        }
    }
}
