import UIKit

/// The screen's left edge at a tab's first page, where WebKit's own back
/// swipe can't start: a finger there pulls the page aside (BackStack), back
/// to the tab that opened it, or against a rubber band with nothing behind.
/// While the page has a Back this one takes no touch and WebKit's swipe has
/// the edge. On the window, as the plate's (Paging/PlateGestures), for
/// touches on the page above the plate only.
@MainActor
final class BackGestures: NSObject, UIGestureRecognizerDelegate {
    private weak var stack: BackStack?
    private let edge = UIPanGestureRecognizer()

    init(stack: BackStack) {
        self.stack = stack
        super.init()
        edge.maximumNumberOfTouches = 1
        edge.allowedScrollTypesMask = .continuous
        edge.addTarget(self, action: #selector(panned(_:)))
        edge.delegate = self
    }

    func install(on window: UIWindow) {
        guard edge.view !== window else { return }
        edge.view?.removeGestureRecognizer(edge)
        window.addGestureRecognizer(edge)
    }

    func uninstall(from window: UIWindow) {
        guard edge.view === window else { return }
        stack?.cancelPull(animated: false)
        window.removeGestureRecognizer(edge)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let stack, let window = edge.view as? UIWindow, let touched = touch.view, Self.onPage(touched) else { return false }
        let frame = stack.app?.workspace.paneFrame ?? .zero
        let pane = frame.isEmpty ? window.bounds : frame
        let point = touch.location(in: window)
        guard pane.contains(point) else { return false }
        return stack.mayPull(at: CGPoint(x: point.x - pane.minX, y: point.y - pane.minY), in: pane.size)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        let velocity = edge.velocity(in: edge.view)
        return stack?.mayPull == true && velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // The page's own scrolling waits for the edge to decide, as it does
        // under a navigation controller's back swipe.
        guard let view = other.view, view is UIScrollView else { return false }
        return Self.onPage(view)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let stack else { return }
        let t = recognizer.translation(in: recognizer.view), v = recognizer.velocity(in: recognizer.view)
        switch recognizer.state {
        case .began:
            stack.pullBegan()
            stack.pulled(by: t.x)
        case .changed: stack.pulled(by: t.x)
        case .ended: stack.pullEnded(velocity: v.x)
        case .cancelled, .failed: stack.cancelPull()
        default: break
        }
    }

    /// The touch is on the page in front (its web view or its failure), not
    /// on the chrome, a sheet or a toast over it.
    static func onPage(_ view: UIView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0 is PageContainer }
    }
}

extension BackStack {
    /// A touch at `point` may start the pull: at the left edge, on the
    /// page's part of the screen, above the plate and the Now line, whose
    /// swipes are theirs. Any other touch never meets the recognizer.
    func mayPull(at point: CGPoint, in size: CGSize) -> Bool {
        guard point.x <= Metrics.Back.edge, mayPull, let app else { return false }
        if app.workspace.tabletControls { return point.y < size.height }
        let chrome = ChromeGeometry(size: size, folded: app.chrome.folded, hasNow: app.nowItem != nil)
        let floor = app.nowItem != nil ? min(chrome.plateTouch.minY, chrome.now.minY) : chrome.plateTouch.minY
        return point.y < floor
    }
}
