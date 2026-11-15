import SwiftUI
import UIKit

/// UIKit follows the finger from every drawn bottom control. Horizontal
/// movement pages tabs; an upward movement from the plate lifts the spaces
/// (FieldModel.beginLift), and from the tab stack flicks to the previous tab
/// (Tabs/TabStack).
/// A recognized pan cancels the original button touch, while an ordinary tap
/// or native Plus hold keeps its own UIKit recognizer.
@MainActor
final class PlateGestures: NSObject, UIGestureRecognizerDelegate {
    let app: AppModel
    /// The bottom toolbar's native host: only touches inside it are followed.
    weak var owner: UIView?
    private let pan = UIPanGestureRecognizer()
    private enum Direction { case horizontal, vertical, flick, suppressed }
    private var direction: Direction?
    private weak var touchOwner: UIView?
    private var touchSpaceID: Space.ID?
    private var touchTabID: Tab.ID?
    private var beganOnPlate = false
    private var beganOnStack = false

    /// Installed: the plate's SwiftUI drags (paging, the lift) stand aside.
    private static let installedRecognizers = NSHashTable<UIGestureRecognizer>.weakObjects()
    static var installed: Bool { installedRecognizers.allObjects.contains { $0.view != nil } }

    init(app: AppModel) {
        self.app = app
        super.init()
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.maximumNumberOfTouches = 1
    }

    func install(on window: UIWindow) {
        guard pan.view !== window else { return }
        window.addGestureRecognizer(pan)
        Self.installedRecognizers.add(pan)
    }

    func uninstall() {
        if direction == .horizontal { Pager.of(app).cancel(animated: false) }
        if direction == .flick { TabStack.of(app).cancelFlick(animated: false) }
        Self.installedRecognizers.remove(pan)
        pan.view?.removeGestureRecognizer(pan)
        retireTouch()
    }

    private var sourceAvailable: Bool {
        let s = app.surfaces
        return !app.privateContentBlocked && s.field == nil && s.chat == nil
            && !s.settings && s.menu == nil && (!app.chrome.folded || app.workspace.verticalControls) && s.chromeOpacity > 0.5
            && s.pageSwipe?.blank != true
    }

    private var currentTouch: Bool {
        guard let window = pan.view as? UIWindow, let owner = touchOwner,
              owner === self.owner, owner.window === window,
              window.windowScene?.activationState == .foregroundActive,
              UIApplication.shared.applicationState == .active else { return false }
        return sourceAvailable && app.browser.spaceID == touchSpaceID && app.browser.tab?.id == touchTabID
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = pan.view as? UIWindow, let touched = touch.view else { return false }
        return receive(at: touch.location(in: window), touched: touched, in: window)
    }

    /// The delegate and native tests use the same actual window/owner gate.
    /// The transparent root still passes gaps and unrelated page touches through.
    func receive(at point: CGPoint, touched: UIView, in window: UIWindow) -> Bool {
        guard pan.view === window, let owner,
              touched.isDescendant(of: owner), owner.window === window, sourceAvailable,
              window.windowScene?.activationState == .foregroundActive,
              UIApplication.shared.applicationState == .active else { return false }
        let point = owner.convert(point, from: window)
        let geometry = ChromeGeometry(size: owner.bounds.size, folded: false, hasNow: app.nowItem != nil, verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail)
        if app.chrome.folded, !geometry.back.union(geometry.space).contains(point) { return false }
        guard geometry.back.union(geometry.plateTouch).union(geometry.space).contains(point) else { return false }
        touchOwner = owner
        touchSpaceID = app.browser.spaceID
        touchTabID = app.browser.tab?.id
        beganOnPlate = geometry.plateTouch.contains(point)
        beganOnStack = !beganOnPlate && geometry.space.contains(point) && TabStack.of(app).canFlick
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        begin(translation: pan.translation(in: pan.view), velocity: pan.velocity(in: pan.view))
    }

    /// The native delegate supplies actual UIKit observations. State-machine
    /// tests supply numbers explicitly; they do not synthesize native fingers.
    func begin(translation t: CGPoint, velocity v: CGPoint) -> Bool {
        guard currentTouch else { retireTouch(); return false }
        let horizontal = t == .zero ? abs(v.x) > abs(v.y) : abs(t.x) > abs(t.y)
        let up = t.y < 0 || (t.y == 0 && v.y < 0)
        if horizontal {
            direction = .horizontal
        } else if beganOnPlate && up {
            direction = .vertical
        } else if beganOnStack && up && TabStack.of(app).canFlick {
            direction = .flick
        } else {
            // A vertical side-button pan consumes its touch without tapping,
            // paging or lifting the spaces.
            direction = .suppressed
        }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The plate's pan runs beside its own tap and hold. At a native side
        // button, the pan and its tap/hold must have a single UIKit winner.
        beganOnPlate
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        follow(g.state, translation: g.translation(in: g.view), velocity: g.velocity(in: g.view))
    }

    /// Native state-machine qualification is separate from real finger UI tests.
    func follow(_ state: UIGestureRecognizer.State, translation t: CGPoint, velocity v: CGPoint) {
        let pager = Pager.of(app)
        let stack = TabStack.of(app)
        if direction == .horizontal && !currentTouch {
            pager.cancel(animated: false)
            retireTouch()
            return
        }
        if direction == .flick && !currentTouch {
            stack.cancelFlick(animated: false)
            retireTouch()
            return
        }
        switch (state, direction) {
        case (.began, .horizontal?):
            pager.start()
            pager.follow(by: t.x)
        case (.changed, .horizontal?):
            pager.follow(by: t.x)
        case (.ended, .horizontal?):
            pager.finish(t.x, velocity: v.x)
            retireTouch()
        case (.cancelled, .horizontal?), (.failed, .horizontal?):
            pager.cancel()
            retireTouch()
        case (.began, .vertical?):
            // The field follows only a lift it began (FieldModel.lifting).
            app.field.beginLift()
            app.field.liftMoved(t.y)
        case (.changed, .vertical?):
            app.field.liftMoved(t.y)
        case (.ended, .vertical?), (.cancelled, .vertical?), (.failed, .vertical?):
            app.field.liftEnded(t.y, velocity: state == .ended ? v.y : 0)
            retireTouch()
        case (.began, .flick?):
            if stack.flickBegan() { stack.flickMoved(-t.y) }
        case (.changed, .flick?):
            stack.flickMoved(-t.y)
        case (.ended, .flick?):
            stack.flickEnded(-t.y, velocity: -v.y)
            retireTouch()
        case (.cancelled, .flick?), (.failed, .flick?):
            stack.cancelFlick()
            retireTouch()
        case (.ended, _), (.cancelled, _), (.failed, _):
            retireTouch()
        default:
            break
        }
    }

    private func retireTouch() {
        direction = nil
        touchOwner = nil
        touchSpaceID = nil
        touchTabID = nil
        beganOnPlate = false
        beganOnStack = false
    }
}
