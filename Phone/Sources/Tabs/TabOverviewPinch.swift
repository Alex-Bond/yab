import SwiftUI
import WebKit

/// A pinch below the page's minimum zoom opens All Tabs. Website zoom keeps
/// its native recognizer; a pinch begun on a zoomed page belongs to it alone.
@MainActor
final class TabOverviewPinch: NSObject, UIGestureRecognizerDelegate {
    /// Off until its pinch is proven on a phone: the simulator's UI proof never opened All Tabs.
    static let enabled = false

    private weak var stack: TabStack?
    private weak var page: WKWebView?
    private weak var heldZoom: UIGestureRecognizer?
    private var zoomWasEnabled = false
    private let pinch = UIPinchGestureRecognizer()

    init(stack: TabStack) {
        self.stack = stack
        super.init()
        pinch.addTarget(self, action: #selector(changed(_:)))
        pinch.delegate = self
        pinch.cancelsTouchesInView = false
    }

    func install(on window: UIWindow) {
        guard pinch.view !== window else { return }
        pinch.view?.removeGestureRecognizer(pinch)
        window.addGestureRecognizer(pinch)
    }

    func uninstall() {
        stack?.endPinch(velocity: 0, cancelled: true)
        restoreZoom()
        pinch.view?.removeGestureRecognizer(pinch)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let stack, stack.canPinchGallery, let touched = touch.view,
              BackGestures.onPage(touched),
              let web = sequence(first: touched, next: \.superview).first(where: { $0 is WKWebView }) as? WKWebView
        else { return false }
        page = web
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let stack, let page else { return false }
        return Self.mayBegin(inward: pinch.scale < 1 || pinch.velocity < 0, zoom: page.scrollView.zoomScale,
                             minimum: page.scrollView.minimumZoomScale, available: stack.canPinchGallery)
    }

    static func mayBegin(inward: Bool, zoom: CGFloat, minimum: CGFloat, available: Bool) -> Bool {
        inward && available && zoom <= minimum + 0.01
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === page?.scrollView.pinchGestureRecognizer
    }

    @objc private func changed(_ recognizer: UIPinchGestureRecognizer) {
        guard let stack else { return }
        let progress = (1 - recognizer.scale) / Metrics.TabGallery.pinchTravel
        let velocity = -recognizer.velocity / Metrics.TabGallery.pinchTravel
        switch recognizer.state {
        case .began:
            // At minimum zoom the page's rubber band would otherwise be
            // captured into the shrinking card. Only this pinch owns it.
            heldZoom = page?.scrollView.pinchGestureRecognizer
            zoomWasEnabled = heldZoom?.isEnabled ?? false
            heldZoom?.isEnabled = false
            stack.beginPinch()
            stack.updatePinch(progress)
        case .changed: stack.updatePinch(progress)
        case .ended:
            restoreZoom()
            stack.endPinch(velocity: velocity, cancelled: false)
        case .cancelled, .failed:
            restoreZoom()
            stack.endPinch(velocity: 0, cancelled: true)
        default: break
        }
    }

    private func restoreZoom() {
        heldZoom?.isEnabled = zoomWasEnabled
        heldZoom = nil
    }
}

struct TabOverviewPinchHost: UIViewRepresentable {
    let stack: TabStack

    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) { view.gestures = stack.pinchGesture }
    static func dismantleUIView(_ view: Host, coordinator: ()) { view.gestures?.uninstall() }

    final class Host: UIView {
        var gestures: TabOverviewPinch? {
            didSet {
                if oldValue !== gestures {
                    oldValue?.uninstall()
                    attach()
                }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        private func attach() {
            if let window { gestures?.install(on: window) }
            else { gestures?.uninstall() }
        }
    }
}
