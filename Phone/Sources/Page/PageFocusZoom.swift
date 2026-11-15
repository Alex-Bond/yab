import UIKit
import WebKit

/// WebKit zooms in on a text field under 16 px as it takes focus, and leaves
/// the page zoomed when the keyboard goes (#1437, Calendly's 14 px inputs).
/// With the keyboard gone the page comes back to the zoom it had before the
/// field took focus. A zoom the person made, before or while typing, stays.
@MainActor
final class PageFocusZoom: NSObject {
    private let page: @MainActor () -> WKWebView?
    private var observers: [NSObjectProtocol] = []
    /// The page and its zoom as the keyboard came up; nil while it is down.
    private weak var view: WKWebView?
    private var before: CGFloat?
    private var pinched = false
    private weak var watched: UIPinchGestureRecognizer?

    init(page: @escaping @MainActor () -> WKWebView?) {
        self.page = page
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardWillShow() }
            },
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardDidHide() }
            },
        ]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func keyboardWillShow() {
        // Moving between fields shows the keyboard again: the zoom to return
        // to is still the one before the first.
        guard before == nil, let view = page() else { return }
        self.view = view
        before = view.scrollView.zoomScale
        pinched = false
        if let recognizer = view.scrollView.pinchGestureRecognizer, recognizer !== watched {
            watched?.removeTarget(self, action: #selector(pinched(_:)))
            recognizer.addTarget(self, action: #selector(pinched(_:)))
            watched = recognizer
        }
    }

    private func keyboardDidHide() {
        guard let before else { return }
        self.before = nil
        // Another page in front now, or the person's own pinch: theirs.
        guard let view, !pinched, page() === view else { return }
        let scroll = view.scrollView
        guard scroll.zoomScale > before + 0.01 else { return }
        let zoom = max(scroll.minimumZoomScale, before)
        scroll.setZoomScale(zoom, animated: !Motion.disabled)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        if before != nil, recognizer.state == .began { pinched = true }
    }
}
