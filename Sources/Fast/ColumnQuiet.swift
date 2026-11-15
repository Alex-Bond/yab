import AppKit
import QuartzCore
import ObjectiveC

// What the column's scroll tells the rows' hosts, and how their asks for
// SwiftUI's update are answered (docs/evidence/night-smoothness-2026-10-14.md,
// "Day 2026-10-14" and "Round 2").
//
// Each frame of the rows' scroll AppKit tells every view under the clip view
// that it moved in the window (NSViewHierarchyNoteGeometryInWindowDidChange).
// NSHostingView hears it (rootTransform) and asks its update through the
// constraints pass; AppKit carries that ask up every view over the cell to
// the column's SwiftUI host and the window's, which lay themselves out for
// it: the window's whole graph again, on every frame (40% of the main
// thread under the column's scroll at 200 tabs).

@MainActor
enum ColumnQuiet {
    private static let env = ProcessInfo.processInfo.environment

    /// While two fingers or their glide scroll the rows, the rows' hosts
    /// hear the moves once, at the gesture's end (or the pointer's next
    /// move or press); a wheel's step is heard at once. Column scroll at
    /// 200 tabs -37% instructions, -6% main thread, the swipes, the page
    /// and rest unchanged (job 71d982b0, 4 rounds); the row lit right after
    /// a scroll as with every move heard (hover_after_scroll.py, same job:
    /// 16 of 19 checks against 15, all from 0.1 s on and the click right).
    /// The first way, told 0.12 s after the rows rested, left the row lit
    /// behind the pointer (job b9158315). YAB_SMOOTH_MOVED=0: every move
    /// heard, as before.
    static let quietMoves = env["YAB_SMOOTH_MOVED"] != "0"

    /// YAB_SMOOTH_ASKS=1: a row's ask stops at the column's page and the
    /// row answers it in its own layout. Off: it climbs to the window as
    /// AppKit has it. Fewer instructions but more main-thread time under the
    /// column's scroll at 200 tabs (1604 -> 1249 M, 391 -> 474 ms, job
    /// 33c58ab6), the swipes -30% instructions and -16% main thread: off
    /// until a way keeps the swipes' gain without the scroll's cost.
    /// YAB_SMOOTH_ASKS=swipe: kept, but while the rows scroll they climb.
    /// The swipes -24% instructions and -9% main thread, their rows -64% and
    /// -14%, but the column's scroll at 200 tabs +3% main thread (461 -> 477
    /// ms, job 71d982b0): off, as the column's scroll may not get slower.
    static var keepsAsks = env["YAB_SMOOTH_ASKS"] == "1" || env["YAB_SMOOTH_ASKS"] == "swipe"
    static var climbsWhileScrolling = env["YAB_SMOOTH_ASKS"] == "swipe"

    /// When the rows of a page last scrolled.
    static var rowsScrolled: CFTimeInterval = 0
    /// The rows scrolled within the last quarter second.
    static var rowsScrolling: Bool { CACurrentMediaTime() - rowsScrolled < 0.25 }

    /// YAB_SMOOTH_HAND=0: the hand's drawing of the rows on every frame of
    /// a scroll, held or not.
    static let stillHand = env["YAB_SMOOTH_HAND"] != "0"

    // MARK: - moves heard later

    /// Inside a scroll of the rows' clip view: moves heard now are kept.
    private(set) static var scrolling = 0
    /// The observations told of a move while the rows scrolled, and the
    /// word they were told it in, to tell them again when the rows rest.
    private static var kept: [ObjectIdentifier: (observer: NSObject, note: AnyObject)] = [:]
    private static var later: DispatchWorkItem?
    private static var original: IMP?
    private static let selector = NSSelectorFromString("_geometryInWindowDidChange:")
    /// Moves kept and told later, for the bench.
    static var movesKept = 0
    static var movesTold = 0

    /// AppKit's observation of a view's place in the window, the one
    /// NSHostingView's rootTransform listens through, made to keep what it
    /// hears while the rows scroll. Once, and only if AppKit has it.
    static func install() {
        guard quietMoves, original == nil,
              let observation: AnyClass = NSClassFromString("_NSViewGeometryInWindowConcreteObservation"),
              let method = class_getInstanceMethod(observation, selector) else { return }
        typealias Heard = @convention(c) (NSObject, Selector, AnyObject?) -> Void
        let block: @convention(block) (NSObject, AnyObject?) -> Void = { observer, note in
            if Thread.isMainThread, MainActor.assumeIsolated({ ColumnQuiet.keep(observer, note) }) { return }
            guard let imp = MainActor.assumeIsolated({ ColumnQuiet.original }) else { return }
            unsafeBitCast(imp, to: Heard.self)(observer, selector, note)
        }
        original = method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Two fingers on the rows, or their glide: only then are moves kept.
    /// A wheel's step, a scroll to a row, are heard at once, as before.
    private(set) static var gliding = false

    /// A scroll event the rows' scroll view heard: whether fingers or their
    /// glide go on, and, at their end, what was kept told at once.
    static func heard(_ event: NSEvent) {
        guard quietMoves else { return }
        let on: [NSEvent.Phase] = [.began, .changed, .stationary]
        let gesture = Swipe.isGesture(event)
        let going = gesture && on.contains { $0 == event.phase || $0 == event.momentumPhase }
        let over = !gesture || event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended || event.momentumPhase == .cancelled
        if going { gliding = true }
        if over, gesture || gliding {
            gliding = false
            // After this event's own scroll, on this turn of the run loop.
            DispatchQueue.main.async { ColumnQuiet.tell() }
        }
    }

    /// Kept, if fingers are scrolling the rows: told when they rest.
    private static func keep(_ observer: NSObject, _ note: AnyObject?) -> Bool {
        guard scrolling > 0, gliding, let note else { return false }
        kept[ObjectIdentifier(observer)] = (observer, note)
        movesKept += 1
        return true
    }

    /// A scroll of the rows' clip view begun: its moves kept.
    static func begin() { scrolling += 1 }

    /// How long the rows rest before the kept moves are told, ms
    /// (YAB_SMOOTH_MOVED_MS): a frame and a little, so a scroll that goes on
    /// keeps them while one step of a wheel is told at once. It was 120 ms,
    /// and the row lit lagged the pointer that long after a wheel's step
    /// (hover_after_scroll.py, job b9158315).
    static let rest = Double(env["YAB_SMOOTH_MOVED_MS"] ?? "") ?? 20

    /// The pointer moved or pressed while moves are kept: told first, so
    /// what the pointer reaches is where it is drawn.
    private static var monitor: Any?

    /// And over: what it kept told once the rows rest, or the pointer moves.
    static func end() {
        scrolling -= 1
        guard !kept.isEmpty else { return }
        later?.cancel()
        let work = DispatchWorkItem { ColumnQuiet.tell() }
        later = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rest / 1000, execute: work)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                                  .leftMouseDragged]) { event in
                ColumnQuiet.tell()
                return event
            }
        }
    }

    /// The rows at rest: each kept observation told, once.
    static func tell() {
        later?.cancel()
        later = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            Self.monitor = nil
        }
        guard !kept.isEmpty else { return }
        let all = kept
        kept = [:]
        guard let original else { return }
        typealias Heard = @convention(c) (NSObject, Selector, AnyObject?) -> Void
        for (_, each) in all {
            movesTold += 1
            unsafeBitCast(original, to: Heard.self)(each.observer, selector, each.note)
        }
    }

    // MARK: - asks kept in the page

    /// Asks a page kept from climbing, for the bench.
    static var asksKept = 0
    /// Asks a row answered in its own layout, for the bench.
    static var asksAnswered = 0

    /// AppKit's own carrying of an ask up past `view`.
    static func climb(_ view: NSView) {
        let selector = NSSelectorFromString("_informContainerThatSubviewsNeedUpdateConstraints")
        typealias Inform = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(class_getMethodImplementation(NSView.self, selector), to: Inform.self)(view, selector)
    }
}

/// The rows' clip view: its scrolls keep the moves they make (ColumnQuiet).
final class RowsClip: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        if ColumnQuiet.climbsWhileScrolling {
            ColumnQuiet.rowsScrolled = CACurrentMediaTime()
            var view = superview
            while let each = view, !(each is ColumnPage) { view = each.superview }
            (view as? ColumnPage)?.letAsksClimb()
        }
        guard ColumnQuiet.quietMoves else { return super.scroll(to: newOrigin) }
        ColumnQuiet.begin()
        super.scroll(to: newOrigin)
        ColumnQuiet.end()
    }
}
