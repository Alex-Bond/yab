import AppKit

/// input.send reconstructs CGEvent fields. NSEvent.Phase is a different
/// bitset, and momentum uses CGMomentumScrollPhase's separate 0...3 values.
enum ChromiumWheelPhase {
    static func gesture(_ phase: NSEvent.Phase) -> Int {
        var value = 0
        if phase.contains(.began) { value |= 1 }
        if phase.contains(.changed) { value |= 2 }
        if phase.contains(.ended) { value |= 4 }
        if phase.contains(.cancelled) { value |= 8 }
        if phase.contains(.mayBegin) { value |= 128 }
        return value
    }

    static func momentum(_ phase: NSEvent.Phase) -> Int {
        if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.began) { return 1 }
        return 0
    }
}

/// Chromium adapter of PageView's established pill/list gesture. History is a
/// native snapshot and permission still comes from the authenticated main frame.
/// WebKit retains its existing controller and behavior.
@MainActor
final class ChromiumSwipe {
    weak var page: ChromiumPage?
    private var snapshot: ChromiumHistorySnapshot?
    private var historyTask: Task<Void, Never>?
    private let history: @MainActor () async throws -> ChromiumHistorySnapshot
    private let evaluate: @MainActor (String) -> Void
    private let wheel: @MainActor (NSEvent) -> Void
    private var observing = false
    private var lastWheel: NSEvent?
    private var interrupted = false
    private var stepped: (forward: Bool, swipe: Bool, at: TimeInterval)?

    init(_ page: ChromiumPage?,
         history: (@MainActor () async throws -> ChromiumHistorySnapshot)? = nil,
         wheel: (@MainActor (NSEvent) -> Void)? = nil,
         evaluate: (@MainActor (String) -> Void)? = nil) {
        self.page = page
        self.history = history ?? { [weak page] in
            guard let page else { throw CancellationError() }
            return try await page.swipeHistory()
        }
        self.wheel = wheel ?? { [weak page] in page?.sendWheel($0) }
        self.evaluate = evaluate ?? { [weak page] source in
            page?.command("script.evaluate", ["world": .string(ChromiumScripts.world(.yab)),
                "function": .string("function(){\(source);return true}"), "userGesture": .bool(false)])
        }
    }

    /// A mouse driver may emit a button and a swipe for the same press.
    func step(forward: Bool, swipe: Bool, at time: TimeInterval) {
        if let last = stepped, last.forward == forward, last.swipe != swipe, time - last.at < 0.4 { return }
        stepped = (forward, swipe, time)
        guard let tab = page?.navigationTab else { return }
        if let onStep = tab.onStep { onStep(tab, forward) }
        else if forward { tab.forward() } else { tab.back() }
    }

    /// Reading history is observational: it must never hold the input stream.
    /// AppKit already delivers wheels in order on the main actor.
    func receive(_ event: NSEvent) {
        if interrupted {
            guard event.phase == .began || event.phase == .mayBegin ||
                (event.phase == [] && event.momentumPhase == []) else { return }
            interrupted = false
        }
        read(event)
    }

    private func forward(_ event: NSEvent) {
        wheel(event)
        if event.phase == .began || event.phase == .mayBegin || event.phase == .changed ||
            event.momentumPhase == .began || event.momentumPhase == .changed {
            lastWheel = event
        } else { lastWheel = nil }
    }

    /// Close Chromium's latched target when replacing its document. Use a
    /// zero-distance terminal wheel at the original target, never a new notch.
    func invalidate() {
        interrupted = true
        if let event = lastWheel, let cg = event.cgEvent?.copy() {
            let deltas: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
            for field in deltas {
                cg.setDoubleValueField(field, value: 0)
            }
            cg.timestamp = DispatchTime.now().uptimeNanoseconds
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.momentumPhase == [] ? 8 : 0)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: event.momentumPhase == [] ? 0 : 3)
            if let end = NSEvent(cgEvent: cg) { wheel(end) }
        }
        lastWheel = nil
        historyTask?.cancel()
        historyTask = nil
        snapshot = nil
        cancelSwipe()
    }

    private func readHistory() {
        if let page, let tab = page.navigationTab {
            ways = PageNavigationList.immediate(page: page, tab: tab, back: back)
            rows = ways?.stops ?? []
        }
        let mine = swipeGesture
        // A late snapshot may not suddenly arm navigation after a slow page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, swipeGesture == mine, snapshot == nil, !spent, rows.isEmpty else { return }
            historyTask?.cancel()
            spent = true
            settle(nil)
        }
        historyTask = Task { @MainActor [weak self, history = history] in
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = try? await history()
            if Store.testing {
                NSLog("Chromium swipe history %.3f s (cancelled=%@, received=%@)",
                    ProcessInfo.processInfo.systemUptime - start,
                    Task.isCancelled ? "yes" : "no", snapshot == nil ? "no" : "yes")
            }
            guard let self, !Task.isCancelled, swipeGesture == mine, !spent else { return }
            guard let snapshot else {
                if rows.isEmpty { spent = true; settle(nil) }
                return
            }
            self.snapshot = snapshot
            if let page, let tab = page.navigationTab {
                ways = snapshot.list(page: page, tab: tab, back: back)
                rows = ways?.stops ?? []
            }
            if rows.isEmpty {
                nowhere = true
                spent = true
                if free == true { still = true }
            } else { tell() }
        }
    }

    private func script(_ source: String) {
        evaluate(source)
    }
    private func note(_ text: @autoclosure () -> String) {}
    private var swipeState: String { "gesture=\(swipeGesture)" }

    private enum Axis { case across, down }

    private var sideways: CGFloat = 0
    private var gatheredX: CGFloat = 0
    private var gatheredY: CGFloat = 0
    private var axis: Axis?
    /// Which way the gesture set off, decided once and kept. Turning round
    /// mid-swipe pulls the pill back; it never becomes the other one.
    private var back = true
    /// The page's word on whether this swipe is its own. Nil until it says.
    private var free: Bool?
    private(set) var swipeGesture = 0
    /// Already went somewhere, or was refused: nothing more this gesture.
    private var spent = false
    /// Pages the swipe would go if let go now (`Swipe.steps`).
    private var stepsNow = 0
    /// How far the fingers have gone down (up, less than nought) since the
    /// list came out, each `Swipe.rowPitch` a row.
    private var upDown: CGFloat = 0
    /// Rows moved up and down in the list, changed only a good way past a
    /// row's middle, so a finger resting on a boundary doesn't flicker.
    private var picked = 0
    /// The row the sideways pull had reached when the fingers first went up
    /// or down: from then on, only up and down pick, sideways drift doesn't.
    private var lockedAcross: Int?
    /// Where and when the fingers last moved while the pill was armed: still
    /// there for `Swipe.hold`, they mean the list (feedback #346).
    private var holdAnchor: (time: TimeInterval, travel: CGFloat)?
    private var holdCheck = 0
    /// How far the fingers had come when a hold brought the list out: rows
    /// further are counted from there, not from where the swipe began.
    private var listFrom: CGFloat = 0
    /// Sideways towards no page, on a page with nothing to scroll that way:
    /// the page isn't moved at all, not even to bounce.
    private var nowhere = false
    private var still = false
    /// The pill is on screen: going quick no longer takes it back to a disc.
    private var pillShown = false
    private var retelling = false
    private var lastTap: TimeInterval = 0
    /// The list is out: up and down pick in it.
    private var listing: Bool { axis == .across && free == true && !spent && listedNow }
    private var listedNow = false
    /// Let go while the page's answer was still on its way.
    private var waiting = false
    /// The gesture is over: gone somewhere, refused, or given up on.
    var swipeSettled: Bool { spent && !waiting }
    private var showing = false
    private var going = false
    private var pulls = 0
    /// The history that way, nearest first, read once as the gesture sets
    /// off. Empty is nowhere to go: the pill still comes, faintly, and
    /// never arms, so a swipe on a tab's first page isn't simply dead.
    private var ways: PageNavigationList?
    /// The rows the list shows for them (`Swipe.rows`), read with them.
    private var rows: [Stop] = []
    /// The last few moments of the fingers, for how fast they were going
    /// when they lifted.
    private var trail: [(time: TimeInterval, sideways: CGFloat)] = []

    /// Less than this and there is nothing to show yet, or nothing left to.
    private static let show: CGFloat = 6
    /// A short swipe lifted this fast, in points a second, over at least
    /// `flickReach`, goes one page, however far it got. Only ever one: the
    /// pages behind that are for a hand that means it.
    private static let flick: CGFloat = 1000
    private static let flickReach: CGFloat = 60
    /// Coming back is quicker than going out: every point the fingers give
    /// back counts this many, so thinking better of a deep pull is a short
    /// way home, not the whole way.
    private static let giveBack: CGFloat = 3

    private func read(_ event: NSEvent) {
        // The page gets every event first and scrolls as it always did. The
        // swipe is only read, never taken, but for one moment: while the
        // list of pages is out, the fingers going up and down pick in it,
        // and the page under it keeps still.
        if event.phase == .mayBegin || event.phase == .began {
            historyTask?.cancel()
            historyTask = nil
            snapshot = nil
            swipeGesture += 1
            observing = false
            nowhere = false
            still = false
        }
        // script.evaluate is a completion barrier in the page's input queue.
        // A zero-distance touch or a vertical scroll must not wait for a
        // renderer round trip before its first wheel. Start ownership watching
        // before the first sideways wheel (including a sideways began), while
        // keeping begin ahead of that wheel so a quick flick is still observed.
        let starting = event.phase == .began || event.phase == .mayBegin
        if !observing, event.phase != [], event.momentumPhase == [],
           starting || !spent,
           abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.3 {
            observing = true
            if !LinkGap.cut("swipe") { script("window.__yabSwipe && window.__yabSwipe.begin(\(swipeGesture))") }
        }
        // Nor while the swipe goes towards no page and the page has nothing
        // of its own to scroll that way: it stays put rather than sliding
        // and springing back. Its end still goes, to settle anything begun.
        let listingNow = event.phase == .changed && event.momentumPhase == [] && listing
        let stillNow = still && (event.phase == .changed || event.momentumPhase == .began || event.momentumPhase == .changed)
        if !(listingNow || stillNow) { forward(event) }
        // Only a live trackpad gesture, not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }

        switch event.phase {
        case .mayBegin, .began:
            sideways = 0
            gatheredX = 0
            gatheredY = 0
            axis = nil
            free = nil
            spent = false
            stepsNow = 0
            listedNow = false
            upDown = 0
            picked = 0
            lockedAcross = nil
            pillShown = false
            holdAnchor = nil
            holdCheck += 1
            listFrom = 0
            waiting = false
            showing = false
            ways = nil
            rows = []
            trail = []
            // A pill still on its way out belongs to the last gesture. It
            // is already invisible; it is only taken off the stage so the
            // next one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                page?.navigationTab?.pull = nil
            }
        case .changed:
            guard !spent else { return }
            if axis == nil {
                // A few points in, the gesture has shown which way it means
                // to go. Only a clearly sideways one is read further.
                gatheredX += abs(event.scrollingDeltaX)
                gatheredY += abs(event.scrollingDeltaY)
                sideways += event.scrollingDeltaX
                guard gatheredX + gatheredY > 6 else { return }
                axis = gatheredX > gatheredY * 1.3 ? .across : .down
                note("decided \(axis == .across ? "across" : "down") gathered x=\(Int(gatheredX)) y=\(Int(gatheredY))")
                if axis == .down {
                    spent = true
                    return
                }
                // Pinched in, the fingers are moving around inside what was
                // magnified, the page itself may be no wider than the window.
                // Reaching its edge there is not a wish to leave.
                if (page?.magnification ?? 1) > 1.01 {
                    note("magnified \(String(format: "%.2f", page?.magnification ?? 1)), left to pan")
                    spent = true
                    return
                }
                back = sideways > 0
                readHistory()
                note(event)
                tell()
                return
            }
            let dx = event.scrollingDeltaX
            if back ? dx < 0 : dx > 0 {
                sideways = back ? max(0, sideways + dx * ChromiumSwipe.giveBack) : min(0, sideways + dx * ChromiumSwipe.giveBack)
            } else {
                sideways += dx
            }
            // Down the list as the fingers go down, whichever way the Mac
            // is set to scroll.
            let down = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
            if listing {
                upDown += down
            }
            note(event)
            tell()
        case .ended:
            release()
        case .cancelled:
            cancelSwipe()
        default:
            break
        }
    }

    private func note(_ event: NSEvent) {
        trail.append((event.timestamp, sideways))
        if trail.count > 6 { trail.removeFirst(trail.count - 6) }
    }

    /// The fingers' speed now: nought once they have sent nothing for
    /// `Swipe.quickRest`, which is what fingers at rest do.
    private func live(_ now: TimeInterval) -> CGFloat {
        guard let last = trail.last, now - last.time < Swipe.quickRest else { return 0 }
        return speed
    }

    /// Points a second the fingers were going, the way the swipe set off,
    /// over the last events before they lifted.
    private var speed: CGFloat {
        guard let first = trail.first, let last = trail.last, last.time - first.time > 0.005 else { return 0 }
        let moved = (last.sideways - first.sideways) * (back ? 1 : -1)
        return moved / CGFloat(last.time - first.time)
    }

    /// Invalidate replies from an old gesture or a document being replaced.
    func cancelSwipe() {
        swipeGesture += 1
        spent = true
        waiting = false
        nowhere = false
        still = false
        settle(nil)
    }

    /// Only replies from this gesture in the main document may authorize it.
    func answer(free yes: Bool, gesture: Int, finished: Bool = false) {
        guard gesture == swipeGesture else { return }
        note("page says \(yes ? "free" : "taken") | \(swipeState)")
        if nowhere { still = yes }
        guard axis != .down, !spent else { return }
        guard yes else {
            free = false
            waiting = false
            spent = true
            settle(nil)
            return
        }
        free = true
        tell()
        if waiting && finished {
            waiting = false
            release(confirmed: true)
        }
    }

    /// Only the distance in the direction it set off in. Past the origin the
    /// other way is just nought.
    private var travel: CGFloat { max(0, back ? sideways : -sideways) }

    private func tell() {
        guard free == true, ways != nil else { return }

        let travel = travel
        // Drawn all the way back, the pill goes; drawn out again, it
        // returns. Nothing is decided until the fingers lift.
        guard travel >= ChromiumSwipe.show else {
            // Back home, however quick: a flick back can come all the way
            // in one event, past the arm with no step in between, and what
            // was armed must not still be when the fingers lift.
            if stepsNow != 0 || listedNow { note("home from steps \(stepsNow) list \(listedNow)") }
            stepsNow = 0
            listedNow = false
            pillShown = false
            holdAnchor = nil
            upDown = 0
            picked = 0
            lockedAcross = nil
            if showing { settle(nil) }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let armedHere = Swipe.steps(travel: travel, rows: rows.count) > 0
        // However far or slow the pull, letting go goes one page. The list
        // of pages behind comes out only for fingers held still a moment
        // with the pill armed (feedback #346): a long swipe that went past
        // where the list used to open went to the history instead of back.
        if !armedHere || listedNow || rows.count < 2 {
            holdAnchor = nil
        } else if let anchor = holdAnchor, abs(travel - anchor.travel) <= Swipe.holdSlop {
            // Resting, or near enough: the clock runs on.
        } else {
            holdAnchor = (now, travel)
            awaitHold()
        }
        let held = holdAnchor.map { now - $0.time >= Swipe.hold - 0.005 } ?? false
        var listed = listedNow ? armedHere : held
        if listed, !listedNow {
            listFrom = travel
            note("list out after a hold at travel \(Int(travel))")
        }
        if !listed { listFrom = 0 }
        // Rows past the first, while the list is out, by how much further
        // the fingers pull from where it came out.
        let across = listed ? Swipe.steps(travel: Swipe.open + max(0, travel - listFrom), rows: rows.count)
                            : Swipe.steps(travel: travel, rows: rows.count)
        if rows.count < 2 { listed = false }
        // Going quick, either way: the fingers are on their way somewhere,
        // so nothing new grows under them, no pill out of the disc, only to
        // be taken back a frame later. What shows stays; the rest comes once
        // they slow or rest a moment.
        let quick = abs(live(now)) >= Swipe.passSpeed
        // Pulled back to where there is no list, what the fingers did up and
        // down is let go of with it.
        var steps = across
        if listed {
            let pitch = Swipe.rowPitch
            if lockedAcross == nil, abs(upDown) >= pitch / 2 { lockedAcross = across }
            let base = lockedAcross ?? across
            // Nothing banked past either end: turning back moves at once.
            // Above the first row is a row's worth of nothing: let go there
            // and the page stays.
            upDown = min(max(upDown, (CGFloat(-base) - 0.5) * pitch), (CGFloat(rows.count - base) + 0.5) * pitch)
            let at = upDown / pitch
            while at > CGFloat(picked) + 0.6 { picked += 1 }
            while at < CGFloat(picked) - 0.6 { picked -= 1 }
            steps = min(max(lockedAcross == nil ? 1 : 0, base + picked), rows.count)
        } else {
            upDown = 0
            picked = 0
            lockedAcross = nil
            // The list held back: the pill's page, however far out.
            steps = min(steps, 1)
        }
        let passing = quick && steps > 0 && !pillShown && !listed
        if steps == 0 { pillShown = false } else if !passing { pillShown = true }
        if quick, !retelling {
            // Fingers that stop send nothing more: a look again in a moment
            // shows what they rest on. One look at a time; still quick then,
            // it sets the next.
            retelling = true
            let gesture = pulls
            DispatchQueue.main.asyncAfter(deadline: .now() + Swipe.quickRest + 0.01) { [weak self] in
                guard let self else { return }
                retelling = false
                guard pulls == gesture, !spent, showing else { return }
                tell()
            }
        }
        if steps != stepsNow || listed != listedNow {
            note("steps \(stepsNow) -> \(steps) across=\(across) locked=\(lockedAcross.map(String.init) ?? "-") picked=\(picked) list \(listedNow) -> \(listed) passing=\(passing)")
        }
        // A firmer tap for every page further, a lighter one for every page
        // given back, so you know without looking how deep letting go would
        // take you, and that at nought it is safe. The list coming out or
        // folding is a tap of its own; two within a moment are one.
        let opens = listed != listedNow
        if steps != stepsNow || opens {
            let firmer = steps > stepsNow || (steps == stepsNow && listed)
            if now - lastTap > 0.06 {
                NSHapticFeedbackManager.defaultPerformer.perform(firmer ? .levelChange : .alignment, performanceTime: .now)
                lastTap = now
            }
        }
        listedNow = listed
        stepsNow = steps
        var pull = pull(travel: travel, steps: steps, going: false)
        pull.passing = passing
        pull.quick = quick
        settle(pull)
    }

    /// A look once the fingers have been still for `Swipe.hold`: resting
    /// fingers send nothing, so nothing else would bring the list out.
    private func awaitHold() {
        holdCheck += 1
        let mine = holdCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + Swipe.hold) { [weak self] in
            guard let self, holdCheck == mine, !spent, !waiting, free == true, holdAnchor != nil else { return }
            tell()
        }
    }

    private func pull(travel: CGFloat, steps: Int, going: Bool) -> Pull {
        Pull(back: back, travel: travel, steps: steps, stops: rows, blocked: rows.isEmpty, listed: listedNow, going: going)
    }

    private func release(confirmed: Bool = false) {
        // Even an earlier free reply must be checked after the last wheel:
        // the page may have consumed a later event in the same gesture.
        if !confirmed, !spent, axis == .across, !rows.isEmpty {
            guard !waiting else { return }
            waiting = true
            let mine = swipeGesture
            script("window.__yabSwipe && window.__yabSwipe.finish(\(mine))")
            // This includes IPC and the page's wheel handlers, not just our
            // 32 ms coalescing timer. A busy article must get time to reply.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self, waiting, swipeGesture == mine else { return }
                // Silence is not permission to leave a busy page.
                cancelSwipe()
            }
            return
        }
        defer { spent = true }
        guard !spent, free == true, !rows.isEmpty else {
            note("let go: nothing (spent or page's or no rows) | \(swipeState)")
            settle(nil)
            return
        }
        var steps = stepsNow
        if steps == 0, !listedNow, travel >= ChromiumSwipe.flickReach, speed >= ChromiumSwipe.flick { steps = 1 }
        guard steps > 0, steps <= rows.count else {
            note("let go short: nothing, speed=\(Int(speed)) | \(swipeState)")
            settle(nil)
            return
        }
        let stop = rows[steps - 1]
        note("let go on row \(steps) \(stop.kind) \"\(stop.title)\" speed=\(Int(speed)) | \(swipeState)")
        going = true
        settle(pull(travel: travel, steps: steps, going: true))
        if stop.kind == .search, let tab = page?.navigationTab, let history = ways?.history() {
            tab.pullView?.panel(history, of: tab) { [weak tab] words in
                guard let tab else { return }
                tab.onSearchHistory?(tab, words)
            }
        } else { ways?.take(stop) }
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    private func settle(_ pull: Pull?) {
        showing = pull != nil
        page?.navigationTab?.pull = pull
    }
}

extension ChromiumPage {
    /// Same stage edge and press callbacks as PageView. Agent input cannot
    /// open a user's Peek or dim the source document.
    func receivePressure(stage: Int, amount: CGFloat, point: CGPoint) {
        let previous = pressureStage
        pressureStage = stage
        guard !PageView.agentActing, let tab = navigationTab else { return }
        if forceInput.holdsInput {
            if stage == 0, previous > 0 { tab.onPress?(tab, 0) }
            return
        }
        if stage == 1 { tab.onPress?(tab, amount) }
        else if stage == 0, previous > 0 { tab.onPress?(tab, 0) }
        if stage == 2, previous < 2 { tab.onForceClick?(tab, point) }
    }
}
