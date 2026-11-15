import SwiftUI
import UIKit

/// A page's edge Back leaves native sliders, switches and text editing alone.
/// In particular, a slider's minimum thumb can sit inside the 24-point edge.
struct SettingsBackGesture: UIGestureRecognizerRepresentable {
    let route: SettingsRoute

    func makeUIGestureRecognizer(context: Context) -> SettingsBackPan {
        let pan = SettingsBackPan()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        return pan
    }

    /// The page follows the finger to the right, as iOS's navigation does,
    /// the one under it coming back; let go, it goes or springs back.
    func handleUIGestureRecognizerAction(_ pan: SettingsBackPan, context: Context) {
        let ui = SettingsUI.shared
        let valid = context.coordinator.route == route
            && context.coordinator.path == ui.navigation
            && ui.navigation.last == context.coordinator.route
        switch pan.state {
        case .began, .changed:
            guard valid else { return }
            ui.backDrag = max(0, pan.translation(in: pan.view).x)
        case .ended:
            defer { context.coordinator.reset() }
            guard valid else { ui.backDrag = 0; return }
            ui.letGoBack(width: pan.view?.bounds.width ?? Metrics.screen.width, velocity: pan.velocity(in: pan.view).x)
        case .cancelled, .failed:
            context.coordinator.reset()
            if ui.backDrag != 0 { TaskMotion.run(.settingsBack) { ui.backDrag = 0 } }
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(route: route) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let route: SettingsRoute
        private(set) var start: CGPoint?
        private(set) var path: [SettingsRoute]?

        init(route: SettingsRoute) { self.route = route }

        /// Inspect the actual hit view and its parents, rather than its AX label.
        func acceptsOrigin(_ view: UIView?) -> Bool {
            var node = view
            while let current = node {
                if current is UIControl || current is UITextView { return false }
                node = current.superview
            }
            return true
        }

        func reset() { start = nil; path = nil }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            reset()
            guard SettingsUI.shared.navigation.last == route, !SettingsUI.shared.standsAsRoot,
                  acceptsOrigin(touch.view) else { return false }
            let point = touch.location(in: recognizer.view)
            guard point.x < Metrics.Settings.backEdge else { return false }
            start = point
            path = SettingsUI.shared.navigation
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard start != nil, path == SettingsUI.shared.navigation,
                  SettingsUI.shared.navigation.last == route,
                  let pan = recognizer as? UIPanGestureRecognizer else { reset(); return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}

final class SettingsBackPan: UIPanGestureRecognizer {}
