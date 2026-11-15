import ObjectiveC
import UIKit
import WebKit

/// What a swipe anywhere on the page asks of the app: whether nothing else
/// holds the screen, and the pull back to the opener at a tab's first page.
@MainActor
protocol SwipeAnywhereHost: AnyObject {
    /// Settings › General › Swipe from Anywhere is on and nothing covers the page.
    var maySwipeAnywhere: Bool { get }
    /// The page in front has no Back of its own but a tab that opened it.
    var maySwipeToOpener: Bool { get }
    func pullBegan()
    func pulled(by dx: CGFloat)
    func pullEnded(velocity: CGFloat)
    func cancelPull(animated: Bool, velocity: CGFloat)
}

/// Back and forward from anywhere on the page: a sideways
/// swipe across the page plays WebKit's own swipe (its pictures of the pages,
/// their parallax and shadow, its let-go), not only from the screen's edges.
///
/// iOS 26 gave navigation transitions a second recognizer that starts
/// anywhere, not only at an edge (UIKit's content back swipe, the one behind
/// UINavigationController's interactiveContentPopGestureRecognizer). WebKit
/// makes it for its back and forward swipes too and turns it off; this turns
/// it on, so the hysteresis, tracking and let-go are UIKit's and WebKit's own.
/// At a tab's first page, where WebKit has nothing behind, a swipe right pulls
/// it back to its opener, as the edge does (BackStack).
///
/// A swipe that belongs to the page stays the page's: a scroller that can
/// still move that way (a carousel, a code block, a zoomed page), a part of
/// the page that keeps sideways moves for itself (touch-action without
/// pan-x, a slider; PageSignals tells), and a page that takes the touch
/// (WebKit holds recognizers on the web view until its touch handlers say).
@MainActor
final class SwipeAnywhere: NSObject, UIGestureRecognizerDelegate {
    enum Route: Equatable { case back, forward }

    private weak var view: WKWebView?
    private weak var host: SwipeAnywhereHost?
    /// UIKit's content swipes of WebKit's back and forward transitions, each
    /// asking this before its transition does.
    private(set) var swipes: [Route: UIPanGestureRecognizer] = [:]
    private var edges: [Route: UIPanGestureRecognizer] = [:]
    private var vetoes: [Route: Veto] = [:]
    /// Ours, for the first page's pull to the opener only.
    private let opener = UIPanGestureRecognizer()
    private var pulling = false
    /// The page said the finger came down on a part that keeps sideways
    /// moves; reset as each touch comes down.
    var held = false

    private static var key: UInt8 = 0

    /// The swipe of `view`, made once and kept on the view.
    @discardableResult
    static func attach(to view: WKWebView, host: SwipeAnywhereHost?) -> SwipeAnywhere {
        if let made = objc_getAssociatedObject(view, &key) as? SwipeAnywhere {
            made.host = host
            made.adopt()
            return made
        }
        let made = SwipeAnywhere(view: view, host: host)
        objc_setAssociatedObject(view, &key, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    static func of(_ view: WKWebView) -> SwipeAnywhere? { objc_getAssociatedObject(view, &key) as? SwipeAnywhere }

    private init(view: WKWebView, host: SwipeAnywhereHost?) {
        self.view = view
        self.host = host
        super.init()
        opener.maximumNumberOfTouches = 1
        opener.allowedScrollTypesMask = .continuous
        opener.delegate = self
        opener.name = "yab.swipeAnywhere.opener"
        opener.addTarget(self, action: #selector(pulled(_:)))
        view.addGestureRecognizer(opener)
        adopt()
    }

    // MARK: - UIKit's content swipe

    /// Finds WebKit's two transitions by their edge recognizers (made once
    /// allowsBackForwardNavigationGestures is on) and turns on the content
    /// swipe each one holds, under a delegate that asks the page first.
    private func adopt() {
        guard let view, swipes.isEmpty else { return }
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        for case let edge as UIScreenEdgePanGestureRecognizer in view.gestureRecognizers ?? [] {
            let route: Route = edge.edges.contains(.left) != rtl ? .back : .forward
            let direction: CGFloat = edge.edges.contains(.left) ? 1 : -1
            if let transition = edge.delegate as? UIPercentDrivenInteractiveTransition {
                NavigationSwipeCompletion.install(on: transition, pan: edge, direction: direction)
                edge.addTarget(self, action: #selector(swiped(_:)))
                edges[route] = edge
            }
            // The content swipes are edge recognizers too; once adopted, their delegate is a Veto.
            guard let transition = edge.delegate as? NSObject, !(transition is Veto), let content = Self.contentSwipe(of: transition, edge: edge, in: view) else { continue }
            guard swipes[route] == nil else { continue }
            let veto = Veto(owner: self, route: route, transition: transition)
            vetoes[route] = veto
            content.delegate = veto
            content.name = route == .back ? "yab.swipeAnywhere.back" : "yab.swipeAnywhere.forward"
            content.isEnabled = true
            // One finger: a pinch whose fingers drift sideways is a zoom,
            // never a page sliding back over the one before it.
            content.maximumNumberOfTouches = 1
            content.allowedScrollTypesMask = .continuous
            if let transition = transition as? UIPercentDrivenInteractiveTransition {
                NavigationSwipeCompletion.install(on: transition, pan: content, direction: direction)
            }
            content.addTarget(self, action: #selector(swiped(_:)))
            swipes[route] = content
        }
    }

    /// The transition's content swipe: WebKit's, switched off, where UIKit
    /// made one; else made here as UIKit makes it.
    private static func contentSwipe(of transition: NSObject, edge: UIScreenEdgePanGestureRecognizer, in view: UIView) -> UIPanGestureRecognizer? {
        let get = NSSelectorFromString("contentSwipeGestureRecognizer")
        guard transition.responds(to: get) else { return nil }
        if let made = transition.value(forKey: "contentSwipeGestureRecognizer") as? UIPanGestureRecognizer { return made }
        let create = NSSelectorFromString("_createContentSwipeGestureRecognizer")
        guard transition.responds(to: create),
              let made = transition.perform(create)?.takeUnretainedValue() as? UIScreenEdgePanGestureRecognizer else { return nil }
        made.edges = edge.edges
        view.addGestureRecognizer(made)
        made.require(toFail: edge)
        transition.setValue(made, forKey: "contentSwipeGestureRecognizer")
        return made
    }

    // MARK: - deciding

    /// The content swipe of `route` may start here: the app lets it, the page
    /// didn't keep the touch, and no scroller under the finger can still move.
    fileprivate func allows(_ route: Route, _ pan: UIPanGestureRecognizer) -> Bool {
        guard let view, let host, host.maySwipeAnywhere, !held, pan.numberOfTouches <= 1 else { return false }
        return !scrolls(at: pan.location(in: view), right: route == .back)
    }

    fileprivate func touchCameDown() { held = false }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        held = false
        guard let view, let host, host.maySwipeAnywhere else { return false }
        let x = touch.location(in: view).x
        // The edges stay WebKit's own swipe and BackGestures'.
        return x > Metrics.Back.edge && x < view.bounds.width - Metrics.Back.edge
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view, let host, let pan = recognizer as? UIPanGestureRecognizer, !held,
              !view.canGoBack, host.maySwipeToOpener else { return false }
        let v = pan.velocity(in: view)
        // Sideways enough: a scroll a little off the vertical stays a scroll.
        guard v.x > 0, abs(v.x) > abs(v.y) * Metrics.Back.anywhereSlope else { return false }
        return !scrolls(at: pan.location(in: view), right: true)
    }

    /// A scroller under the finger, the page's own included, that can still
    /// move the way the finger goes: the swipe is its.
    private func scrolls(at point: CGPoint, right: Bool) -> Bool {
        guard let view, var hit = view.hitTest(point, with: nil) else { return false }
        while true {
            if let scroller = hit as? UIScrollView, Self.canScroll(scroller, right: right) { return true }
            guard hit !== view, let up = hit.superview else { return false }
            hit = up
        }
    }

    /// The finger going right shows what is left of the scroller, if any.
    static func canScroll(_ scroller: UIScrollView, right: Bool) -> Bool {
        guard scroller.isScrollEnabled else { return false }
        let inset = scroller.adjustedContentInset
        let least = -inset.left, most = scroller.contentSize.width + inset.right - scroller.bounds.width
        guard most > least + 1 else { return false }
        return right ? scroller.contentOffset.x > least + 0.5 : scroller.contentOffset.x < most - 0.5
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // The page's scrollers wait for the pull to decide, as they do under
        // WebKit's own edge swipe; it decides at the first move.
        guard let view, let scroller = other.view as? UIScrollView, other === scroller.panGestureRecognizer else { return false }
        return scroller.isDescendant(of: view)
    }

    /// UI tests: a content swipe's start and let-go, one line each, to the
    /// file YAB_SWIPES_JOURNAL names (a simulated finger can't finish
    /// WebKit's swipe, so the test reads that it began). Nothing otherwise.
    private static let journal = ProcessInfo.processInfo.environment["YAB_SWIPES_JOURNAL"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        guard let journal = Self.journal,
              let route = (swipes.first(where: { $0.value === pan }) ?? edges.first(where: { $0.value === pan }))?.key else { return }
        let state: String
        switch pan.state {
        case .began: state = "began"
        case .ended: state = "ended"
        case .cancelled, .failed: state = "cancelled"
        default: return
        }
        let line = Data("\(state) \(route) at \(Int(pan.location(in: pan.view).x))\n".utf8)
        if let handle = try? FileHandle(forWritingTo: journal) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: journal)
        }
    }

    // MARK: - the pull to the opener

    @objc private func pulled(_ pan: UIPanGestureRecognizer) {
        guard let host else { return }
        let t = pan.translation(in: pan.view), v = pan.velocity(in: pan.view)
        switch pan.state {
        case .began: pulling = true; host.pullBegan(); host.pulled(by: t.x)
        case .changed:
            // The page said, a moment late, that this touch is its own.
            if held { pan.isEnabled = false; pan.isEnabled = true } else { host.pulled(by: t.x) }
        case .ended: pulling = false; host.pullEnded(velocity: v.x)
        case .cancelled, .failed: if pulling { pulling = false; host.cancelPull(animated: true, velocity: 0) }
        default: break
        }
    }

    /// Tests: UIKit's content swipe is on for both ways, under this delegate.
    var drivesWebKit: Bool {
        adopt()
        return [Route.back, .forward].allSatisfy { swipes[$0]?.isEnabled == true && swipes[$0]?.delegate === vetoes[$0] }
    }
}

/// The content swipe's delegate: this page's say first, then the transition's
/// (UIKit's, which asks WebKit whether there is a page that way). Everything
/// else the transition answers, private requirements included.
@MainActor
private final class Veto: NSObject, UIGestureRecognizerDelegate {
    weak var owner: SwipeAnywhere?
    let route: SwipeAnywhere.Route
    weak var transition: NSObject?

    init(owner: SwipeAnywhere, route: SwipeAnywhere.Route, transition: NSObject) {
        self.owner = owner
        self.route = route
        self.transition = transition
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let owner else { return false }
        owner.touchCameDown()
        return (transition as? UIGestureRecognizerDelegate)?.gestureRecognizer?(recognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let owner, let pan = recognizer as? UIPanGestureRecognizer, owner.allows(route, pan) else { return false }
        return (transition as? UIGestureRecognizerDelegate)?.gestureRecognizerShouldBegin?(recognizer) ?? false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || transition?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        transition?.responds(to: selector) == true ? transition : nil
    }
}
