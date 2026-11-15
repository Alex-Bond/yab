import UIKit
import XCTest
@testable import YabPhone

@MainActor
final class NavigationSwipeCompletionTests: XCTestCase {
    func testRealWebKitTransitionsHaveTheDistanceCompletionRule() throws {
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let view = app.pages.activate(try XCTUnwrap(app.browser.tab))
        let delegates = (view.gestureRecognizers ?? []).compactMap { recognizer -> NSObject? in
            guard recognizer is UIScreenEdgePanGestureRecognizer,
                  recognizer.name?.hasPrefix("yab.swipeAnywhere") != true,
                  let delegate = recognizer.delegate as? NSObject,
                  delegate.responds(to: NSSelectorFromString("contentSwipeGestureRecognizer")) else { return nil }
            return delegate
        }
        XCTAssertEqual(delegates.count, 2)
        for delegate in delegates {
            XCTAssertTrue(String(cString: object_getClassName(delegate)).hasPrefix("YabDistanceCompletion_"),
                          "the actual WebKit transition must receive the rule: \(delegate)")
        }
    }
    private final class Pan: UIPanGestureRecognizer {
        var phase: UIGestureRecognizer.State = .ended
        var distance: CGFloat = 0
        override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: distance, y: 0) }
    }
    private class Transition: UIPercentDrivenInteractiveTransition {
        var progress: CGFloat = 0
        var finishes = 0
        var cancellations = 0
        override var percentComplete: CGFloat { progress }
        override func finish() { finishes += 1 }
        override func cancel() { cancellations += 1 }
    }

    func testSlowEndedSwipePastHalfFinishesAndInterruptionsStillCancel() {
        for phase in [UIGestureRecognizer.State.ended, .cancelled, .failed, .changed] {
            for progress in [CGFloat(0.49), 0.5, 0.51, 0.75] {
                let transition = Transition()
                let pan = Pan()
                let view = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
                view.addGestureRecognizer(pan)
                pan.phase = phase
                pan.distance = progress * 402
                transition.progress = 0
                NavigationSwipeCompletion.install(on: transition, pan: pan)
                transition.cancel()
                let commit = phase == .ended && progress > 0.5
                XCTAssertEqual(transition.finishes, commit ? 1 : 0)
                XCTAssertEqual(transition.cancellations, commit ? 0 : 1)
            }
        }
    }

    func testNativeFinishAndUnrelatedTransitionsAreUnchanged() {
        let unrelated = Transition()
        unrelated.progress = 0.9
        unrelated.cancel()
        XCTAssertEqual(unrelated.cancellations, 1)
        let transition = Transition(), edge = Pan(), content = Pan()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.addGestureRecognizer(edge); view.addGestureRecognizer(content)
        edge.phase = .failed
        content.phase = .ended
        transition.progress = 0.7
        content.distance = -0.7 * 402
        NavigationSwipeCompletion.install(on: transition, pan: edge)
        NavigationSwipeCompletion.install(on: transition, pan: content, direction: -1)
        NavigationSwipeCompletion.install(on: transition, pan: content, direction: -1)
        transition.cancel()
        transition.finish()
        XCTAssertEqual(transition.finishes, 2)
        XCTAssertEqual(transition.cancellations, 0)
    }
}
