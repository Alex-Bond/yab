import CoreGraphics
import Foundation
import Observation

/// The page's chrome: folded into the capsule while the page is read
/// scrolling down, back on a scroll up, and what each page said about itself.
@MainActor
@Observable
final class ChromeState {
    /// Folded: the plate a small capsule at the bottom, the Now line one word
    /// beside it, the round buttons gone.
    private(set) var folded = false
    /// Pages that said they are dark, by tab.
    var pageDark: [Tab.ID: Bool] = [:]
    /// Native loading, history and Reader capability for each actual page.
    var pageStates: [Tab.ID: WebPool.PageState] = [:]

    @ObservationIgnored private var lastScroll: CGFloat = 0

    /// A scroll of the page in front, the prototype's rule: past 50 points and
    /// going down folds, going up or near the top unfolds; a step under 3
    /// points is a tremble, not a direction.
    func scrolled(to y: CGFloat) {
        let rule = Metrics.Chrome.self
        // WebKit can report a long swipe in sub-point samples. Keep the
        // direction anchor until those samples have moved past the tremble.
        guard abs(y - lastScroll) > rule.foldStep || y < rule.unfoldBefore else { return }
        let target: Bool?
        if y > rule.foldAfter && y - lastScroll > rule.foldStep {
            target = true
        } else if lastScroll - y > rule.foldStep || y < rule.unfoldBefore {
            target = false
        } else {
            target = nil
        }
        lastScroll = y
        guard let target, target != folded else { return }
        // A fold moves the page's insets, and that can move the page, which
        // would fold again. A person folds a few times a second at most; a
        // scroll that flips the chrome faster is the layout answering itself
        // (watchdog kills 0x8BADF00D, a million passes in 30 s). Stop
        // listening to scrolls for a moment and the loop has nothing to feed on.
        let time = now()
        if time < frozenUntil { return }
        flips = flips.filter { time - $0 < Self.flipWindow } + [time]
        if flips.count > Self.flipLimit {
            flips = []
            frozenUntil = time + Self.freeze
            return
        }
        fold(target)
    }

    /// Scroll-driven folds allowed in `flipWindow` seconds before the chrome
    /// holds still for `freeze` seconds.
    static let flipLimit = 6
    static let flipWindow: TimeInterval = 1
    static let freeze: TimeInterval = 2
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var flips: [TimeInterval] = []
    @ObservationIgnored private var frozenUntil: TimeInterval = 0

    /// Move the direction anchor with a native layout correction. A zero
    /// correction leaves an inner DOM scroller's independent position alone.
    func rebaseScroll(by delta: CGFloat) { lastScroll += delta }

    /// Take a position as the new direction anchor without deciding a fold.
    func settleScroll(to y: CGFloat) { lastScroll = y }

    func fold(_ on: Bool) {
        guard folded != on else { return }
        // The toolbar folds with its own .animation(chromeFold, value: folded)
        // (SharedBottomToolbar), so the signpost is timed to the fold.
        Motion.chromeFold.run(timed: true) { folded = on }
    }

    func unfold() {
        lastScroll = 0
        fold(false)
    }

    /// For named states: straight to folded or not, no movement.
    func setFolded(_ on: Bool) { folded = on }
}
